import Cocoa
import SwiftUI
import Darwin
import CoreMIDI
import CoreImage
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    let mtcReceiver  = MTCReceiver()
    let logicPoller  = LogicPoller()
    let stateEngine  = StateEngine()
    let webServer    = WebServer()
    var hasAutoScanned = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        debugLog("[App] 시작 v\(version) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // 크래시 원인 추적: 잡히지 않은 예외를 로그에 남김 (Swift 런타임 크래시는 시스템 리포트 참조)
        NSSetUncaughtExceptionHandler { exc in
            debugLog("[CRASH] \(exc.name.rawValue): \(exc.reason ?? "-")\n\(exc.callStackSymbols.joined(separator: "\n"))")
        }

        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()
        setupIACDriver()
        setupMenuBar()

        logicPoller.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            // timeSigEvents가 새로 생겼고 아직 변박 없이 스캔된 상태면 재스캔 예약
            self.stateEngine.update(snapshot: snapshot)
        }
        mtcReceiver.onTimeUpdate = { [weak self] time in
            guard let self else { return }
            self.logicPoller.mtcActive = true
            self.stateEngine.updateMTC(time: time)
        }
        mtcReceiver.onStop = { [weak self] in
            self?.logicPoller.mtcActive = false
            self?.stateEngine.mtcStopped()
            self?.logicPoller.syncBarBeat()  // 정지 직후 즉시 현재 위치 읽기
        }
        mtcReceiver.onBeat = { [weak self] in
            self?.stateEngine.onBeat()
        }
        // 프로젝트 프레임레이트가 스캔 당시와 다르면 마커 시각이 전부 어긋남 → 재스캔 경고
        mtcReceiver.onFPSChange = { [weak self] newFPS in
            guard let self, let schedule = ScheduleStore.shared.current, schedule.fps != newFPS else { return }
            let msg = "프레임레이트 변경 감지(\(schedule.fps) → \(newFPS)fps) — 다시 스캔하세요"
            debugLog("[FPS] \(msg)")
            self.lastScanFailReason = msg
            if let item = self.statusItem?.menu?.item(withTag: self.tagSchedule) {
                self.updateStatusItemTristate(item, color: .systemOrange, title: "⚠️ \(msg)")
            }
        }
        stateEngine.onJump = { [weak self] in
            self?.logicPoller.syncBarBeat()
        }
        stateEngine.onStateChange = { [weak self] state in
            self?.webServer.broadcast(state: state)
        }

        ScheduleStore.shared.onSaved = { [weak self] schedule in
            DispatchQueue.main.async {
                self?.lastScanFailReason = nil
                self?.updateScanResultMenuItem(schedule: schedule)
                // 스캔 데이터로 실시간 스냅샷(마커 폴백) 즉시 갱신 — 목록 창이 닫혀 있어도 뷰어 동작
                self?.logicPoller.forceUpdate()
                // 마디 수·박자표 등이 스캔으로 바뀌었을 수 있으니 이미 열린 편집/뷰어 페이지도
                // 최신 DATA를 다시 받아오도록 알림 (안 하면 새로고침 전까지 옛 박자표로 표시됨)
                self?.webServer.notifyDataChanged()
            }
        }

        logicPoller.onScanFailed = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastScanFailReason = reason
                if let item = self.statusItem?.menu?.item(withTag: self.tagSchedule) {
                    self.updateStatusItemTristate(item, color: .systemOrange, title: "⚠️ \(reason)")
                }
            }
        }

        webServer.getMarkers = {
            (ScheduleStore.shared.current?.markers ?? []).map {
                Marker(name: $0.name, mtcSeconds: $0.mtcSeconds, bar: $0.barHint)
            }
        }
        webServer.getLyric = { song, section in
            LyricsStore.shared.get(song: song, section: section)
        }
        webServer.getLyricOcc = { song, section, occIdx in
            LyricsStore.shared.resolve(song: song, section: section, occIdx: occIdx)
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

        // 디스크에서 복원된 스캔 데이터가 있으면 즉시 스냅샷 반영 (목록 창 닫혀 있어도 뷰어 동작)
        if ScheduleStore.shared.current != nil {
            logicPoller.forceUpdate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("[App] 정상 종료")
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
    private let tagViewers  = 107
    private var lastScanFailReason: String? = nil

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
        menu.addItem(makeStatusItem("뷰어 연결 0대", tag: tagViewers, action: nil))
        menu.addItem(.separator())

        let addrItem = NSMenuItem(title: "http://\(ip):8888", action: #selector(copyAddress), keyEquivalent: "")
        addrItem.representedObject = "http://\(ip):8888"
        menu.addItem(addrItem)
        menu.addItem(NSMenuItem(title: "뷰어 접속 QR 보기", action: #selector(showQRPanel), keyEquivalent: ""))
        menu.addItem(.separator())
        let editItem = NSMenuItem(title: "가사·노트 편집 열기", action: #selector(openEditPage), keyEquivalent: "")
        editItem.representedObject = "http://\(ip):8888/edit"
        menu.addItem(editItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "AX 트리 덤프 (디버그)", action: #selector(dumpAXTree), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "로그 파일 열기", action: #selector(openLogFile), keyEquivalent: ""))
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
        let markersOk = !(ScheduleStore.shared.current?.markers.isEmpty ?? true)

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

        // 사전 스캔 상태 (경고 > 완료 > 안 됨 — fps 불일치/프로젝트 전환 경고가 완료 표시에 덮이지 않도록)
        if let item = menu.item(withTag: tagSchedule) {
            if let reason = lastScanFailReason {
                updateStatusItemTristate(item, color: .systemOrange, title: "⚠️ \(reason)")
            } else if let schedule = ScheduleStore.shared.current {
                let title = "사전 스캔 완료 · 마커 \(schedule.markers.count) / 템포 \(schedule.tempos.count) / 박자 \(schedule.timeSigs.count) / 조표 \(schedule.keySigs.count)"
                updateStatusItemTristate(item, color: .systemGreen, title: title)
            } else {
                updateStatusItemTristate(item, color: .systemGray, title: "사전 스캔 안 됨 (선택)")
            }
        }

        // 뷰어 연결 수
        if let item = menu.item(withTag: tagViewers) {
            let n = webServer.viewerCount
            updateStatusItemTristate(item, color: n > 0 ? .systemGreen : .systemGray, title: "뷰어 연결 \(n)대")
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
        logicPoller.performScan()
    }

    private func updateScanResultMenuItem(schedule: ScannedSchedule) {
        guard let item = statusItem?.menu?.item(withTag: tagSchedule) else { return }
        let title = "사전 스캔 완료 · 마커 \(schedule.markers.count) / 템포 \(schedule.tempos.count) / 박자 \(schedule.timeSigs.count) / 조표 \(schedule.keySigs.count)"
        updateStatusItemTristate(item, color: .systemGreen, title: title)
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

    @objc private func refreshMarkers() {
        logicPoller.refreshMarkers()
    }

    @objc private func dumpAXTree() {
        logicPoller.dumpAXTree = true
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([debugLogURL])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 뷰어 접속 QR

    private var qrWindow: NSWindow?

    @objc private func showQRPanel() {
        let ip = localIP()
        let entries: [(String, String)] = [
            ("밴드 뷰", "http://\(ip):8888/band"),
            ("싱어 뷰", "http://\(ip):8888/singer"),
        ]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 28
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        for (label, url) in entries {
            let col = NSStackView()
            col.orientation = .vertical
            col.spacing = 8
            let title = NSTextField(labelWithString: label)
            title.font = .boldSystemFont(ofSize: 14)
            title.alignment = .center
            let imgView = NSImageView()
            imgView.image = Self.qrImage(for: url, size: 180)
            imgView.translatesAutoresizingMaskIntoConstraints = false
            imgView.widthAnchor.constraint(equalToConstant: 180).isActive = true
            imgView.heightAnchor.constraint(equalToConstant: 180).isActive = true
            let urlLabel = NSTextField(labelWithString: url)
            urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            urlLabel.alignment = .center
            urlLabel.isSelectable = true
            col.addArrangedSubview(title)
            col.addArrangedSubview(imgView)
            col.addArrangedSubview(urlLabel)
            stack.addArrangedSubview(col)
        }

        let win = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "뷰어 접속 — 같은 Wi-Fi에서 카메라로 스캔"
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        win.center()
        win.isReleasedWhenClosed = false
        qrWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private static func qrImage(for string: String, size: CGFloat) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
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
