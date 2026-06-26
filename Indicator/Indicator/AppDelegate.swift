import Cocoa
import SwiftUI
import Darwin
import CoreMIDI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {

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
            self?.stateEngine.updateMTC(time: time)
        }
        mtcReceiver.onStop = { [weak self] in
            self?.stateEngine.mtcStopped()
        }
        mtcReceiver.onBeat = { [weak self] in
            self?.stateEngine.onBeat()
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

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Indicator")
        }

        let ip = localIP()
        let menu = NSMenu()
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
        menu.addItem(NSMenuItem(title: "AX 트리 덤프 (디버그)", action: #selector(dumpAXTree), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
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
