import Cocoa
import SwiftUI
import Darwin
import CoreMIDI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    let mtcReceiver  = MTCReceiver()
    let logicPoller  = LogicPoller()
    let stateEngine  = StateEngine()
    let webServer    = WebServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()
        setupIACDriver()
        setupMenuBar()

        logicPoller.onSnapshot = { [weak self] snapshot in
            self?.stateEngine.update(snapshot: snapshot)
        }
        mtcReceiver.onTimeUpdate = { [weak self] time in
            self?.logicPoller.mtcActive = true
            self?.stateEngine.updateMTC(time: time)
        }
        mtcReceiver.onStop = { [weak self] in
            self?.logicPoller.mtcActive = false
            self?.stateEngine.mtcStopped()
        }
        mtcReceiver.onBeat = { [weak self] in
            self?.stateEngine.onBeat()
        }
        stateEngine.onJump = { [weak self] in
            self?.logicPoller.syncBarBeat()
        }
        stateEngine.onStateChange = { [weak self] state in
            self?.webServer.broadcast(state: state)
        }

        webServer.getMarkers = { [weak self] in
            self?.logicPoller.lastSnapshot?.markers ?? []
        }
        webServer.getLyric = { song, section in
            LyricsStore.shared.get(song: song, section: section)
        }
        webServer.getLyricOcc = { song, section, startBar, canonicalStartBar in
            LyricsStore.shared.resolve(song: song, section: section, startBar: startBar, canonicalStartBar: canonicalStartBar)
        }
        webServer.saveLyrics = { dict in
            LyricsStore.shared.merge(dict)
        }
        webServer.exportSetlist = { [weak self] markers in
            LyricsStore.shared.exportSetlist(markers: markers)
        }
        webServer.exportSong = { name in
            LyricsStore.shared.exportSong(name: name)
        }
        webServer.getSongNames = {
            LyricsStore.shared.songNames()
        }
        webServer.onLyricsSaved = { [weak self] in
            self?.logicPoller.forceUpdate()
        }

        logicPoller.start()
        mtcReceiver.start()
        webServer.start(port: 8888)
    }

    func applicationWillTerminate(_ notification: Notification) {
        logicPoller.stop()
        mtcReceiver.stop()
        webServer.stop()
    }

    // MARK: - IAC Driver

    private func setupIACDriver() {
        var deviceList: Unmanaged<CFPropertyList>?
        MIDIObjectGetProperties(MIDIGetDevice(0), &deviceList, true)

        let deviceCount = MIDIGetNumberOfDevices()
        for i in 0..<deviceCount {
            let device = MIDIGetDevice(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(device, kMIDIPropertyName, &name)
            guard let deviceName = name?.takeRetainedValue() as String?,
                  deviceName == "IAC Driver" else { continue }

            // 온라인 상태로 설정
            MIDIObjectSetIntegerProperty(device, kMIDIPropertyOffline, 0)

            // 포트가 없으면 추가할 수 없으므로 엔티티(포트 그룹) 확인
            let entityCount = MIDIDeviceGetNumberOfEntities(device)
            if entityCount == 0 { break }

            let entity = MIDIDeviceGetEntity(device, 0)
            // 엔티티도 온라인으로
            MIDIObjectSetIntegerProperty(entity, kMIDIPropertyOffline, 0)
            break
        }
    }

    // MARK: - Accessibility

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Menu Bar

    // MARK: - Setup status tags
    private let tagAX      = 100
    private let tagLogic   = 101
    private let tagIAC     = 102
    private let tagMTC     = 103
    private let tagClock   = 104
    private let tagMarkers = 105
    private let tagSchedule = 106

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Indicator")
        }

        let ip = localIP()
        let menu = NSMenu()
        menu.delegate = self

        // ── 설정 상태 체크리스트 ──
        menu.addItem(makeStatusItem("손쉬운 사용 권한", tag: tagAX, action: #selector(openAccessibilitySettings)))
        menu.addItem(makeStatusItem("Logic Pro 실행 중", tag: tagLogic, action: nil))
        menu.addItem(makeStatusItem("IAC Driver 연결됨", tag: tagIAC, action: #selector(openAudioMIDISetup)))
        menu.addItem(makeStatusItem("MTC 수신 중", tag: tagMTC, action: #selector(openLogicSyncSettings)))
        menu.addItem(makeStatusItem("MIDI Clock 수신 중", tag: tagClock, action: #selector(openLogicSyncSettings)))
        menu.addItem(makeStatusItem("마커 목록 창 열림", tag: tagMarkers, action: nil))
        menu.addItem(makeStatusItem("사전 스캔 안 됨 (선택)", tag: tagSchedule, action: #selector(scanSchedule)))
        menu.addItem(.separator())

        let addrItem = NSMenuItem(title: "http://\(ip):8888", action: #selector(copyAddress), keyEquivalent: "")
        addrItem.representedObject = "http://\(ip):8888"
        menu.addItem(addrItem)
        menu.addItem(.separator())
        let editItem = NSMenuItem(title: "가사·노트 편집 열기", action: #selector(openEditPage), keyEquivalent: "")
        editItem.representedObject = "http://\(ip):8888/edit"
        menu.addItem(editItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Master 저장 (전체 내보내기)", action: #selector(saveMaster), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Master 불러오기", action: #selector(loadMaster), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "리더용 템플릿 내보내기", action: #selector(exportLyrics), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "리더 파일 가져오기", action: #selector(importLyrics), keyEquivalent: "i"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "마커/코드 새로고침", action: #selector(refreshMarkers), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "AX 트리 덤프 (디버그)", action: #selector(dumpAXTree), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func makeStatusItem(_ title: String, tag: Int, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        item.target = self
        // 초기 상태는 menuWillOpen에서 채워짐
        updateStatusItem(item, ok: false, title: title)
        return item
    }

    private func updateStatusItem(_ item: NSMenuItem, ok: Bool, title: String) {
        let dot   = ok ? "● " : "○ "
        let color = ok ? NSColor.systemGreen : NSColor.systemRed
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        let base  = NSAttributedString(string: dot, attributes: attrs)
        let rest  = NSAttributedString(string: title,
                                       attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let full  = NSMutableAttributedString(attributedString: base)
        full.append(rest)
        item.attributedTitle = full
        item.action = ok ? nil : item.action  // ok면 클릭 불필요
    }

    // NSMenuDelegate — 메뉴 열릴 때마다 상태 갱신
    func menuWillOpen(_ menu: NSMenu) {
        let axOk      = AXIsProcessTrusted()
        let logicOk   = NSRunningApplication.runningApplications(withBundleIdentifier: LogicPoller.bundleID).first != nil
        // IAC 연결 여부: 현재 MIDI 소스 목록에서 실시간 재확인
        var iacOk = false
        let srcCount = MIDIGetNumberOfSources()
        var srcNames: [String] = []
        for i in 0..<srcCount {
            let src = MIDIGetSource(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyName, &cfName)
            let name = (cfName?.takeRetainedValue() as String?) ?? ""
            srcNames.append(name)
            // 한국어 macOS: "버스 1" / 영어: "IAC Driver Bus 1"
            if name.lowercased().contains("iac") || name.contains("버스") { iacOk = true }
        }
        debugLog("[MIDI Sources] \(srcNames)")
        let mtcOk     = mtcReceiver.mtcReceived
        let clockOk   = mtcReceiver.clockReceived
        let markersOk = !(logicPoller.lastSnapshot?.markers.isEmpty ?? true)

        let checks: [(Int, Bool, String)] = [
            (tagAX,      axOk,      "손쉬운 사용 권한"),
            (tagLogic,   logicOk,   "Logic Pro 실행 중"),
            (tagIAC,     iacOk,     "IAC Driver 연결됨"),
            (tagMTC,     mtcOk,     "MTC 수신 중"),
            (tagClock,   clockOk,   "MIDI Clock 수신 중"),
            (tagMarkers, markersOk, "마커 목록 창 열림"),
        ]
        for (tag, ok, title) in checks {
            if let item = menu.item(withTag: tag) {
                updateStatusItem(item, ok: ok, title: title)
            }
        }

        // 사전 스캔 상태 (3단계: 완료 / 재스캔 필요 / 안 됨 — 선택 기능이라 빨강 대신 회색 사용)
        if let item = menu.item(withTag: tagSchedule) {
            let snap = logicPoller.lastSnapshot
            let liveMarkers = snap?.markers ?? []
            let liveBpm = snap?.bpm ?? 0
            let liveBpb = snap?.beatsPerBar ?? 4
            let liveTS  = snap?.timeSigEvents ?? []
            if ScheduleStore.shared.current == nil {
                updateStatusItemTristate(item, color: .systemGray, title: "사전 스캔 안 됨 (선택)")
            } else if ScheduleStore.shared.isValid(against: liveMarkers, bpm: liveBpm, beatsPerBar: liveBpb, timeSigEvents: liveTS) {
                updateStatusItemTristate(item, color: .systemGreen, title: "사전 스캔 완료")
            } else {
                updateStatusItemTristate(item, color: .systemOrange, title: "마커/템포 변경됨 — 재스캔 필요")
            }
        }
    }

    private func updateStatusItemTristate(_ item: NSMenuItem, color: NSColor, title: String) {
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: NSFont.menuFont(ofSize: 0)]
        let dot  = NSAttributedString(string: "● ", attributes: attrs)
        let rest = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let full = NSMutableAttributedString(attributedString: dot)
        full.append(rest)
        item.attributedTitle = full
    }

    @objc private func scanSchedule() {
        guard let snap = logicPoller.lastSnapshot, !snap.markers.isEmpty else { return }
        ScheduleStore.shared.scan(markers: snap.markers, bpm: snap.bpm, beatsPerBar: snap.beatsPerBar, timeSigEvents: snap.timeSigEvents)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    @objc private func openLogicSyncSettings() {
        let alert = NSAlert()
        alert.messageText = "Logic Pro 동기화 설정"
        alert.informativeText = "Logic Pro → 파일 → 프로젝트 설정 → 동기화 → MIDI 탭\n\nIAC Driver Bus 1 행에서 MTC와 클락(Clock) 체크박스를 모두 활성화하세요."
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        if let addr = sender.representedObject as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(addr, forType: .string)
        }
    }

    @objc private func openEditPage(_ sender: NSMenuItem) {
        if let addr = sender.representedObject as? String,
           let url = URL(string: addr) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "Indicator 설정"
            win.contentView = NSHostingView(rootView: SettingsView())
            win.center()
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveMaster() {
        guard let data = LyricsStore.shared.exportAll() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "master.json"
        panel.allowedContentTypes = [.json]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    @objc private func loadMaster() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            LyricsStore.shared.importJSON(from: url)
            self?.logicPoller.forceUpdate()
        }
    }

    @objc private func exportLyrics() {
        let markers = logicPoller.lastSnapshot?.markers ?? []
        guard let data = LyricsStore.shared.exportTemplate(markers: markers) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "lyrics.json"
        panel.allowedContentTypes = [.json]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    @objc private func importLyrics() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            LyricsStore.shared.importJSON(from: url)
            // Force recompute so browsers get updated state immediately
            self?.logicPoller.forceUpdate()
        }
    }

    @objc private func refreshMarkers() {
        logicPoller.refreshMarkers()
    }

    @objc private func dumpAXTree() {
        logicPoller.dumpAXTree = true
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Network

    private func localIP() -> String {
        let sock = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        defer { Darwin.close(sock) }
        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = 80
        remote.sin_addr.s_addr = inet_addr("8.8.8.8")
        _ = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        return String(cString: inet_ntoa(local.sin_addr))
    }
}
