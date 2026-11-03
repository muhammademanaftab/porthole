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
    lazy var trust = HostTrust(desk: pairing, config: config)
    var statusItem: NSStatusItem?
    var settingsWindow: SettingsWindow?
    let heartbeats = Heartbeats()
    let settings = HostSettings(lookup: { UserDefaults.standard.object(forKey: $0) })
    var state = "Starting…"

    var browserLink: String {
        viewerLink(host: tailscaleAddress() ?? ProcessInfo.processInfo.hostName, port: config.httpPort, password: config.password)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        HostFiles.clearMarker()
        let env = ProcessInfo.processInfo.environment
        if let reason = env[WatchdogReason.envKey] { Log.info("launched by the watchdog, reason=\(reason)") }
        let fromLegacy = LegacyAgent.launchedUs
        if !fromLegacy { LegacyAgent.bootOut() }
        LegacyAgent.removeFiles()
        if let exe = Bundle.main.executableURL?.path {
            let others = Processes.hosts(executable: exe)
            if !others.isEmpty { Log.info("stopping older host instance(s) \(others)"); Processes.stop(others) }
        }
        let keep = settings.keepRunningThisRun(environment: env)
        let overridden = ["0", "1"].contains(env[HostSettings.overrideEnvKey] ?? "")
        heartbeats.start(watched: keep)
        if overridden { Log.info("\(HostSettings.overrideEnvKey)=\(env[HostSettings.overrideEnvKey] ?? "") for this run: the watchdog \(keep ? "watches" : "ignores") this host; the saved switch is unchanged") }
        else { KeepRunning.apply(keep) }
        if fromLegacy {
            if KeepRunning.isEnabled {
                HostFiles.writeMarker(.migrate)
                LegacyAgent.bootOutSelf()
                return
            }
            Log.info("launched by the old login agent but the watchdog is \(KeepRunning.describe(KeepRunning.status)); staying up")
        }
        setUpMenu()
        Log.info("permissions: screen recording \(CGPreflightScreenCaptureAccess()), accessibility \(InputInjector.isTrusted), keep running \(keep) (watchdog \(KeepRunning.describe(KeepRunning.status)))")
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !InputInjector.isTrusted { InputInjector.requestTrust() }
        host.onRestart = { [weak self] who, hasOpenWindow in self?.restartRequested(by: who, hasOpenWindow: hasOpenWindow, watched: keep) }
        Task { await start() }
    }

    func restartRequested(by who: String, hasOpenWindow: Bool, watched: Bool) -> String? {
        switch restartDecision(hasOpenWindow: hasOpenWindow, agentEnabled: watched && KeepRunning.isEnabled) {
        case .refuse(let why):
            Log.info("restart from \(who) refused: \(why)")
            return why
        case .restart:
            Log.info("restart requested by \(who); quitting so the watchdog relaunches")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.quitHost(marker: .remote) }
            return nil
        }
    }

    func start() async {
        do {
            try server.start()
            guard await server.waitUntilReady() else { throw NSError(domain: "Porthole", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "livekit-server did not start; see \(HostConfig.directory.path)/livekit.log"]) }
            let http = try HTTPServer(config: config, pairing: pairing, trust: trust)
            http.onFailure = { [weak self] msg in self?.state = "Error: \(msg)"; self?.refresh() }
            http.start()
            self.http = http
            let keys = AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret)
            host.onChange = { [weak self] in self?.refresh() }
            trust.attach(to: host)
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
        menu.addItem(withTitle: "Paired Macs…", action: #selector(showPairedMacs), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let perms = menu.addItem(withTitle: "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "on" : "OFF, click to fix")",
                                 action: #selector(openScreenSettings), keyEquivalent: "")
        perms.target = self
        let ax = menu.addItem(withTitle: "Accessibility: \(InputInjector.isTrusted ? "on" : "OFF, click to fix")",
                              action: #selector(openAXSettings), keyEquivalent: "")
        ax.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Porthole Host", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem?.menu = menu
    }

    @objc func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(browserLink, forType: .string) }
    @objc func copyPassword() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.password, forType: .string) }
    @objc func pairViewer() { trust.presentNewCode() }
    @objc func showPairedMacs() { trust.showPaired() }
    @objc func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func showSettings() {
        let w = settingsWindow ?? SettingsWindow(link: { [unowned self] in browserLink }, password: { [unowned self] in config.password })
        settingsWindow = w
        w.present()
    }
    @objc func quit() { quitHost(marker: .quit) }

    func quitHost(marker: ExitMarker) {
        HostFiles.writeMarker(marker)
        Log.info("quitting (\(marker.rawValue))")
        host.stage.release()
        server.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) {
        HostFiles.writeMarker(.session, unlessPresent: true)
        host.stage.release()
        Log.flush()
    }
}

switch HostCommand.parse(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment) {
case .agentPlist:
    FileHandle.standardOutput.write(LaunchAgent.plistData(executableName: Bundle.main.executableURL?.lastPathComponent ?? "porthole-host") ?? Data())
case .watchdog:
    WatchdogRunner.run()
case .app:
    if let status = HostCLI.run(Array(CommandLine.arguments.dropFirst())) { exit(status) }
    signal(SIGTERM) { _ in LiveKitServer.shared?.stop(); exit(0) }
    signal(SIGINT) { _ in LiveKitServer.shared?.stop(); exit(0) }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = HostApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
