import Cocoa
import ApplicationServices

class LogicPoller {

    static let bundleID = "com.apple.logic10"

    var onSnapshot: ((LogicSnapshot) -> Void)?
    var dumpAXTree = false
    private(set) var lastSnapshot: LogicSnapshot?

    private var driftTimer: DispatchSourceTimer?
    private let queue     = DispatchQueue(label: "com.indicator.poller", qos: .utility)
    private let syncQueue = DispatchQueue(label: "com.indicator.poller.sync", qos: .userInitiated)

    // MTC 재생 중 여부 — true면 AX 드리프트 읽기 스킵
    var mtcActive: Bool = false

    // 캐시 — 공연 중 바뀌지 않는 값들
    private var cachedTimeSigEvents: [TimeSigEvent] = []
    private var cachedMarkers: [Marker] = []
    private var cachedChords: [ChordEvent] = []
    private var cachedInnerBar: AXUIElement? = nil

    // MARK: - 시작 / 종료

    func start() {
        // 앱 시작 시 풀스캔 1회
        queue.async { [weak self] in self?.fullScan() }

        // 500ms마다 bar/beat 보정 (정지 중 재생헤드 이동 포함)
        let t = DispatchSource.makeTimerSource(queue: syncQueue)
        t.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.readBarBeatOnly() }
        t.resume()
        driftTimer = t

