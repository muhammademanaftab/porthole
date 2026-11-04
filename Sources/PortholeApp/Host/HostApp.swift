import AppKit
import CoreGraphics
import PortholeCore

@MainActor
final class HostApp: NSObject {
    let config = HostConfig.loadOrCreate()
    lazy var server = LiveKitServer(config: config)
    let host = HostRoom()
    var http: HTTPServer?
    let pairing = PairingDesk(budgetFile: HostConfig.directory.appendingPathComponent("pairing-budget.json"))
    lazy var trust = HostTrust(desk: pairing, config: config)
    lazy var guests = HostGuests(config: config)
    let heartbeats = Heartbeats()
    let status = StatusBox()
    var statusTimer: Timer?
    let settings = HostSettings(lookup: { UserDefaults.standard.object(forKey: $0) })
    var state = "Starting…"
    var isGallery = false
    var started = false
    let wholeMacUI = WholeMacUI()
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    var browserLink: String {
        viewerLink(host: tailscaleAddress() ?? ProcessInfo.processInfo.hostName, port: config.httpPort, password: config.password)
    }

    func start(environment env: [String: String]) {
        guard !started else { return }
        started = true
        let previous = HostFiles.readMarker()
        HostFiles.clearMarker()
        Log.info("host started version=\(LocalStatus.version) launchedBy=\(env[WatchdogReason.envKey] == nil ? "user" : "watchdog") previousExit=\(previous?.rawValue ?? "none")", .host)
        if let reason = env[WatchdogReason.envKey] { Log.info("launched by the watchdog, reason=\(reason)", .watchdog) }
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
        refresh()
        Log.info("permissions: screen recording \(CGPreflightScreenCaptureAccess()), accessibility \(InputInjector.isTrusted), keep running \(keep) (watchdog \(KeepRunning.describe(KeepRunning.status)))", .host)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !InputInjector.isTrusted { InputInjector.requestTrust() }
        host.companionsEnabled = { CompanionRules.enabled(stored: UserDefaults.standard.object(forKey: CompanionRules.settingKey), environment: env) }
        host.onRestart = { [weak self] who, hasOpenWindow in self?.restartRequested(by: who, hasOpenWindow: hasOpenWindow, watched: keep) }
        setUpWholeMac(environment: env)
        startStatus(watched: keep)
        Task { await start() }
    }

    func startStatus(watched: Bool) {
        status.start { [weak self] in self.map { LocalStatus.snapshot($0, watched: watched) } ?? [:] }
        let box = status
        let t = Timer(timeInterval: StatusBox.interval, repeats: true) { _ in
            MainActor.assumeIsolated { box.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    func restartRequested(by who: String, hasOpenWindow: Bool, watched: Bool) -> String? {
        switch restartDecision(hasOpenWindow: hasOpenWindow, agentEnabled: watched && KeepRunning.isEnabled) {
        case .refuse(let why):
            Log.info("restart from \(who) refused: \(why)", .host)
            return why
        case .restart:
            Log.info("restart requested by \(who); quitting so the watchdog relaunches", .host)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.quitHost(marker: .remote) }
            return nil
        }
    }

    func start() async {
        do {
            try server.start()
            guard await server.waitUntilReady() else { throw NSError(domain: "Porthole", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "livekit-server did not start; see \(HostConfig.directory.path)/livekit.log"]) }
            let box = status
            let http = try HTTPServer(config: config, pairing: pairing, trust: trust, guests: guests,
                                      allowControl: { RemoteControlSwitch.enabled(stored: UserDefaults.standard.object(forKey: RemoteControlSwitch.settingKey)) },
                                      status: { box.fresh() })
            http.onFailure = { [weak self] msg in self?.state = "Error: \(msg)"; self?.refresh() }
            http.start()
            self.http = http
            let keys = AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret)
            host.onChange = { [weak self] in self?.refresh(); self?.host.wholeMacChanged() }
            trust.attach(to: host)
            guests.attach(to: host)
            guests.onChange = { [weak self] in self?.refresh() }
            try await host.connect(url: "ws://127.0.0.1:\(config.livekitPort)") {
                keys.make(identity: "host", room: "porthole", canPublish: true)
            }
            state = "Sharing"
            Log.info("host ready", .host); print("Porthole host ready.\n  Browser: \(browserLink)\n  Mac viewer: porthole-view \(tailscaleAddress() ?? "<this-mac>") \(config.password)")
            fflush(stdout)
        } catch {
            state = "Error: \(error.localizedDescription)"
            print("Porthole host failed: \(error.localizedDescription)")
            fflush(stdout)
        }
        refresh()
    }

    var menuModel: HostMenuModel {
        HostMenuModel(state: state, macName: HTTPServer.computerName,
                      address: tailscaleAddress(), shared: host.sharedWindows, screenLocked: Session.isScreenLocked,
                      screenRecording: CGPreflightScreenCaptureAccess(), accessibility: InputInjector.isTrusted,
                      paired: trust.store.devices().count, shareLinks: guests.links.count, allowControl: guests.allowControl,
                      controlOverridden: guests.switchOverridden, asks: guests.pendingAsks.map { ($0.who, $0.link.label) })
    }

    var menuSymbol: String {
        state.hasPrefix("Error") ? "exclamationmark.triangle" : host.openWindowCount > 0 ? "macwindow.on.rectangle" : "macwindow"
    }

    var menuToolTip: String { hostMenuTitle(state: state, openWindows: host.openWindowCount) }

    func refresh() { onRefresh?() }

    @objc func copyLink() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(browserLink, forType: .string) }
    @objc func copyPassword() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.password, forType: .string) }
    @objc func pairViewer() { trust.presentNewCode() }
    @objc func showPairedMacs() { trust.showPaired() }
    @objc func shareWindow() { guests.showShareWindow(picker: false) }
    @objc func sharePicker() { guests.showShareWindow(picker: true) }
    @objc func showSharedLinks() { guests.showLinks() }
    @objc func toggleAllowControl() { guard !GuardedPanel.currentEventInjected else { return }; guests.setAllowControl(!guests.allowControl) }
    @objc func allowAsk(_ item: NSMenuItem) { guard !GuardedPanel.currentEventInjected else { return }; if let who = item.representedObject as? String { guests.answer(who, allow: true) } }
    @objc func denyAsk(_ item: NSMenuItem) { if let who = item.representedObject as? String { guests.answer(who, allow: false) } }
    @objc func openScreenSettings() { HostSystemSettings.openScreenRecording() }
    @objc func openAXSettings() { HostSystemSettings.openAccessibility() }
    @objc func showSettings() { onSettings?() }
    @objc func quit() { if let onQuit { onQuit() } else { quitHost(marker: .quit) } }

    func quitHost(marker: ExitMarker) {
        guard !isGallery, started else { NSApp.terminate(nil); return }
        HostFiles.writeMarker(marker)
        Log.info("quitting (\(marker.rawValue))", .host)
        liftCurtain()
        host.stage.release()
        server.stop()
        NSApp.terminate(nil)
    }

    func willTerminate() {
        guard !isGallery, started else { return }
        HostFiles.writeMarker(.session, unlessPresent: true)
        Log.info("terminating (\(HostFiles.readMarker()?.rawValue ?? ExitMarker.session.rawValue))", .host)
        liftCurtain()
        host.stage.release()
        Log.flush()
    }
}

enum HostSignals {
    nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []

    static func install() {
        sources = [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")].map { number, name in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Log.signalled(name)
                LiveKitServer.shared?.stop()
                Log.flush()
                exit(0)
            }
            source.resume()
            return source
        }
    }
}
