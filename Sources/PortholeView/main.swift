import AppKit
import LiveKit
import PortholeCore

@MainActor
final class ViewerApp: NSObject, NSApplicationDelegate {
    var connection: Connection?
    var picker: PickerWindow?
    var portals: [UInt32: PortalWindow] = [:]
    var titles: [UInt32: String] = [:]
    var clip = ClipboardSync(changeCount: NSPasteboard.general.changeCount)
    var clipTimer: Timer?
    let tiles = TileManager()
    var icons: [UInt32: Data] = [:]
    var muted = false
    var connectWindow: ConnectWindow?
    let discovery = HostDiscovery()

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpMainMenu()
        tiles.onActivate = { [weak self] id in self?.raise(id) }
        tiles.onQuit = { [weak self] id in self?.portals[id]?.close() }
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        let args = viewerArguments(Array(CommandLine.arguments.dropFirst()))
        if let host = args.host, let pw = args.password {
            connect(host: host, credential: .password(pw))
            return
        }
        let host = args.host ?? UserDefaults.standard.string(forKey: "host")
        if let host, let (cred, id) = PasswordStore.credential(for: host) {
            connect(host: host, credential: cred, saved: true, hostID: id)
        } else {
            showConnect(address: host, ask: args.host.map { askText(nil, $0) })
        }
    }

    func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Windows on Host", action: #selector(showPicker), keyEquivalent: "")
        appMenu.addItem(withTitle: "Connect to Host…", action: #selector(connectToHost), keyEquivalent: "")
        appMenu.addItem(withTitle: "Mute Host Sound", action: #selector(toggleMute(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Restart Host", action: #selector(restartHost), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Porthole", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc func showPicker() { picker?.makeKeyAndOrderFront(nil); connection?.requestList() }
    @objc func toggleMute(_ item: NSMenuItem) {
        muted.toggle()
        item.state = muted ? .on : .off
        connection?.muted = muted
    }

    @objc func restartHost() {
        guard let c = connection else { return }
        let alert = NSAlert()
        alert.messageText = "Restart Porthole Host on \(c.hostAddress)?"
        alert.informativeText = "Every window open from that Mac closes, for all viewers. Its watchdog starts it again in a few seconds."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        c.send(Message(.restart))
    }

    @objc func connectToHost() { showConnect(address: connection?.hostAddress) }

    func showConnect(address: String?, ask: String? = nil) {
        let w = connectWindow ?? makeConnectWindow()
        w.cancelQuits = connection == nil
        if let address { w.fill(address) }
        if let ask { w.ask(ask) }
        discovery.start()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func makeConnectWindow() -> ConnectWindow {
        let w = ConnectWindow()
        connectWindow = w
        discovery.onChange = { [weak self, weak w] in
            guard let self, let w else { return }
            w.show(self.discovery.hosts, scanning: self.discovery.scanning, preferTailscale: self.discovery.tailscaleRunning,
                   hasAccess: PasswordStore.hasAccess)
        }
        w.onRefresh = { [weak self] in self?.discovery.refresh() }
        w.onCancel = { [weak self, weak w] in
            guard let self else { return }
            if self.connection == nil { NSApp.terminate(nil) }
            w?.close()
            self.discovery.stop()
        }
        w.onSubmit = { [weak self] address, name, secret in self?.submit(address: address, name: name, secret: secret) }
        w.onRequestPairing = { [weak self] address, name in self?.requestPairing(address: address, name: name) }
        return w
    }

    func askText(_ name: String?, _ address: String) -> String {
        "Type the pairing code from \(name ?? address): on that Mac, click the Porthole Host menu-bar icon and choose Pair a New Viewer…. Its password works too."
    }

    func requestPairing(address: String, name: String?) {
        guard let w = connectWindow else { return }
        w.setBusy(true, "Asking…")
        Task {
            let reply = await HostDiscovery.requestPairing(address: address, device: PasswordStore.device.id, name: PasswordStore.deviceName)
            w.setBusy(false)
            switch reply {
            case .shown(let host):
                w.ask("\(host) is showing a pairing code for this Mac. Type it here; after that this Mac can view it without a password.")
            case .older:
                w.ask(askText(name, address))
            case .refused(let why):
                w.ask(askText(name, address))
                w.showError(why)
            }
        }
    }

    func submit(address: String, name: String?, secret: String?) {
        guard let w = connectWindow else { return }
        guard splitHostAddress(address) != nil else {
            w.showError("\"\(address)\" isn't a host address. Use a name or IP, optionally with :port.")
            return
        }
        guard let secret, !secret.isEmpty else {
            if let (cred, id) = PasswordStore.credential(for: address) {
                startConnection(address: address, name: name, credential: cred, saved: true, hostID: id)
            } else {
                requestPairing(address: address, name: name)
            }
            return
        }
        guard looksLikePairingCode(secret) else {
            startConnection(address: address, name: name, credential: .password(secret), saved: false)
            return
        }
        w.setBusy(true)
        Task {
            let device = PasswordStore.device
            let reply = await HostDiscovery.pair(address: address, code: secret, device: device.id, name: PasswordStore.deviceName)
            w.setBusy(false)
            switch reply {
            case .paired(let deviceSecret, let id, let hostName):
                let key = hostKeyForTrust(hostID: id, address: address)
                guard PasswordStore.savePairing(hostID: key, name: hostName ?? name ?? address, address: address, secret: deviceSecret) else {
                    w.showError("Paired, but the Keychain refused to keep the pairing. Try again.")
                    return
                }
                startConnection(address: address, name: name ?? hostName, credential: .device(id: device.id, secret: deviceSecret),
                                saved: true, hostID: key)
            case .password(let pw): startConnection(address: address, name: name, credential: .password(pw), saved: false)
            case .refused(let why): w.showError(why)
            }
        }
    }

    func startConnection(address: String, name: String?, credential: ViewerCredential, saved: Bool, hostID: String? = nil) {
        connectWindow?.close()
        discovery.stop()
        connect(host: address, credential: credential, name: name, saved: saved, hostID: hostID)
    }

    func connect(host: String, credential: ViewerCredential, name: String? = nil, saved: Bool = false, hostID: String? = nil) {
        for p in portals.values { p.close() }
        if let old = connection { Task { await old.disconnect() } }
        picker?.close()
        let c = Connection(hostAddress: host, credential: credential)
        connection = c
        c.muted = muted
        let picker = PickerWindow(hostName: name ?? host) { [weak self] info in self?.open(info) } refresh: { [weak c] in c?.requestList() }
        self.picker = picker
        picker.makeKeyAndOrderFront(nil)
        NSApp.activate()
        c.onWindows = { [weak self, weak picker] list in
            picker?.show(list)
            self?.autoOpen(list)
        }
        c.onError = { [weak picker] msg in picker?.showError(msg); picker?.orderFront(nil) }
        c.onClosed = { [weak self] id in self?.portals[id]?.close() }
        c.onClipboard = { [weak self] text in self?.clipboardFromHost(text) }
        c.onIcon = { [weak self] id, png in self?.icons[id] = png }
        c.onReconnected = { [weak self, weak c, weak picker] in
            guard let self, let c, self.connection === c else { return }
            picker?.showError("Reconnected.")
            c.requestList()
            for (id, portal) in self.portals { c.open(id) { track, _ in portal.attach(track) } }
        }
        Task {
            do {
                try await c.connect()
                UserDefaults.standard.set(host, forKey: "host")
                if case .password(let password) = credential, !PasswordStore.save(password, for: host) {
                    UserDefaults.standard.set(password, forKey: "password")
                }
                PasswordStore.knownHosts = rememberHost(PasswordStore.knownHosts, KnownHost(name: name ?? host, address: host))
                for _ in 0..<50 where c.hostParticipant == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                c.requestList()
            } catch {
                picker.showError(error.localizedDescription)
                let err = error as NSError
                if err.domain == "Porthole" && err.code == 403, case .device = credential {
                    if let hostID { PasswordStore.forgetPairing(hostID: hostID) }
                    showConnect(address: host, ask: err.localizedDescription + " Click Connect to ask \(name ?? host) for a new code.")
                } else if saved && err.domain == "Porthole" && err.code == 401 {
                    showConnect(address: host, ask: "The saved password for \(name ?? host) was refused. " + askText(name, host))
                }
            }
        }
    }

    var autoOpenMatch = ProcessInfo.processInfo.environment["PORTHOLE_OPEN"]

    func autoOpen(_ list: [WindowInfo]) {
        guard let match = autoOpenMatch?.lowercased(), !match.isEmpty,
              let info = list.first(where: { "\($0.app) \($0.title)".lowercased().contains(match) }) else { return }
        autoOpenMatch = nil
        open(info)
    }

    func open(_ info: WindowInfo) {
        if let existing = portals[info.id] { existing.makeKeyAndOrderFront(nil); return }
        guard let c = connection else { return }
        let host = c.hostAddress
        icons[info.id] = nil
        c.requestIcon(info.id)
        c.open(info.id) { [weak self] track, reply in
            guard let self else { return }
            let size = CGSize(width: reply.w ?? info.w, height: reply.h ?? info.h)
            let portal = PortalWindow(windowID: info.id, title: info.portalTitle(host: host), size: size, track: track, connection: c)
            portal.onClose = { [weak self] in
                self?.connection?.close(info.id)
                self?.portals[info.id] = nil
                self?.tiles.remove(info.id)
            }
            self.portals[info.id] = portal
            portal.makeKeyAndOrderFront(nil)
            NSApp.activate()
            self.startTile(info, portal: portal)
        }
    }

    func startTile(_ info: WindowInfo, portal: PortalWindow) {
        Task {
            for _ in 0..<30 where icons[info.id] == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard portals[info.id] === portal else { return }
            tiles.show(win: info.id, app: info.app, icon: icons.removeValue(forKey: info.id) ?? localIcon(info))
        }
    }

    func localIcon(_ info: WindowInfo) -> Data? {
        let image = info.bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        var rect = CGRect(x: 0, y: 0, width: AppIcon.pixels, height: AppIcon.pixels)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap { AppIcon.png(from: $0) }
    }

    func raise(_ id: UInt32) {
        guard let portal = portals[id] else { return }
        if portal.isMiniaturized { portal.deminiaturize(nil) }
        portal.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillTerminate(_ note: Notification) { tiles.removeAll() }

    func pollClipboard() {
        guard !portals.isEmpty, let c = connection else { return }
        let pb = NSPasteboard.general
        guard let text = clip.outgoing(changeCount: pb.changeCount, text: { pb.string(forType: .string) }) else { return }
        c.sendClipboard(text)
    }

    func clipboardFromHost(_ text: String) {
        guard clip.incoming(text) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        clip.applied(changeCount: pb.changeCount)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if let status = ViewerCLI.run(Array(CommandLine.arguments.dropFirst())) { exit(status) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ViewerApp()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
