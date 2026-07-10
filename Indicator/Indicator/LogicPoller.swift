import Cocoa
import ApplicationServices

class LogicPoller {

    static let bundleID = "com.apple.logic10"

    var onSnapshot: ((LogicSnapshot) -> Void)?
    var onScanFailed: ((String) -> Void)?
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
        // 500ms마다 bar/beat 보정 (정지 중 재생헤드 이동 포함)
        let t = DispatchSource.makeTimerSource(queue: syncQueue)
        t.schedule(deadline: .now() + 1, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.readBarBeatOnly() }
        t.resume()
        driftTimer = t

    }

    func stop() {
        driftTimer?.cancel()
        driftTimer = nil
        axPermissionTimer?.cancel()
        axPermissionTimer = nil
    }

    private var axPermissionTimer: DispatchSourceTimer?

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
        // 마커 목록 창이 닫혀 있으면 사전 스캔 데이터로 대체 (스캔 후 창 닫는 워크플로우 지원)
        if snapshot.markers.isEmpty, let sched = ScheduleStore.shared.current {
            snapshot.markers = sched.markers.map {
                Marker(name: $0.name, mtcSeconds: $0.mtcSeconds, bar: $0.barHint)
            }
        }
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

    // MARK: - 프로젝트 전환 감지
    // 스캔 당시의 프로젝트명(트랙 창 제목)을 기억해두고, 정지 중 폴링에서 주기적으로
    // 비교 — 다른 프로젝트가 열려 있으면 옛 스캔 데이터로 오동작하므로 재스캔 경고
    private var scannedProjectTitle: String?
    private var projectCheckCounter = 0
    private var projectMismatchNotified = false

    private func currentProjectTitle(axApp: AXUIElement) -> String? {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return nil }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard containsAny(title, LX.tracksTitle),
                  !containsAny(title, LX.markerListTitle),
                  !containsAny(title, LX.signatureListTitle) else { continue }
            // "<프로젝트명> - 트랙" / "<name> - Tracks" → 프로젝트명만
            if let range = title.range(of: " - ", options: .backwards) {
                return String(title[..<range.lowerBound])
            }
            return title
        }
        return nil
    }

    private func checkProjectSwitch(axApp: AXUIElement) {
        projectCheckCounter += 1
        guard projectCheckCounter % 10 == 0 else { return }   // 500ms × 10 = 5초마다
        guard let scanned = scannedProjectTitle, !projectMismatchNotified,
              ScheduleStore.shared.current != nil,
              let cur = currentProjectTitle(axApp: axApp), cur != scanned else { return }
        projectMismatchNotified = true
        debugLog("[ProjectSwitch] '\(scanned)' → '\(cur)' — 재스캔 필요")
        DispatchQueue.main.async {
            self.onScanFailed?("다른 프로젝트가 열려 있습니다('\(cur)') — 다시 스캔하세요")
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
        // 마커가 없으면 스킵 (수동 스캔 전까지 대기)
        guard !cachedMarkers.isEmpty else { return }

        guard AXIsProcessTrusted() else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var snapshot = lastSnapshot ?? LogicSnapshot()
        snapshot.markers        = cachedMarkers
        snapshot.chords         = cachedChords
        snapshot.timeSigEvents  = cachedTimeSigEvents
        readTransport(axApp: axApp, into: &snapshot)
        checkProjectSwitch(axApp: axApp)

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
            guard let outerBar = findByDescAny(window, LX.controlBar),
                  let innerBar = findByDescAmongChildrenAny(of: outerBar, descs: LX.controlBar)
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
                eq(axString($0, key: kAXDescriptionAttribute), LX.playheadPosition)
            }
            if let posGroup = posGroups.first,
               let barSlider  = findByDescAny(posGroup, LX.bar),
               let beatSlider = findByDescAny(posGroup, LX.beat) {
                if let bar  = axNumber(barSlider),  bar  >= 1 { snapshot.transportBar  = Int(bar)  }
                if let beat = axNumber(beatSlider), beat >= 1 { snapshot.transportBeat = Int(beat) }
            }
            if posGroups.count >= 2,
               eq(axString(posGroups[1], key: kAXDescriptionAttribute), LX.playheadPosition),
               let tcStr = axString(posGroups[1], key: kAXValueAttribute) ?? axString(posGroups[1], key: kAXTitleAttribute) {
                if let tc = parseMTCSeconds(tcStr) { snapshot.transportMTC = tc }
            }

            // BPM
            if let tempoSlider = findByDescAny(innerBar, LX.tempo),
               let bpm = axNumber(tempoSlider), bpm > 20, bpm < 500 {
                snapshot.bpm = bpm
            }

            // Time signature  (val = "4/4")
            if let tsButton = findByDescAny(innerBar, LX.timeSigButton),
               let val = axString(tsButton, key: kAXValueAttribute) {
                snapshot.timeSignature = val
                if let num = parseTimeSigNumerator(val) {
                    snapshot.beatsPerBar = num
                }
            }

            // Key signature  (val = "C 메이저", "G 메이저", "A 마이너" / "C Major" …)
            if let keyButton = findByDescAny(innerBar, LX.keySigButton),
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
            guard containsAny(title, LX.tracksTitle), !containsAny(title, LX.markerListTitle), !containsAny(title, LX.signatureListTitle) else { continue }
            debugLog("[Chord] found track window: \(title)")
            guard let ruler = findByDescAny(window, LX.trackRuler) else {
                debugLog("[Chord] 트랙 시간 눈금자 not found"); continue
            }
            guard let track = findByDescAny(ruler, LX.chordTrack) else {
                debugLog("[Chord] 코드 트랙 not found"); continue
            }
            let groups = axArray(of: track, key: kAXChildrenAttribute)?
                .filter { d in LX.chordGroupPrefix.contains { (axString(d, key: kAXDescriptionAttribute) ?? "").lowercased().hasPrefix($0.lowercased()) } } ?? []
            debugLog("[Chord] found \(groups.count) chord groups")

            var chords: [ChordEvent] = []
            for group in groups {
                guard let container = findByDescAny(group, LX.chordContainer),
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
        guard let barIdx = tokens.firstIndex(where: { eq($0, LX.bar) }), barIdx > 0,
              let bar = Int(tokens[barIdx - 1]) else { return nil }

        // beat: "마디" 다음에 숫자 "비트" 순서
        var beat = 1
        if barIdx + 2 < tokens.count, eq(tokens[barIdx + 2], LX.beat),
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
            guard containsAny(title, LX.markerListTitle) else { continue }
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
            guard containsAny(title, LX.signatureListTitle) else { continue }
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

            if eq(typeDesc, LX.sigTypeTime) {
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

            } else if eq(typeDesc, LX.sigTypeKey) {
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

    private func fail(_ msg: String) {
        DispatchQueue.main.async {
            debugLog(msg)
            self.onScanFailed?(msg)
        }
    }

    private func scanMTC() {
        guard AXIsProcessTrusted() else {
            fail("접근성 권한이 없어요")
            return
        }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID).first else {
            fail("Logic Pro가 실행중이지 않아요")
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // 1. 마커 읽기 (MTC 직접)
        switch readMarkersMTC(axApp: axApp) {
        case nil:
            fail("마커 목록 창을 열어주세요 (탐색 → 마커 목록 열기)")
            return
        case let m? where m.isEmpty:
            fail("마커 목록 > 보기 > '이벤트 위치 및 길이를 시간으로 표시' 체크 후 다시 스캔하세요")
            return
        case let m?:
            break
        }
        let markers = readMarkersMTC(axApp: axApp)!

        // 2. 템포 읽기 (MTC 직접)
        guard let tempos = readTemposMTC(axApp: axApp), !tempos.isEmpty else {
            fail("템포 목록 창을 열어주세요 (탐색 → 템포 목록 열기)")
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

        // 프로젝트 전환 감지용 기준 저장
        scannedProjectTitle = currentProjectTitle(axApp: axApp)
        projectMismatchNotified = false

        let schedule = ScannedSchedule(
            markers:   markersWithBar,
            tempos:    tempos,
            timeSigs:  timeSigs,
            keySigs:   keySigs,
            scannedAt: Date(),
            fps:       SMPTEConfig.fps
        )
        DispatchQueue.main.async { ScheduleStore.shared.save(schedule: schedule) }
        debugLog("[Scan] 완료: 마커 \(markers.count)개, 템포 \(tempos.count)개, 박자 \(timeSigs.count)개, 조표 \(keySigs.count)개, fps \(SMPTEConfig.fps)")
    }

    // MARK: 마커 목록 읽기 (MTC)
    private func readMarkersMTC(axApp: AXUIElement) -> [ScannedMarker]? {
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return nil }
        for window in windows {
            let title = axString(window, key: kAXTitleAttribute) ?? ""
            guard containsAny(title, LX.markerListTitle) else { continue }
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
            guard containsAny(title, LX.tempoListTitle), !containsAny(title, LX.tracksTitle) else { continue }
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
            guard containsAny(title, LX.signatureListTitle) else { continue }
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

            if eq(typeText, LX.sigTypeTime) {
                let vc = axArray(of: cells[valueIdx], key: kAXChildrenAttribute) ?? []
                guard let slider = vc.first(where: { (axString($0, key: kAXRoleAttribute) ?? "") == "AXSlider" }),
                      let num = axNumber(slider).map({ Int(round($0)) }), num > 0 else { continue }
                let denomStr = vc.compactMap { el -> String? in
                    guard (axString(el, key: kAXRoleAttribute) ?? "") == "AXPopUpButton" else { return nil }
                    return axString(el, key: kAXValueAttribute)
                }.first ?? "/4"
                let den = Int(denomStr.replacingOccurrences(of: "/", with: "")) ?? 4
                items.append(TSKSItem(kind: "ts", bar: bar, n: num, d: den, name: ""))
            } else if eq(typeText, LX.sigTypeKey) {
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
            guard containsAny(title, LX.signatureListTitle),
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
    // "HH:MM:SS:FF.sf" → seconds
    // fps는 MTC 수신부가 디코딩한 프로젝트 프레임레이트(SMPTEConfig.fps) 사용.
    // MTC 수신 전 스캔이면 기본 25fps — 이후 fps 불일치가 감지되면 재스캔 경고 표시.
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
        let fps = SMPTEConfig.fps
        return hh * 3600 + mm * 60 + ss + (ff + sf / 100.0) / fps
    }

    // MARK: - Parsers

    // "HH:MM:SS:FF.sub" → 초 (프레임·서브프레임 포함)
    // 주의: 예전엔 프레임을 버려서 마커 시각이 항상 최대 1초(≈2박) 일찍 잡혔음 —
    // 카운트다운·섹션 전환이 마커마다 다르게 일찍 나오던 원인.
    private func parseMTCSeconds(_ s: String) -> Double? {
        return parseMTC(s)
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
        let isMinor = LX.minorMarkers.contains { s.lowercased().contains($0.lowercased()) }
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

    // ── 한/영 Logic UI 문자열 대응 ──────────────────────────
    // Logic의 AX 문자열은 시스템 언어를 따라가므로, 영어 macOS에서도 동작하도록
    // 모든 매칭을 후보 목록(한국어 + 영어)에 대해 대소문자 무시로 수행한다.
    private func eq(_ s: String?, _ candidates: [String]) -> Bool {
        guard let v = s?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else { return false }
        return candidates.contains { v == $0.lowercased() }
    }
    private func containsAny(_ s: String, _ candidates: [String]) -> Bool {
        let v = s.lowercased()
        return candidates.contains { v.contains($0.lowercased()) }
    }
    private func findByDescAny(_ root: AXUIElement, _ targets: [String]) -> AXUIElement? {
        if eq(axString(root, key: kAXDescriptionAttribute), targets) { return root }
        guard let children = axArray(of: root, key: kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = findByDescAny(child, targets) { return found }
        }
        return nil
    }

    // Logic 한국어/영어 UI 문자열 후보 (영어 문자열은 영어 Logic에서 확인 필요 시 여기만 수정)
    private enum LX {
        static let playheadPosition = ["재생헤드 위치", "playhead position"]
        static let bar              = ["마디", "bar"]
        static let beat             = ["비트", "beat"]
        static let tempo            = ["템포", "tempo"]
        static let timeSigButton    = ["박자표", "time signature"]
        static let keySigButton     = ["조표", "key signature"]
        static let markerListTitle  = ["마커 목록", "marker list"]
        static let tempoListTitle   = ["템포", "tempo"]
        static let signatureListTitle = ["조표 및 박자표 목록", "signature list"]
        static let tracksTitle      = ["트랙", "tracks"]
        static let sigTypeTime      = ["박자", "time"]
        static let sigTypeKey       = ["키", "key"]
        static let minorMarkers     = ["마이너", "단조", "minor"]
        static let controlBar       = ["컨트롤 막대", "control bar"]
        static let trackRuler       = ["트랙 시간 눈금자", "tracks time ruler", "track time ruler"]
        static let chordTrack       = ["코드 트랙", "chord track"]
        static let chordGroupPrefix = ["코드 그룹", "chord group"]
        static let chordContainer   = ["코드 컨테이너", "chord container"]
    }

    // Find first child of `el` whose desc matches (non-recursive, 두 단계 깊이까지)
    private func findByDescAmongChildrenAny(of el: AXUIElement, descs targets: [String]) -> AXUIElement? {
        guard let children = axArray(of: el, key: kAXChildrenAttribute) else { return nil }
        for child in children {
            if eq(axString(child, key: kAXDescriptionAttribute), targets) { return child }
            // One level deeper to handle the nested group structure
            if let sub = axArray(of: child, key: kAXChildrenAttribute) {
                for s in sub {
                    if eq(axString(s, key: kAXDescriptionAttribute), targets) { return s }
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
