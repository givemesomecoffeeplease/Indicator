import Cocoa
import SwiftUI
import Darwin

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
        setupMenuBar()

        logicPoller.onSnapshot = { [weak self] snapshot in
            self?.stateEngine.update(snapshot: snapshot)
        }
        mtcReceiver.onTimeUpdate = { [weak self] time in
            self?.stateEngine.updateMTC(time: time)
        }
        stateEngine.onStateChange = { [weak self] state in
            self?.webServer.broadcast(state: state)
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
        menu.addItem(NSMenuItem(title: "설정...", action: #selector(openSettings), keyEquivalent: ","))
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
