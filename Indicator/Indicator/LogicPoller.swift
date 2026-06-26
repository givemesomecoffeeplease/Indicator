import Cocoa
import ApplicationServices

class LogicPoller {

    static let bundleID = "com.apple.logic10"

    var onSnapshot: ((LogicSnapshot) -> Void)?
    var dumpAXTree = false
    private(set) var lastSnapshot: LogicSnapshot?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.indicator.poller", qos: .userInitiated)
    private var lastTimeSigRead: Date = .distantPast
    private var cachedTimeSigEvents: [TimeSigEvent] = []
    private var cachedMarkers: [Marker] = []
    private var cachedChords: [ChordEvent] = []

    func refreshMarkers() { cachedMarkers = []; cachedChords = [] }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func forceUpdate() {
        queue.async { [weak self] in self?.poll() }
    }

    // MARK: - Poll

    private func poll() {
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
        snapshot.capturedMTCTime = 0

        readTransport(axApp: axApp, into: &snapshot)
        // 마커는 캐시 없을 때만 읽음 (스크롤 탐색 비용) — 수동 새로고침: refreshMarkers()
        if cachedMarkers.isEmpty {
            readMarkers(axApp: axApp, into: &snapshot)
            if !snapshot.markers.isEmpty { cachedMarkers = snapshot.markers }
        } else {
            snapshot.markers = cachedMarkers
        }
        // 코드는 캐시 없을 때만 읽음 (마커 새로고침과 함께 갱신)
        if cachedChords.isEmpty {
            readChords(axApp: axApp, into: &snapshot)
            if !snapshot.chords.isEmpty { cachedChords = snapshot.chords }
        } else {
            snapshot.chords = cachedChords
        }
        // 변박 이벤트는 1초마다만 읽음 (AX 트리 탐색 비용)
        if Date().timeIntervalSince(lastTimeSigRead) >= 1.0 {
            readTimeSigs(axApp: axApp, into: &snapshot)
            if !snapshot.timeSigEvents.isEmpty { cachedTimeSigEvents = snapshot.timeSigEvents }
            lastTimeSigRead = Date()
        } else {
            snapshot.timeSigEvents = cachedTimeSigEvents
        }

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
        guard let windows = axArray(of: axApp, key: kAXWindowsAttribute) else { return }
        for window in windows {
            guard let outerBar = findByDesc(window, "컨트롤 막대"),
                  let innerBar = findByDescAmongChildren(of: outerBar, desc: "컨트롤 막대")
            else { continue }

            // Bar / Beat
            if let posGroup  = findByDesc(innerBar, "재생헤드 위치"),
               let barSlider  = findByDesc(posGroup, "마디"),
               let beatSlider = findByDesc(posGroup, "비트") {
                if let bar  = axNumber(barSlider),  bar  >= 1 { snapshot.transportBar  = Int(bar)  }
                if let beat = axNumber(beatSlider), beat >= 1 { snapshot.transportBeat = Int(beat) }
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

            return
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
                    let key = "\(m.name)_\(m.bar)_\(m.beat)"
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
                snapshot.markers = collected.sorted { ($0.bar, $0.beat) < ($1.bar, $1.beat) }
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

            guard !nameText.isEmpty, let pos = parseBarBeat(posText) else { continue }
            markers.append(Marker(name: nameText, bar: pos.bar, beat: pos.beat))
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
            let events = extractTimeSigs(from: table)
            if !events.isEmpty { snapshot.timeSigEvents = events }
            return
        }
    }

    private func extractTimeSigs(from table: AXUIElement) -> [TimeSigEvent] {
        let rows = axArray(of: table, key: kAXRowsAttribute)
                ?? axArray(of: table, key: kAXChildrenAttribute)
                ?? []

        var events: [TimeSigEvent] = []
        for row in rows {
            let cells = axArray(of: row, key: kAXChildrenAttribute) ?? []
            guard cells.count >= 3 else { continue }

            // 위치: cells[0] → AXGroup child
            guard let posChildren = axArray(of: cells[0], key: kAXChildrenAttribute),
                  let posGroup = posChildren.first(where: {
                      (axString($0, key: kAXRoleAttribute) ?? "") == "AXGroup"
                  }) else { continue }
            let posText = axString(posGroup, key: kAXDescriptionAttribute) ?? ""
            guard let pos = parseBarBeat(posText) else { continue }

            // 타입: cells[1] → AXCell child → desc == "박자" 만 처리 (키 이벤트 스킵)
            guard let typeChildren = axArray(of: cells[1], key: kAXChildrenAttribute),
                  let typeCell = typeChildren.first(where: {
                      (axString($0, key: kAXRoleAttribute) ?? "") == "AXCell"
                  }),
                  (axString(typeCell, key: kAXDescriptionAttribute) ?? "") == "박자"
            else { continue }

            // 값: cells[2] → AXSlider (분자) + AXPopUpButton val="/N" (분모)
            let valueChildren = axArray(of: cells[2], key: kAXChildrenAttribute) ?? []
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

            events.append(TimeSigEvent(bar: pos.bar, beatsPerBar: numerator, beatUnit: beatUnit))
        }
        return events.sorted { $0.bar < $1.bar }
    }

    // MARK: - Parsers

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
