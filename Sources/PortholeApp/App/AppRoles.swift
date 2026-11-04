import AppKit
import PortholeCore

extension ViewerApp {
    func startRoles() -> Bool {
        let saved = Self.savedHosting()
        var on = HostingSwitch.thisRun(saved: saved, environment: environment)
        if HostingSwitch.overridden(environment) {
            VLog.info("\(HostingSwitch.envKey)=\(environment[HostingSwitch.envKey] ?? "") for this run: \(on ? "sharing" : "not sharing") this Mac; the saved switch (\(saved ? "on" : "off")) is unchanged")
        }
        if on && !mayHost {
            VLog.info("started from a shell with arguments, not by Launch Services: viewing only; this run doesn't share this Mac")
            on = false
        }
        menuBar = MenuBar(app: self)
        watchPresence()
        watchSessionEnd()
        KeychainCache.warm()
        if on { startHosting() } else if mayHost { idle() }
        updatePresence()
        return on
    }

    func watchSessionEnd() {
        presenceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionEnding = true
                VLog.info("the session is ending (log out, restart or shut down)")
            }
        })
    }

    static func savedHosting() -> Bool {
        let d = UserDefaults.standard
        let (on, decided) = HostingSwitch.saved(stored: d.object(forKey: HostingSwitch.settingKey)) {
            HostingSwitch.firstRunDefault(
                hasHostConfig: HostConfig.saved() != nil,
                oldHostInstalled: OneApp.oldHostApps().contains { FileManager.default.fileExists(atPath: $0.path) },
                watchdogLoaded: LegacyAgent.launchctl(["print", "gui/\(getuid())/\(LaunchAgent.label)"]) == 0,
                watchdogRunning: !Processes.running(named: CLITool.host.rawValue, argument: "watchdog").isEmpty)
        }
        if decided {
            d.set(on, forKey: HostingSwitch.settingKey)
            VLog.info("first launch as one app: Share this Mac \(on ? "on (this Mac ran Porthole Host)" : "off")")
        }
        return on
    }

    func idle() {
        if !HostingSwitch.overridden(environment) { KeepRunning.apply(false) }
        if KeepRunning.isEnabled || KeepRunning.watchdogRunning {
            VLog.info("not sharing this Mac while its watchdog is registered; telling it not to watch this run")
            idleBeats.start(watched: false)
        }
    }

    func setHosting(_ on: Bool) {
        guard on != (hosting != nil) else { return }
        if on {
            UserDefaults.standard.set(true, forKey: HostingSwitch.settingKey)
            VLog.info("settings: share this Mac on")
            startHosting()
            return
        }
        guard let h = hosting, h.started else {
            UserDefaults.standard.set(false, forKey: HostingSwitch.settingKey)
            hosting = nil
            return
        }
        let alert = NSAlert()
        alert.messageText = "Stop sharing this Mac?"
        alert.informativeText = "Porthole quits and opens again without sharing. Windows that other Macs have open from this one close, and so do the windows you are viewing here."
        alert.addButton(withTitle: "Stop Sharing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            settingsWindow?.refresh()
            return
        }
        UserDefaults.standard.set(false, forKey: HostingSwitch.settingKey)
        VLog.info("settings: share this Mac off; restarting without the host role")
        KeepRunning.apply(false)
        relaunch()
        h.quitHost(marker: .quit)
    }

    func startHosting() {
        guard hosting == nil else { return }
        guard mayHost else {
            VLog.info("not sharing this Mac from a run started in a shell; open Porthole from Finder or the Dock to share it")
            return
        }
        KeychainCache.mainMayPrompt = false
        let h = HostApp()
        hosting = h
        h.onRefresh = { [weak self] in self?.menuBar?.refresh() }
        h.onSettings = { [weak self] in self?.showSettings(tab: .sharing) }
        h.onQuit = { [weak self] in self?.quitApp() }
        h.start(environment: environment)
        updatePresence()
        menuBar?.refresh()
        settingsWindow?.refresh()
    }

    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "porthole-relaunch",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    @objc func quitApp() {
        if let h = hosting, h.started { h.quitHost(marker: .quit) } else { NSApp.terminate(nil) }
    }

    @objc func showSharingSettings() { showSettings(tab: .sharing) }

    var viewerWindowCount: Int {
        NSApp.windows.filter { ($0 is PickerWindow || $0 is ConnectWindow || $0 is PortalWindow) && ($0.isVisible || $0.isMiniaturized) }.count
    }

    var dockWindowCount: Int {
        let shown = NSApp.windows.filter {
            ($0 is PickerWindow || $0 is ConnectWindow || $0 is PortalWindow || $0 is SettingsWindow || $0 is PairingWindow
                || $0 is PairedMacsWindow || $0 is CodeSheet || $0.sheetParent != nil) && ($0.isVisible || $0.isMiniaturized)
        }.count
        return shown + (NSApp.modalWindow == nil ? 0 : 1)
    }

    func updatePresence(adding window: NSWindow? = nil) {
        let sharing = hosting.map { !$0.isGallery } ?? false
        let dock = Presence.dockIcon(hosting: sharing, viewerWindows: dockWindowCount + (window == nil ? 0 : 1))
        let wanted: NSApplication.ActivationPolicy = dock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        VLog.info("dock icon \(dock ? "shown: a window is open" : "hidden: only sharing this Mac")")
        guard dock else { return }
        if dockActivated { NSApp.activate() } else {
            dockActivated = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func watchPresence() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification] {
            presenceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updatePresence() } }
            })
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard viewerWindowCount == 0 else { return true }
        if picker != nil { showPicker() } else { showConnect(address: connection?.hostAddress) }
        return true
    }

    func showGallery(_ screen: String) {
        guard !galleryScreens.contains(screen) else {
            NSApp.setActivationPolicy(.regular)
            Gallery.show(screen)
            return
        }
        let h = HostApp()
        h.isGallery = true
        hosting = h
        HostGallery.show(screen, host: h, app: self)
    }
}
