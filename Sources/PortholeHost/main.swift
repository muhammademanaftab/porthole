import AppKit
import CoreGraphics
import PortholeCore

@MainActor
final class HostApp: NSObject, NSApplicationDelegate {
    let config = HostConfig.loadOrCreate()
    lazy var server = LiveKitServer(config: config)
    let host = HostRoom()
    var http: HTTPServer?
    var statusItem: NSStatusItem?
    var state = "Starting…"

    var browserLink: String {
        "http://\(tailscaleAddress() ?? ProcessInfo.processInfo.hostName):\(config.httpPort)/?pw=\(config.password)"
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpMenu()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !InputInjector.isTrusted { InputInjector.requestTrust() }
        Task { await start() }
    }

    func start() async {
        do {
            try server.start()
            guard await server.waitUntilReady() else { throw NSError(domain: "Porthole", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "livekit-server did not start; see \(HostConfig.directory.path)/livekit.log"]) }
            let http = try HTTPServer(config: config)
            http.start()
            self.http = http
            let token = AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret)
                .make(identity: "host", room: "porthole", canPublish: true)
            host.onChange = { [weak self] in self?.refresh() }
            try await host.connect(url: "ws://127.0.0.1:\(config.livekitPort)", token: token)
            state = "Sharing"
            print("Porthole host ready.\n  Browser: \(browserLink)\n  Mac viewer: porthole-view \(tailscaleAddress() ?? "<this-mac>") \(config.password)")
            fflush(stdout)
        } catch {
            state = "Error: \(error.localizedDescription)"
            print("Porthole host failed: \(error.localizedDescription)")
            fflush(stdout)
        }
        refresh()
    }

    func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Porthole")
        statusItem = item
        refresh()
    }

    func refresh() {
        let menu = NSMenu()
        let n = host.openWindowCount
        menu.addItem(withTitle: "Porthole: \(state)\(n > 0 ? " · \(n) window\(n == 1 ? "" : "s") open" : "")", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Browser Link", action: #selector(copyLink), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Copy Password", action: #selector(copyPassword), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let perms = menu.addItem(withTitle: "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "on" : "OFF, click to fix")",
                                 action: #selector(openScreenSettings), keyEquivalent: "")
        perms.target = self
        let ax = menu.addItem(withTitle: "Accessibility: \(InputInjector.isTrusted ? "on" : "OFF, click to fix")",
                              action: #selector(openAXSettings), keyEquivalent: "")
        ax.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Porthole Host", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
    }

    @objc func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(browserLink, forType: .string) }
    @objc func copyPassword() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.password, forType: .string) }
    @objc func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { server.stop(); NSApp.terminate(nil) }
}

signal(SIGTERM) { _ in LiveKitServer.shared?.stop(); exit(0) }
signal(SIGINT) { _ in LiveKitServer.shared?.stop(); exit(0) }

let app = NSApplication.shared
let delegate = HostApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
