import Cocoa
import ApplicationServices

class LogicPoller {

    static let bundleID = "com.apple.logic10"

    var onSnapshot: ((LogicSnapshot) -> Void)?
    var dumpAXTree = false
    private(set) var lastSnapshot: LogicSnapshot?

    private var timer: Timer?

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func forceUpdate() {
        if let snap = lastSnapshot {
            DispatchQueue.main.async { self.onSnapshot?(snap) }
        }
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
        readMarkers(axApp: axApp, into: &snapshot)

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
            guard let table = findByRole(window, "AXTable") else { continue }
            let markers = extractMarkers(from: table)
            if !markers.isEmpty {
                snapshot.markers = markers
            }
            return
        }
    }

    private func extractMarkers(from table: AXUIElement) -> [Marker] {
        let rows = axArray(of: table, key: kAXRowsAttribute)
                ?? axArray(of: table, key: kAXChildrenAttribute)
                ?? []

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
