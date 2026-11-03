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
    var connectWindow: ConnectWindow?
    let discovery = HostDiscovery()

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpMainMenu()
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        let args = viewerArguments(Array(CommandLine.arguments.dropFirst()))
        if let host = args.host, let pw = args.password {
            connect(host: host, password: pw)
            return
        }
        let host = args.host ?? UserDefaults.standard.string(forKey: "host")
        if let host, let pw = PasswordStore.password(for: host) {
            connect(host: host, password: pw, savedPassword: true)
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
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Porthole", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc func showPicker() { picker?.makeKeyAndOrderFront(nil); connection?.requestList() }
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
            w.show(self.discovery.hosts, scanning: self.discovery.scanning, preferTailscale: self.discovery.tailscaleRunning)
        }
        w.onRefresh = { [weak self] in self?.discovery.refresh() }
        w.onCancel = { [weak self, weak w] in
            guard let self else { return }
            if self.connection == nil { NSApp.terminate(nil) }
            w?.close()
            self.discovery.stop()
        }
        w.onSubmit = { [weak self] address, name, secret in self?.submit(address: address, name: name, secret: secret) }
        return w
    }

    func askText(_ name: String?, _ address: String) -> String {
        "Type the pairing code from \(name ?? address): on that Mac, click the Porthole Host menu-bar icon and choose Pair a New Viewer…. Its password works too."
    }

    func submit(address: String, name: String?, secret: String?) {
        guard let w = connectWindow else { return }
        guard splitHostAddress(address) != nil else {
            w.showError("\"\(address)\" isn't a host address. Use a name or IP, optionally with :port.")
            return
        }
        guard let secret, !secret.isEmpty else {
            if let pw = PasswordStore.password(for: address) {
                startConnection(address: address, name: name, password: pw, saved: true)
            } else {
                w.ask(askText(name, address))
            }
            return
        }
        guard looksLikePairingCode(secret) else {
            startConnection(address: address, name: name, password: secret, saved: false)
            return
        }
        w.setBusy(true)
        Task {
            let reply = await HostDiscovery.pair(address: address, code: secret)
            w.setBusy(false)
            switch reply {
            case .password(let pw): startConnection(address: address, name: name, password: pw, saved: false)
            case .refused(let why): w.showError(why)
            }
        }
    }

    func startConnection(address: String, name: String?, password: String, saved: Bool) {
        connectWindow?.close()
        discovery.stop()
        connect(host: address, password: password, name: name, savedPassword: saved)
    }

    func connect(host: String, password: String, name: String? = nil, savedPassword: Bool = false) {
        for p in portals.values { p.close() }
        if let old = connection { Task { await old.disconnect() } }
        picker?.close()
        let c = Connection(hostAddress: host, password: password)
        connection = c
        let picker = PickerWindow(hostName: name ?? host) { [weak self] info in self?.open(info) } refresh: { [weak c] in c?.requestList() }
        self.picker = picker
        picker.makeKeyAndOrderFront(nil)
        NSApp.activate()
        c.onWindows = { [weak picker] list in picker?.show(list) }
        c.onError = { [weak picker] msg in picker?.showError(msg) }
        c.onClosed = { [weak self] id in self?.portals[id]?.close() }
        c.onClipboard = { [weak self] text in self?.clipboardFromHost(text) }
        Task {
            do {
                try await c.connect()
                UserDefaults.standard.set(host, forKey: "host")
                if !PasswordStore.save(password, for: host) { UserDefaults.standard.set(password, forKey: "password") }
                PasswordStore.knownHosts = rememberHost(PasswordStore.knownHosts, KnownHost(name: name ?? host, address: host))
                for _ in 0..<50 where c.hostParticipant == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                c.requestList()
            } catch {
                picker.showError(error.localizedDescription)
                if savedPassword && (error as NSError).domain == "Porthole" && (error as NSError).code == 401 {
                    showConnect(address: host, ask: "The saved password for \(name ?? host) was refused. " + askText(name, host))
                }
            }
        }
    }

    func open(_ info: WindowInfo) {
        if let existing = portals[info.id] { existing.makeKeyAndOrderFront(nil); return }
        guard let c = connection else { return }
        let host = c.hostAddress
        c.open(info.id) { [weak self] track, reply in
            guard let self else { return }
            let size = CGSize(width: reply.w ?? info.w, height: reply.h ?? info.h)
            let portal = PortalWindow(windowID: info.id, title: info.portalTitle(host: host), size: size, track: track, connection: c)
            portal.onClose = { [weak self] in
                self?.connection?.close(info.id)
                self?.portals[info.id] = nil
            }
            self.portals[info.id] = portal
            portal.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ViewerApp()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
