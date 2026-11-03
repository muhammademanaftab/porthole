import AppKit
import CoreGraphics
import PortholeCore

@MainActor
final class HostApp: NSObject, NSApplicationDelegate {
    let config = HostConfig.loadOrCreate()
    lazy var server = LiveKitServer(config: config)
    let host = HostRoom()
    var http: HTTPServer?
    let pairing = PairingDesk()
    var pairingWindow: PairingWindow?
    var statusItem: NSStatusItem?
    var state = "Starting…"

    var browserLink: String {
        viewerLink(host: tailscaleAddress() ?? ProcessInfo.processInfo.hostName, port: config.httpPort, password: config.password)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        LoginAgent.installOnFirstRun()
        if !LoginAgent.launchedByAgent && LoginAgent.isInstalled {
            Log.info("handing over to the login agent")
            LoginAgent.handOver()
            exit(0)
        }
        if let exe = Bundle.main.executableURL?.path {
            let others = Processes.running(executable: exe)
            if !others.isEmpty { Log.info("stopping older host instance(s) \(others)"); Processes.stop(others) }
        }
        setUpMenu()
        Log.info("permissions: screen recording \(CGPreflightScreenCaptureAccess()), accessibility \(InputInjector.isTrusted), launched by agent \(LoginAgent.launchedByAgent)")
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !InputInjector.isTrusted { InputInjector.requestTrust() }
        Task { await start() }
    }

    func start() async {
        do {
            try server.start()
            guard await server.waitUntilReady() else { throw NSError(domain: "Porthole", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "livekit-server did not start; see \(HostConfig.directory.path)/livekit.log"]) }
            let http = try HTTPServer(config: config, pairing: pairing)
            http.onFailure = { [weak self] msg in self?.state = "Error: \(msg)"; self?.refresh() }
            http.start()
            self.http = http
            let keys = AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret)
            host.onChange = { [weak self] in self?.refresh() }
            try await host.connect(url: "ws://127.0.0.1:\(config.livekitPort)") {
                keys.make(identity: "host", room: "porthole", canPublish: true)
            }
            state = "Sharing"
            Log.info("host ready"); print("Porthole host ready.\n  Browser: \(browserLink)\n  Mac viewer: porthole-view \(tailscaleAddress() ?? "<this-mac>") \(config.password)")
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
        menu.addItem(withTitle: hostMenuTitle(state: state, openWindows: n), action: nil, keyEquivalent: "")
        if Session.isScreenLocked { menu.addItem(withTitle: "Screen is locked: viewers can watch but not type", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Browser Link", action: #selector(copyLink), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Copy Password", action: #selector(copyPassword), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pair a New Viewer…", action: #selector(pairViewer), keyEquivalent: "p").target = self
        menu.addItem(.separator())
        let perms = menu.addItem(withTitle: "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "on" : "OFF, click to fix")",
                                 action: #selector(openScreenSettings), keyEquivalent: "")
        perms.target = self
        let ax = menu.addItem(withTitle: "Accessibility: \(InputInjector.isTrusted ? "on" : "OFF, click to fix")",
                              action: #selector(openAXSettings), keyEquivalent: "")
        ax.target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginAgent.isInstalled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Porthole Host", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
    }

    @objc func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(browserLink, forType: .string) }
    @objc func copyPassword() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.password, forType: .string) }
    @objc func pairViewer() {
        let w = pairingWindow ?? PairingWindow(desk: pairing)
        pairingWindow = w
        w.present()
    }
    @objc func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleLogin() {
        if LoginAgent.isInstalled { LoginAgent.uninstall() } else { LoginAgent.install() }
        refresh()
    }
    @objc func quit() { host.stage.release(); server.stop(); NSApp.terminate(nil) }

    func applicationWillTerminate(_ note: Notification) { host.stage.release() }
}

signal(SIGTERM) { _ in LiveKitServer.shared?.stop(); exit(0) }
signal(SIGINT) { _ in LiveKitServer.shared?.stop(); exit(0) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = HostApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
