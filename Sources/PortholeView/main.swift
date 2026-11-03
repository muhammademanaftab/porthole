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

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpMainMenu()
        tiles.onActivate = { [weak self] id in self?.raise(id) }
        tiles.onQuit = { [weak self] id in self?.portals[id]?.close() }
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        let args = viewerArguments(Array(CommandLine.arguments.dropFirst()))
        let defaults = UserDefaults.standard
        let host = args.host ?? defaults.string(forKey: "host")
        let pw = args.password ?? defaults.string(forKey: "password")
        if let host, let pw {
            connect(host: host, password: pw)
        } else {
            askForHost(host: host, password: pw)
        }
    }

    func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Show Windows on Host", action: #selector(showPicker), keyEquivalent: "")
        appMenu.addItem(withTitle: "Change Host…", action: #selector(changeHost), keyEquivalent: "")
        appMenu.addItem(withTitle: "Mute Host Sound", action: #selector(toggleMute(_:)), keyEquivalent: "")
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

    @objc func changeHost() { askForHost(host: UserDefaults.standard.string(forKey: "host"), password: nil) }

    func askForHost(host: String?, password: String?) {
        let alert = NSAlert()
        alert.messageText = "Connect to a Porthole host"
        alert.informativeText = "The host's Tailscale address (or name) and its password, from the host's menu-bar icon."
        let stack = NSStackView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        stack.orientation = .vertical
        let hostField = NSTextField(string: host ?? "leos-mac-mini")
        hostField.placeholderString = "host or 100.x.y.z"
        let pwField = NSSecureTextField(string: password ?? "")
        pwField.placeholderString = "password"
        stack.addArrangedSubview(hostField); stack.addArrangedSubview(pwField)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Quit")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        connect(host: hostField.stringValue, password: pwField.stringValue)
    }

    func connect(host: String, password: String) {
        for p in portals.values { p.close() }
        if let old = connection { Task { await old.disconnect() } }
        picker?.close()
        let c = Connection(hostAddress: host, password: password)
        connection = c
        c.muted = muted
        let picker = PickerWindow(hostName: host) { [weak self] info in self?.open(info) } refresh: { [weak c] in c?.requestList() }
        self.picker = picker
        picker.makeKeyAndOrderFront(nil)
        NSApp.activate()
        c.onWindows = { [weak picker] list in picker?.show(list) }
        c.onError = { [weak picker] msg in picker?.showError(msg) }
        c.onClosed = { [weak self] id in self?.portals[id]?.close() }
        c.onClipboard = { [weak self] text in self?.clipboardFromHost(text) }
        c.onIcon = { [weak self] id, png in self?.icons[id] = png }
        Task {
            do {
                try await c.connect()
                UserDefaults.standard.set(host, forKey: "host")
                UserDefaults.standard.set(password, forKey: "password")
                for _ in 0..<50 where c.hostParticipant == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                c.requestList()
            } catch {
                picker.showError(error.localizedDescription)
            }
        }
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

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ViewerApp()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