        // 접근성 권한 부여 감지 → 3초 후 자동 스캔
        scheduleAutoScanAfterPermission()
    }

    func stop() {
        driftTimer?.cancel()
        driftTimer = nil
        axPermissionTimer?.cancel()
        axPermissionTimer = nil
    }

    // MARK: - 접근성 권한 감지 후 자동 스캔

    private var axPermissionTimer: DispatchSourceTimer?
    private var axWasGranted = false

    private func scheduleAutoScanAfterPermission() {
        if AXIsProcessTrusted() {
            // 이미 권한 있음 → 3초 후 스캔
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.performScan()
            }
            return
        }
        // 권한 없음 → 0.5초마다 체크, 부여되면 3초 후 스캔 (1회만)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in
            guard let self, !self.axWasGranted, AXIsProcessTrusted() else { return }
            self.axWasGranted = true
            self.axPermissionTimer?.cancel()
            self.axPermissionTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.performScan()
            }
        }
        t.resume()
        axPermissionTimer = t
    }

    // 수동 새로고침 (메뉴 버튼)
    func refreshMarkers() {
        cachedMarkers = []; cachedChords = []; cachedInnerBar = nil
        queue.async { [weak self] in self?.fullScan() }
    }

    // MTC 점프 감지 시 StateEngine이 호출 — 100ms 후 강제 읽기 (Logic AX 업데이트 대기)
    func syncBarBeat() {
        syncQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.readBarBeatForced() }
    }

    func forceUpdate() {
        queue.async { [weak self] in self?.fullScan() }
    }

    // MARK: - 풀스캔 (시작 1회 + 수동 새로고침)

    private func fullScan() {
        guard AXIsProcessTrusted() else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        if dumpAXTree {
            var dump = ""
            dumpElement(axApp, indent: 0, maxDepth: 12, into: &dump)
            try? dump.write(to: URL(fileURLWithPath: "\(NSHomeDirectory())/Desktop/ax_tree.txt"),
                            atomically: true, encoding: .utf8)
            dumpAXTree = false
        }

        var snapshot = LogicSnapshot()
        readTransport(axApp: axApp, into: &snapshot)           // BPM·박자·조표·bar/beat
        readMarkers(axApp: axApp, into: &snapshot)             // 마커
        if !snapshot.markers.isEmpty { cachedMarkers = snapshot.markers }
        readChords(axApp: axApp, into: &snapshot)              // 코드
        if !snapshot.chords.isEmpty { cachedChords = snapshot.chords }
        readTimeSigs(axApp: axApp, into: &snapshot)            // 변박
        if !snapshot.timeSigEvents.isEmpty { cachedTimeSigEvents = snapshot.timeSigEvents }

        DispatchQueue.main.async {
            self.lastSnapshot = snapshot
            self.onSnapshot?(snapshot)
        }
    }

    // MARK: - bar/beat 보정만 (드리프트 + MTC 점프)

    // 타이머 호출 — 재생 중엔 스킵
    private func readBarBeatOnly() {
        guard !mtcActive else { return }
        readBarBeatForced()
    }

    // 점프 감지 호출 — 재생 중도 강제 실행
    private func readBarBeatForced() {
        // 마커가 아직 없으면 풀스캔으로 대체 (앱 시작 직후 race condition 방지)
        guard !cachedMarkers.isEmpty else { fullScan(); return }

        guard AXIsProcessTrusted() else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var snapshot = lastSnapshot ?? LogicSnapshot()
        snapshot.markers        = cachedMarkers
        snapshot.chords         = cachedChords
        snapshot.timeSigEvents  = cachedTimeSigEvents
        readTransport(axApp: axApp, into: &snapshot)

        DispatchQueue.main.async {
            self.lastSnapshot = snapshot
            self.onSnapshot?(snapshot)
        }
    }

    // MARK: - Transport
    // AX path: AXWindow → AXGroup(desc=컨트롤 막대) → AXGroup(desc=컨트롤 막대) →
    //   AXGroup(desc=재생헤드 위치) → AXSlider(desc=마디), AXSlider(desc=비트)
    //   AXSlider(desc=템포)
    //   AXPopUpButton(desc=박자표)

    private func readTransport(axApp: AXUIElement, into snapshot: inout LogicSnapshot) {
        // 캐시된 innerBar가 있으면 바로 사용 (윈도우 탐색 생략)
        if let innerBar = cachedInnerBar {
            readTransportValues(innerBar: innerBar, into: &snapshot)
            return
        }
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return }
        for window in windows {
            guard let outerBar = findByDesc(window, "컨트롤 막대"),
                  let innerBar = findByDescAmongChildren(of: outerBar, desc: "컨트롤 막대")
            else { continue }
            cachedInnerBar = innerBar
            readTransportValues(innerBar: innerBar, into: &snapshot)
            return
        }
    }

    private func readTransportValues(innerBar: AXUIElement, into snapshot: inout LogicSnapshot) {

            // Bar / Beat + 타임코드 (두 개의 "재생헤드 위치" 그룹)
            let children = axArray(of: innerBar, key: kAXChildrenAttribute) ?? []
            let posGroups = children.filter {
                (axString($0, key: kAXDescriptionAttribute) ?? "") == "재생헤드 위치"
            }
            if let posGroup = posGroups.first,
               let barSlider  = findByDesc(posGroup, "마디"),
               let beatSlider = findByDesc(posGroup, "비트") {
                if let bar  = axNumber(barSlider),  bar  >= 1 { snapshot.transportBar  = Int(bar)  }
                if let beat = axNumber(beatSlider), beat >= 1 { snapshot.transportBeat = Int(beat) }
            }
            if posGroups.count >= 2,
               let desc = axString(posGroups[1], key: kAXDescriptionAttribute), desc == "재생헤드 위치",
               let tcStr = axString(posGroups[1], key: kAXValueAttribute) ?? axString(posGroups[1], key: kAXTitleAttribute) {
                if let tc = parseMTCSeconds(tcStr) { snapshot.transportMTC = tc }
            }

            // BPM
            if let tempoSlider = findByDesc(innerBar, "템포"),
               let bpm = axNumber(tempoSlider), bpm > 20, bpm < 500 {
                snapshot.bpm = bpm
            }

            // Time signature  (val = "4/4")
            if let tsButton = findByDesc(innerBar, "박자표"),
               let val = axString(tsButton, key: kAXValueAttribute) {
                snapshot.timeSignature = val
                if let num = parseTimeSigNumerator(val) {
                    snapshot.beatsPerBar = num
                }
            }

            // Key signature  (val = "C 메이저", "G 메이저", "A 마이너" …)
            if let keyButton = findByDesc(innerBar, "조표"),
               let val = axString(keyButton, key: kAXValueAttribute) {
                snapshot.key = parseKey(val)
            }
    }

    // MARK: - Chords
    // AX path: 트랙 창 → AXLayoutArea(desc=트랙 시간 눈금자) → AXLayoutArea(desc=코드 트랙)
    //          → AXLayoutItem(desc=코드 그룹 ...) → AXLayoutArea(desc=코드 컨테이너)
    //          → AXLayoutItem children: desc = "<chord> <bar> 마디 [<beat> 비트 ...] <ticks> 틱"

    private func readChords(axApp: AXUIElement, into snapshot: inout LogicSnapshot) {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else {
            debugLog("[Chord] no windows"); return
        }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard title.contains("트랙"), !title.contains("마커"), !title.contains("조표") else { continue }
            debugLog("[Chord] found track window: \(title)")
            guard let ruler = findByDesc(window, "트랙 시간 눈금자") else {
                debugLog("[Chord] 트랙 시간 눈금자 not found"); continue
            }
            guard let track = findByDesc(ruler, "코드 트랙") else {
                debugLog("[Chord] 코드 트랙 not found"); continue
            }
            let groups = axArray(of: track, key: kAXChildrenAttribute)?
                .filter { (axString($0, key: kAXDescriptionAttribute) ?? "").hasPrefix("코드 그룹") } ?? []
            debugLog("[Chord] found \(groups.count) chord groups")

            var chords: [ChordEvent] = []
            for group in groups {
                guard let container = findByDesc(group, "코드 컨테이너"),
                      let items = axArray(of: container, key: kAXChildrenAttribute) else { continue }
                for item in items {
                    let desc = axString(item, key: kAXDescriptionAttribute) ?? ""
                    if let chord = parseChordDesc(desc) { chords.append(chord) }
                }
            }
            chords.sort { $0.bar < $1.bar || ($0.bar == $1.bar && $0.beat < $1.beat) }
            debugLog("[Chord] parsed \(chords.count) chords total, barRange=\(chords.first?.bar ?? 0)–\(chords.last?.bar ?? 0)")
            if !chords.isEmpty { snapshot.chords = chords }
            return
        }
        debugLog("[Chord] no matching window found among \(windows.count) windows")
    }

    // "g major 219 마디 25 틱" / "b minor 7 221 마디 4 비트 4 디비전 240 틱" → ChordEvent
    private func parseChordDesc(_ desc: String) -> ChordEvent? {
        let tokens = desc.components(separatedBy: " ")
        guard let barIdx = tokens.firstIndex(of: "마디"), barIdx > 0,
              let bar = Int(tokens[barIdx - 1]) else { return nil }

        // beat: "마디" 다음에 숫자 "비트" 순서
        var beat = 1
        if barIdx + 2 < tokens.count, tokens[barIdx + 2] == "비트",
           let b = Int(tokens[barIdx + 1]) { beat = b }

        // 코드명: 마디 앞 숫자 이전까지 모든 토큰
        let nameParts = Array(tokens[..<(barIdx - 1)])
        let name = formatChordName(nameParts)
        guard !name.isEmpty else { return nil }
        return ChordEvent(name: name, bar: bar, beat: beat)
    }

    // ["g", "major"] → "G" / ["e", "minor"] → "Em" / ["b", "minor", "7"] → "Bm7" / ["g", "major/b"] → "G/B"
    private func formatChordName(_ parts: [String]) -> String {
        guard let root = parts.first else { return "" }
        let rootStr = root.prefix(1).uppercased() + root.dropFirst()

        // slash chord in root itself: "g major/b"
        if let second = parts.dropFirst().first, second.contains("/") {
            let slash = second.components(separatedBy: "/")
            let quality = slash[0] == "major" ? "" : "m"
            let bass = slash.count > 1 ? "/" + slash[1].prefix(1).uppercased() + slash[1].dropFirst() : ""
            return rootStr + quality + bass
        }

        let quality = parts.dropFirst().first ?? "major"
        let extensions = parts.dropFirst(2).joined()

        switch quality {
        case "major": return rootStr + (extensions.isEmpty ? "" : extensions)
        case "minor": return rootStr + "m" + extensions
        default:      return rootStr + quality + extensions
        }
    }

    // MARK: - Markers
    // Window title contains "마커 목록" (탐색 > 마커 목록 열기).
    // Row structure (4 cells per row):
    //   cells[0] = checkbox (skip)
    //   cells[1] = position cell → child AXGroup → desc = "1 1 1 1 "
    //   cells[2] = name cell     → child AXCell  → desc = "#은혜"
    //   cells[3] = length cell (skip)

    private func readMarkers(axApp: AXUIElement, into snapshot: inout LogicSnapshot) {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard title.contains("마커 목록") else { continue }
            guard let scrollArea = findByRole(window, "AXScrollArea"),
                  let table      = findByRole(scrollArea, "AXTable") else { continue }

            // 스크롤바를 여러 위치로 옮기며 전체 마커 수집 (가상 스크롤 대응)
            let scrollBar = axArray(of: scrollArea, key: kAXVerticalScrollBarAttribute as String)?.first
                         ?? findByRole(scrollArea, "AXScrollBar")

            var collected: [Marker] = []
            var seenKeys = Set<String>()

            func harvest() {
                for m in extractMarkers(from: table) {
                    let key = "\(m.name)_\(m.mtcSeconds)"
                    if seenKeys.insert(key).inserted { collected.append(m) }
                }
            }

            if let sb = scrollBar {
                // 원래 스크롤 위치 저장
                var origRef: CFTypeRef?
                AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &origRef)

                // 0.0 → 0.25 → 0.5 → 0.75 → 1.0 순서로 스크롤하며 읽기
                for pos in stride(from: 0.0, through: 1.0, by: 0.25) {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, pos as CFTypeRef)
                    Thread.sleep(forTimeInterval: 0.04) // UI 갱신 대기
                    harvest()
                }

                // 원래 위치 복원
                if let orig = origRef {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, orig)
                }
            } else {
                harvest()
            }

            if !collected.isEmpty {
                snapshot.markers = collected.sorted { $0.mtcSeconds < $1.mtcSeconds }
            }
            return
        }
    }

    private func extractMarkers(from table: AXUIElement) -> [Marker] {
        // kAXRowsAttribute는 가상 스크롤 시 보이는 행만 반환할 수 있음
        // kAXRowsAttribute + kAXVisibleRowsAttribute 합산해 누락 방지
        var seenPtrs = Set<UnsafeRawPointer>()
        var rows: [AXUIElement] = []
        func addRows(_ newRows: [AXUIElement]) {
            for r in newRows {
                let ptr = Unmanaged.passUnretained(r).toOpaque()
                if seenPtrs.insert(ptr).inserted { rows.append(r) }
            }
        }
        if let r = axArray(of: table, key: kAXRowsAttribute)        { addRows(r) }
        if let r = axArray(of: table, key: kAXVisibleRowsAttribute)  { addRows(r) }
        if rows.isEmpty, let r = axArray(of: table, key: kAXChildrenAttribute) { addRows(r) }

        var markers: [Marker] = []
        for row in rows {
            let cells = axArray(of: row, key: kAXChildrenAttribute) ?? []
            guard cells.count >= 3 else { continue }

            // Position: cells[1] → first AXGroup child → kAXDescriptionAttribute
            guard let posChildren = axArray(of: cells[1], key: kAXChildrenAttribute),
                  let posGroup = posChildren.first(where: {
                      (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup"
                  }) else { continue }
            let posText = axString(posGroup, key: kAXDescriptionAttribute) ?? ""

            // Name: cells[2] → first AXCell child → kAXDescriptionAttribute
            guard let nameChildren = axArray(of: cells[2], key: kAXChildrenAttribute),
                  let nameCell = nameChildren.first(where: {
                      (axString($0, key: kAXRoleAttribute) ?? "") == "AXCell"
                  }) else { continue }
            let nameText = (axString(nameCell, key: kAXDescriptionAttribute) ?? "")
                .trimmingCharacters(in: .whitespaces)

            guard !nameText.isEmpty, let mtcSec = parseMTCSeconds(posText) else { continue }
            let bar = parseBarBeat(posText)?.bar ?? 1
            markers.append(Marker(name: nameText, mtcSeconds: mtcSec, bar: bar))
        }
        return markers
    }

    // MARK: - Time Signatures
    // Window title contains "조표 및 박자표 목록"
    // Row structure:
    //   cells[0] = position → AXGroup desc = "55 1 1 1 "
    //   cells[1] = type     → AXCell  desc = "박자" or "키"
    //   cells[2] = value    → AXSlider (분자) + AXPopUpButton val="/4" (분모)

    private func readTimeSigs(axApp: AXUIElement, into snapshot: inout LogicSnapshot) {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard title.contains("조표 및 박자표 목록") else { continue }
            guard let table = findByRole(window, "AXTable") else { continue }
            let (timeSigs, keys) = extractTimeSigsAndKeys(from: table)
            if !timeSigs.isEmpty { snapshot.timeSigEvents = timeSigs }
            // 현재 bar 기준으로 적용 가능한 마지막 박자/키 적용
            let curBar = max(1, snapshot.transportBar)
            if let ts = timeSigs.last(where: { $0.bar <= curBar }) ?? timeSigs.first {
                snapshot.beatsPerBar   = ts.beatsPerBar
                snapshot.timeSignature = "\(ts.beatsPerBar)/\(ts.beatUnit)"
            }
            if let key = keys.last(where: { $0.bar <= curBar }) ?? keys.first {
                snapshot.key = key.name
            }
            return
        }
    }

    private func extractTimeSigsAndKeys(from table: AXUIElement) -> ([TimeSigEvent], [(bar: Int, name: String)]) {
        let rows = axArray(of: table, key: kAXRowsAttribute)
                ?? axArray(of: table, key: kAXChildrenAttribute)
                ?? []

        var timeSigs: [TimeSigEvent] = []
        var keys: [(bar: Int, name: String)] = []

        for row in rows {
            let cells = axArray(of: row, key: kAXChildrenAttribute) ?? []
            guard cells.count >= 3 else { continue }

            // 위치: cells[0] → AXGroup child. 없으면 기본 행(bar=1)
            let posChildren = axArray(of: cells[0], key: kAXChildrenAttribute) ?? []
            let posGroup = posChildren.first(where: {
                (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup"
            })
            let bar: Int
            if let posGroup = posGroup {
                let posText = axString(posGroup, key: kAXDescriptionAttribute) ?? ""
                guard let pos = parseBarBeat(posText) else { continue }
                bar = pos.bar
            } else {
                bar = 1
            }

            // 타입: cells[1] → AXCell desc
            let typeChildren = axArray(of: cells[1], key: kAXChildrenAttribute) ?? []
            let typeDesc = typeChildren.compactMap { el -> String? in
                guard (axString(el, key: kAXRoleAttribute) ?? "") == "AXCell" else { return nil }
                return axString(el, key: kAXDescriptionAttribute)
            }.first ?? ""

            let valueChildren = axArray(of: cells[2], key: kAXChildrenAttribute) ?? []

            if typeDesc == "박자" {
                // 값: AXSlider(분자) + AXPopUpButton val="/N"(분모)
                guard let slider = valueChildren.first(where: {
                          (axString($0, key: kAXRoleAttribute) ?? "") == "AXSlider"
                      }),
                      let numerator = axNumber(slider).map({ Int(round($0)) }),
                      numerator > 0
                else { continue }

                let denomStr = valueChildren.compactMap { el -> String? in
                    guard (axString(el, key: kAXRoleAttribute) ?? "") == "AXPopUpButton" else { return nil }
                    return axString(el, key: kAXValueAttribute)
                }.first ?? "/4"
                let beatUnit = Int(denomStr.replacingOccurrences(of: "/", with: "")) ?? 4

                timeSigs.append(TimeSigEvent(bar: bar, beatsPerBar: numerator, beatUnit: beatUnit))

            } else if typeDesc == "키" {
                // 값: AXPopUpButton val = "C 메이저" / "A 단조" 등
                let rawKey = valueChildren.compactMap { el -> String? in
                    guard (axString(el, key: kAXRoleAttribute) ?? "") == "AXPopUpButton" else { return nil }
                    return axString(el, key: kAXValueAttribute)
                }.first ?? ""
                let keyName = parseLogicKey(rawKey)
                if !keyName.isEmpty {
                    keys.append((bar: bar, name: keyName))
                }
            }
        }
        return (timeSigs.sorted { $0.bar < $1.bar }, keys.sorted { $0.bar < $1.bar })
    }

    // "C 메이저" → "C", "A 단조" → "Am", "F# 메이저" → "F#", "B♭ 단조" → "B♭m"
    private func parseLogicKey(_ raw: String) -> String {
        let parts = raw.split(separator: " ").map(String.init)
        guard let root = parts.first, !root.isEmpty else { return "" }
        let isMinor = parts.dropFirst().contains("단조")
        return isMinor ? root + "m" : root
    }

    // MARK: - 새 MTC 기반 스캔

    // 수동 또는 자동 스캔 진입점
    func performScan() {
        queue.async { [weak self] in self?.scanMTC() }
    }

    private func scanMTC() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { debugLog("접근성 권한 없음") }
            return
        }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID).first else {
            DispatchQueue.main.async { debugLog("Logic Pro가 실행중이지 않음") }
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // 1. 마커 읽기 (MTC 직접)
        switch readMarkersMTC(axApp: axApp) {
        case nil:
            DispatchQueue.main.async { debugLog("마커 목록 창을 열어주세요") }
            return
        case let m? where m.isEmpty:
            DispatchQueue.main.async { debugLog("마커 목록 > 보기 > '이벤트 위치 및 길이를 시간으로 표시' 체크") }
            return
        case let m?:
            break
        }
        let markers = readMarkersMTC(axApp: axApp)!

        // 2. 템포 읽기 (MTC 직접)
        guard let tempos = readTemposMTC(axApp: axApp), !tempos.isEmpty else {
            DispatchQueue.main.async { debugLog("템포 목록 창을 열어주세요") }
            return
        }

        // 3. 조표/박자표 읽기 (마디 위치 → MTC 변환)
        let (timeSigs, keySigs) = readTimeSigsAndKeySigsMTC(axApp: axApp, tempos: tempos)

        // 마커에 barHint 계산 (LyricsStore 키 호환용)
        let rawTS = rawTimeSigsForBarHint(axApp: axApp)
        let markersWithBar = markers.map { m -> ScannedMarker in
            let bar = mtcToBar(m.mtcSeconds, tempos: tempos, rawTimeSigs: rawTS)
            return ScannedMarker(name: m.name, isSong: m.isSong, mtcSeconds: m.mtcSeconds, barHint: max(1, Int(round(bar))))
        }

        let schedule = ScannedSchedule(
            markers:   markersWithBar,
            tempos:    tempos,
            timeSigs:  timeSigs,
            keySigs:   keySigs,
            scannedAt: Date()
        )
        DispatchQueue.main.async { ScheduleStore.shared.save(schedule: schedule) }
        debugLog("[Scan] 완료: 마커 \(markers.count)개, 템포 \(tempos.count)개, 박자 \(timeSigs.count)개, 조표 \(keySigs.count)개")
    }

    // MARK: 마커 목록 읽기 (MTC)
    private func readMarkersMTC(axApp: AXUIElement) -> [ScannedMarker]? {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return nil }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard title.contains("마커 목록") else { continue }
            guard let scrollArea = findByRole(window, "AXScrollArea"),
                  let table      = findByRole(scrollArea, "AXTable") else { return nil }

            let scrollBar = axArray(of: scrollArea, key: kAXVerticalScrollBarAttribute as String)?.first
                         ?? findByRole(scrollArea, "AXScrollBar")

            var collected: [ScannedMarker] = []
            var seenKeys = Set<String>()

            func harvest() {
                for m in extractMarkersMTC(from: table) {
                    let key = "\(m.name)_\(m.mtcSeconds)"
                    if seenKeys.insert(key).inserted { collected.append(m) }
                }
            }

            if let sb = scrollBar {
                var origRef: CFTypeRef?
                AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &origRef)
                // 0.1 간격으로 촘촘하게 스크롤 (66개처럼 많은 경우 0.25로는 누락 발생)
                for pos in stride(from: 0.0, through: 1.0, by: 0.1) {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, pos as CFTypeRef)
                    Thread.sleep(forTimeInterval: 0.08)
                    harvest()
                }
                // 1.0 확실히 포함 (마지막 마커 누락 방지)
                AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 1.0 as CFTypeRef)
                Thread.sleep(forTimeInterval: 0.08)
                harvest()
                if let orig = origRef {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, orig)
                }
            } else {
                harvest()
            }

            return collected.sorted { $0.mtcSeconds < $1.mtcSeconds }
        }
        return nil
    }

    private func extractMarkersMTC(from table: AXUIElement) -> [ScannedMarker] {
        var seenPtrs = Set<UnsafeRawPointer>()
        var rows: [AXUIElement] = []
        func addRows(_ newRows: [AXUIElement]) {
            for r in newRows {
                let ptr = Unmanaged.passUnretained(r).toOpaque()
                if seenPtrs.insert(ptr).inserted { rows.append(r) }
            }
        }
        if let r = axArray(of: table, key: kAXRowsAttribute)       { addRows(r) }
        if let r = axArray(of: table, key: kAXVisibleRowsAttribute) { addRows(r) }
        if rows.isEmpty, let r = axArray(of: table, key: kAXChildrenAttribute) { addRows(r) }

        var markers: [ScannedMarker] = []
        var skipCount = 0
        for row in rows {
            let cells = axArray(of: row, key: kAXChildrenAttribute) ?? []
            guard cells.count >= 3 else { skipCount += 1; continue }

            // 위치: cells[1] → AXGroup.desc = "01:00:04:00.00"
            guard let posChildren = axArray(of: cells[1], key: kAXChildrenAttribute),
                  let posGroup = posChildren.first(where: {
                      (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup"
                  }),
                  let posText = axString(posGroup, key: kAXDescriptionAttribute),
                  let mtc = parseMTC(posText) else {
                // 파싱 실패한 행의 구조 덤프
                let desc0 = axString(cells[0], key: kAXDescriptionAttribute) ?? "-"
                let desc1 = axString(cells[1], key: kAXDescriptionAttribute) ?? "-"
                let desc2 = axString(cells[2], key: kAXDescriptionAttribute) ?? "-"
                debugLog("[MarkerSkip] cells.count=\(cells.count) c0='\(desc0)' c1='\(desc1)' c2='\(desc2)'")
                skipCount += 1
                continue
            }

            // 이름: cells[2] → AXCell.desc
            guard let nameChildren = axArray(of: cells[2], key: kAXChildrenAttribute),
                  let nameCell = nameChildren.first(where: {
                      (axString($0, key: kAXRoleAttribute) ?? "") == "AXCell"
                  }) else { skipCount += 1; continue }
            let name = (axString(nameCell, key: kAXDescriptionAttribute) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { skipCount += 1; continue }

            markers.append(ScannedMarker(name: name, isSong: name.hasPrefix("#"), mtcSeconds: mtc, barHint: 0))
        }
        debugLog("[extractMarkersMTC] rows=\(rows.count) parsed=\(markers.count) skipped=\(skipCount)")
        return markers
    }

    // MARK: 템포 목록 읽기 (MTC)
    private func readTemposMTC(axApp: AXUIElement) -> [ScannedTempo]? {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return nil }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard title.contains("템포"), !title.contains("트랙") else { continue }
            guard let table = findByRole(window, "AXTable") else { return nil }

            let scrollContainer = findByRole(window, "AXScrollArea") ?? window
            let scrollBar = axArray(of: scrollContainer, key: kAXVerticalScrollBarAttribute as String)?.first
                         ?? findByRole(scrollContainer, "AXScrollBar")

            var collected: [ScannedTempo] = []
            var seenKeys = Set<String>()

            func harvest() {
                for t in extractTemposMTC(from: table) {
                    if seenKeys.insert("\(t.mtcSeconds)").inserted { collected.append(t) }
                }
            }

            if let sb = scrollBar {
                var origRef: CFTypeRef?
                AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &origRef)
                for pos in stride(from: 0.0, through: 1.0, by: 0.1) {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, pos as CFTypeRef)
                    Thread.sleep(forTimeInterval: 0.08)
                    harvest()
                }
                AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 1.0 as CFTypeRef)
                Thread.sleep(forTimeInterval: 0.08)
                harvest()
                if let orig = origRef {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, orig)
                }
            } else {
                harvest()
            }

            return collected.sorted { $0.mtcSeconds < $1.mtcSeconds }
        }
        return nil
    }

    private func extractTemposMTC(from table: AXUIElement) -> [ScannedTempo] {
        var seenPtrs = Set<UnsafeRawPointer>()
        var rows: [AXUIElement] = []
        func addRows(_ r: [AXUIElement]) {
            for row in r {
                let ptr = Unmanaged.passUnretained(row).toOpaque()
                if seenPtrs.insert(ptr).inserted { rows.append(row) }
            }
        }
        if let r = axArray(of: table, key: kAXRowsAttribute)       { addRows(r) }
        if let r = axArray(of: table, key: kAXVisibleRowsAttribute) { addRows(r) }
        if rows.isEmpty, let r = axArray(of: table, key: kAXChildrenAttribute) { addRows(r) }

        var tempos: [ScannedTempo] = []
        for row in rows {
            let cells = axArray(of: row, key: kAXChildrenAttribute) ?? []
            guard cells.count >= 3 else { continue }
            guard let barChildren = axArray(of: cells[0], key: kAXChildrenAttribute),
                  let barGroup = barChildren.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup" }),
                  let barText = axString(barGroup, key: kAXDescriptionAttribute),
                  let barPos = parseBarBeat(barText) else { continue }
            guard let bpmChildren = axArray(of: cells[1], key: kAXChildrenAttribute),
                  let bpmGroup = bpmChildren.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup" }),
                  let bpmText = axString(bpmGroup, key: kAXDescriptionAttribute),
                  let bpm = Double(bpmText.trimmingCharacters(in: .whitespaces)) else { continue }
            guard let mtcChildren = axArray(of: cells[2], key: kAXChildrenAttribute),
                  let mtcGroup = mtcChildren.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup" }),
                  let mtcText = axString(mtcGroup, key: kAXDescriptionAttribute),
                  let mtc = parseMTC(mtcText) else { continue }
            tempos.append(ScannedTempo(bpm: bpm, mtcSeconds: mtc, barPosition: Double(barPos.bar)))
        }
        return tempos
    }

    // MARK: 조표/박자표 목록 읽기 (마디 위치 → MTC 변환)
    private func readTimeSigsAndKeySigsMTC(axApp: AXUIElement,
                                            tempos: [ScannedTempo]) -> ([ScannedTimeSig], [ScannedKeySig]) {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return ([], []) }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard title.contains("조표 및 박자표 목록") else { continue }
            guard let table = findByRole(window, "AXTable") else { return ([], []) }

            let scrollArea = findByRole(window, "AXScrollArea")
            let scrollBar = scrollArea.flatMap {
                axArray(of: $0, key: kAXVerticalScrollBarAttribute as String)?.first
                ?? findByRole($0, "AXScrollBar")
            }

            var rawTimeSigs: [(bar: Double, numerator: Int, denominator: Int)] = []
            var rawKeySigs:  [(bar: Double, name: String)] = []
            var seenKeys = Set<String>()

            func harvest() {
                for item in extractTimeSigsAndKeySigs(from: table) {
                    let key = "\(item.kind)_\(item.bar)"
                    if seenKeys.insert(key).inserted {
                        if item.kind == "ts" { rawTimeSigs.append((bar: item.bar, numerator: item.n, denominator: item.d)) }
                        else                 { rawKeySigs.append((bar: item.bar, name: item.name)) }
                    }
                }
            }

            if let sb = scrollBar {
                var origRef: CFTypeRef?
                AXUIElementCopyAttributeValue(sb, kAXValueAttribute as CFString, &origRef)
                for pos in stride(from: 0.0, through: 1.0, by: 0.1) {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, pos as CFTypeRef)
                    Thread.sleep(forTimeInterval: 0.08)
                    harvest()
                }
                AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 1.0 as CFTypeRef)
                Thread.sleep(forTimeInterval: 0.08)
                harvest()
                if let orig = origRef {
                    AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, orig)
                }
            } else {
                harvest()
            }

            let timeSigs = rawTimeSigs.map { ev in
                ScannedTimeSig(numerator: ev.numerator,
                               denominator: ev.denominator,
                               mtcSeconds: barToMTC(ev.bar, tempos: tempos, rawTimeSigs: rawTimeSigs))
            }.sorted { $0.mtcSeconds < $1.mtcSeconds }

            let keySigs = rawKeySigs.map { ev in
                ScannedKeySig(name: ev.name,
                              mtcSeconds: barToMTC(ev.bar, tempos: tempos, rawTimeSigs: rawTimeSigs))
            }.sorted { $0.mtcSeconds < $1.mtcSeconds }

            return (timeSigs, keySigs)
        }
        return ([], [])
    }

    private struct TSKSItem {
        let kind: String  // "ts" or "ks"
        let bar: Double
        let n: Int; let d: Int  // 박자용
        let name: String        // 조표용
    }

    private func extractTimeSigsAndKeySigs(from table: AXUIElement) -> [TSKSItem] {
        var seenPtrs = Set<UnsafeRawPointer>()
        var rows: [AXUIElement] = []
        func addRows(_ r: [AXUIElement]) {
            for row in r {
                let ptr = Unmanaged.passUnretained(row).toOpaque()
                if seenPtrs.insert(ptr).inserted { rows.append(row) }
            }
        }
        if let r = axArray(of: table, key: kAXRowsAttribute)       { addRows(r) }
        if let r = axArray(of: table, key: kAXVisibleRowsAttribute) { addRows(r) }
        if rows.isEmpty, let r = axArray(of: table, key: kAXChildrenAttribute) { addRows(r) }

        var items: [TSKSItem] = []
        for row in rows {
            let cells = axArray(of: row, key: kAXChildrenAttribute) ?? []
            guard cells.count >= 2 else { continue }

            // 3셀(위치, 유형, 값) 또는 2셀(유형, 값) 모두 처리
            let bar: Double; let typeIdx: Int; let valueIdx: Int
            if cells.count >= 3,
               let posChildren = axArray(of: cells[0], key: kAXChildrenAttribute),
               let posGroup = posChildren.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup" }),
               let posText = axString(posGroup, key: kAXDescriptionAttribute),
               let pos = parseBarBeat(posText) {
                // 위치 있는 행
                bar = Double(pos.bar); typeIdx = 1; valueIdx = 2
            } else if cells.count >= 3 {
                // 3셀이지만 위치 비어있음 (프로젝트 시작 기본값 행)
                bar = 1; typeIdx = 1; valueIdx = 2
            } else {
                // 2셀 행
                bar = 1; typeIdx = 0; valueIdx = 1
            }

            guard let typeChildren = axArray(of: cells[typeIdx], key: kAXChildrenAttribute),
                  let typeCell = typeChildren.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXCell" }) else { continue }
            let typeText = axString(typeCell, key: kAXDescriptionAttribute) ?? ""

            if typeText == "박자" {
                let vc = axArray(of: cells[valueIdx], key: kAXChildrenAttribute) ?? []
                guard let slider = vc.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXSlider" }),
                      let num = axNumber(slider).map({ Int(round($0)) }), num > 0 else { continue }
                let denomStr = vc.compactMap { el -> String? in
                    guard (axString(el, key: kAXRoleAttribute) ?? "") == "AXPopUpButton" else { return nil }
                    return axString(el, key: kAXValueAttribute)
                }.first ?? "/4"
                let den = Int(denomStr.replacingOccurrences(of: "/", with: "")) ?? 4
                items.append(TSKSItem(kind: "ts", bar: bar, n: num, d: den, name: ""))
            } else if typeText == "키" {
                let vc = axArray(of: cells[valueIdx], key: kAXChildrenAttribute) ?? []
                let keyName = vc.compactMap { el -> String? in
                    guard (axString(el, key: kAXRoleAttribute) ?? "") == "AXPopUpButton" else { return nil }
                    return axString(el, key: kAXValueAttribute)
                }.first ?? ""
                guard !keyName.isEmpty else { continue }
                items.append(TSKSItem(kind: "ks", bar: bar, n: 0, d: 0, name: parseKey(keyName)))
            }
        }
        return items
    }

    // MARK: 마디 → MTC 변환 (tempo.barPosition을 anchor로 사용)
    private func barToMTC(_ targetBar: Double,
                           tempos: [ScannedTempo],
                           rawTimeSigs: [(bar: Double, numerator: Int, denominator: Int)]) -> Double {
        guard !tempos.isEmpty else { return 0 }
        let tempo   = tempos.last(where: { $0.barPosition <= targetBar }) ?? tempos[0]
        let tsInRange = rawTimeSigs.filter { $0.bar > tempo.barPosition && $0.bar <= targetBar }.sorted { $0.bar < $1.bar }
        var segBPB  = rawTimeSigs.last(where: { $0.bar <= tempo.barPosition })?.numerator ?? 4
        var accMTC  = tempo.mtcSeconds
        var segBar  = tempo.barPosition
        let secPerBeat: Double = 60.0 / tempo.bpm
        for ts in tsInRange {
            let bars: Double = ts.bar - segBar
            let beats: Double = bars * Double(segBPB)
            accMTC += beats * secPerBeat
            segBar  = ts.bar
            segBPB  = ts.numerator
        }
        let remainBars: Double = targetBar - segBar
        let remainBeats: Double = remainBars * Double(segBPB)
        accMTC += remainBeats * secPerBeat
        return accMTC
    }

    // MARK: MTC → 마디 역산 (barHint 계산용)
    private func mtcToBar(_ targetMTC: Double,
                           tempos: [ScannedTempo],
                           rawTimeSigs: [(bar: Double, numerator: Int, denominator: Int)]) -> Double {
        guard !tempos.isEmpty else { return 1 }
        let tempo = tempos.last(where: { $0.mtcSeconds <= targetMTC }) ?? tempos[0]
        let bpb   = Double(rawTimeSigs.last(where: { $0.bar <= tempo.barPosition })?.numerator ?? 4)
        let elapsed = targetMTC - tempo.mtcSeconds
        return tempo.barPosition + elapsed / (bpb * (60.0 / tempo.bpm))
    }

    // 조표/박자표 목록에서 박자 이벤트만 간단히 읽기 (barHint 계산 전용)
    private func rawTimeSigsForBarHint(axApp: AXUIElement) -> [(bar: Double, numerator: Int, denominator: Int)] {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return [] }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard title.contains("조표 및 박자표 목록"),
                  let table = findByRole(window, "AXTable") else { continue }
            let rows = axArray(of: table, key: kAXRowsAttribute)
                    ?? axArray(of: table, key: kAXChildrenAttribute) ?? []
            var result: [(bar: Double, numerator: Int, denominator: Int)] = []
            for row in rows {
                let cells = axArray(of: row, key: kAXChildrenAttribute) ?? []
                guard cells.count >= 3 else { continue }
                guard let pc = axArray(of: cells[0], key: kAXChildrenAttribute),
                      let pg = pc.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup" }),
                      let pt = axString(pg, key: kAXDescriptionAttribute),
                      let pos = parseBarBeat(pt) else { continue }
                guard let tc = axArray(of: cells[1], key: kAXChildrenAttribute),
                      let tCell = tc.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXCell" }),
                      (axString(tCell, key: kAXDescriptionAttribute) ?? "") == "박자" else { continue }
                let vc = axArray(of: cells[2], key: kAXChildrenAttribute) ?? []
                guard let slider = vc.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXSlider" }),
                      let num = axNumber(slider).map({ Int(round($0)) }), num > 0 else { continue }
                let denomStr = vc.compactMap { el -> String? in
                    guard (axString(el, key: kAXRoleAttribute) ?? "") == "AXPopUpButton" else { return nil }
                    return axString(el, key: kAXValueAttribute)
                }.first ?? "/4"
                let denom = Int(denomStr.replacingOccurrences(of: "/", with: "")) ?? 4
                result.append((bar: Double(pos.bar), numerator: num, denominator: denom))
            }
            return result.sorted { $0.bar < $1.bar }
        }
        return []
    }

    // MARK: MTC 문자열 → 초 변환
    // "HH:MM:SS:FF.sf" → seconds (25fps 고정)
    private func parseMTC(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let colonParts = trimmed.components(separatedBy: ":")
        guard colonParts.count == 4,
              let hh = Double(colonParts[0]),
              let mm = Double(colonParts[1]),
              let ss = Double(colonParts[2]) else { return nil }
        let frameParts = colonParts[3].components(separatedBy: ".")
        guard let ff = Double(frameParts[0]) else { return nil }
        let sf = frameParts.count > 1 ? Double(frameParts[1]) ?? 0 : 0
        return hh * 3600 + mm * 60 + ss + ff / 25.0 + sf / 2500.0
    }

    // MARK: - Parsers

    // "HH:MM:SS:FF.sub" → 초 (프레임 무시)
    private func parseMTCSeconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 4,
              let hh = Double(parts[0]),
              let mm = Double(parts[1]),
              let ss = Double(parts[2].split(separator: ".").first.map(String.init) ?? parts[2])
        else { return nil }
        return hh * 3600 + mm * 60 + ss
    }

    private func parseBarBeat(_ s: String) -> (bar: Int, beat: Int)? {
        let nums = s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2, nums[0] > 0, nums[0] < 10000, nums[1] > 0 else { return nil }
        return (nums[0], nums[1])
    }

    // "C 메이저" → "C",  "A 마이너" → "Am",  "F# 메이저" → "F#"
    private func parseKey(_ s: String) -> String {
        let parts = s.split(separator: " ")
        guard let root = parts.first.map(String.init) else { return s }
        let isMinor = s.contains("마이너")
        return isMinor ? root + "m" : root
    }

    private func parseTimeSigNumerator(_ s: String) -> Int? {
        let parts = s.split(separator: "/")
        guard let n = parts.first.flatMap({ Int($0) }), n > 0 else { return nil }
        return n
    }

    // MARK: - AX helpers

    // Find first descendant matching desc exactly
    private func findByDesc(_ root: AXUIElement, _ target: String) -> AXUIElement? {
        if (axString(root, key: kAXDescriptionAttribute) ?? "") == target { return root }
        guard let children = axArray(of: root, key: kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = findByDesc(child, target) { return found }
        }
        return nil
    }

    // Find first child of `el` whose desc matches (non-recursive)
    private func findByDescAmongChildren(of el: AXUIElement, desc target: String) -> AXUIElement? {
        guard let children = axArray(of: el, key: kAXChildrenAttribute) else { return nil }
        for child in children {
            if (axString(child, key: kAXDescriptionAttribute) ?? "") == target { return child }
            // One level deeper to handle the nested group structure
            if let sub = axArray(of: child, key: kAXChildrenAttribute) {
                for s in sub {
                    if (axString(s, key: kAXDescriptionAttribute) ?? "") == target { return s }
                }
            }
        }
        return nil
    }

    private func findByRole(_ root: AXUIElement, _ role: String) -> AXUIElement? {
        if (axString(root, key: kAXRoleAttribute) ?? "") == role { return root }
        guard let children = axArray(of: root, key: kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = findByRole(child, role) { return found }
        }
        return nil
    }

    private func axNumber(_ el: AXUIElement) -> Double? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        if let d = ref as? Double { return d }
        if let i = ref as? Int    { return Double(i) }
        if let s = ref as? String { return Double(s) }
        return nil
    }

    private func axArray(of el: AXUIElement, key: String) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement] else { return nil }
        return arr
    }

    private func axString(_ el: AXUIElement, key: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    // MARK: - Debug dump

    private func dumpElement(_ el: AXUIElement, indent: Int, maxDepth: Int, into out: inout String) {
        let pad   = String(repeating: "  ", count: indent)
        let role  = axString(el, key: kAXRoleAttribute)       ?? "?"
        let desc  = axString(el, key: kAXDescriptionAttribute) ?? ""
        let val   = axString(el, key: kAXValueAttribute)       ?? ""
        let title = axString(el, key: kAXTitleAttribute)       ?? ""
        out += "\(pad)[\(role)] title=\(title) desc=\(desc) val=\(val)\n"
        guard indent < maxDepth,
              let children = axArray(of: el, key: kAXChildrenAttribute) else { return }
        for child in children { dumpElement(child, indent: indent + 1, maxDepth: maxDepth, into: &out) }
    }
}
