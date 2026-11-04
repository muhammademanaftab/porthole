import AppKit
import PortholeCore

enum RoomAdmin {
    static func remove(_ identity: String, config: HostConfig, why: String) async {
        let keys = AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret)
        var attempt = 0
        while true {
            let token = keys.make(identity: "host-admin", room: "porthole", canPublish: false, ttl: 60, roomAdmin: true)
            guard let req = removeParticipantRequest(livekitPort: config.livekitPort, token: token, room: "porthole", identity: identity) else { return }
            let status = (try? await URLSession.shared.data(for: req)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            attempt += 1
            guard let delay = removeRetryDelay(status: status, attempt: attempt) else {
                Log.info("disconnected \(identity) \(why) (status \(status.map(String.init) ?? "none"), \(attempt) \(attempt == 1 ? "try" : "tries"))", .trust)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

func lanAddress() -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
    defer { freeifaddrs(addrs) }
    var found: [NetworkInterface] = []
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        defer { p = cur.pointee.ifa_next }
        guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              cur.pointee.ifa_flags & UInt32(IFF_UP) != 0, cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
        var sin = sockaddr_in()
        memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
        found.append(NetworkInterface(name: String(cString: cur.pointee.ifa_name), ip: UInt32(bigEndian: sin.sin_addr.s_addr)))
    }
    return pickLANAddress(found)
}

func ownAddresses() -> Set<String> {
    var out: Set<String> = ["127.0.0.1", "::1", "localhost"]
    if let local = HTTPServer.localHostName { out.insert(bareHost(local)) }
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return out }
    defer { freeifaddrs(addrs) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        defer { p = cur.pointee.ifa_next }
        guard let sa = cur.pointee.ifa_addr else { continue }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if sa.pointee.sa_family == UInt8(AF_INET) {
            var sin = sockaddr_in()
            memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
            if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil { out.insert(bareHost(String(cString: buf))) }
        } else if sa.pointee.sa_family == UInt8(AF_INET6) {
            var sin6 = sockaddr_in6()
            memcpy(&sin6, sa, MemoryLayout<sockaddr_in6>.size)
            if inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(buf.count)) != nil { out.insert(bareHost(String(cString: buf))) }
        }
    }
    return out
}

@MainActor
final class HostGuests {
    let store = ShareLinkStore(directory: HostConfig.directory)
    private let config: HostConfig
    private weak var host: HostRoom?
    private var sweepTimer: Timer?
    private var shareWindow: ShareWindowPanel?
    private var linksWindow: SharedLinksWindow?
    private var prompts: [String: NSPanel] = [:]
    private var promptLinks: [String: String] = [:]
    private var throttle = AskThrottle()
    private var gate = GuestRoomGate.restored(fileChanged: nil)
    private var expiryTimer: Timer?
    var onChange: (() -> Void)?

    init(config: HostConfig) {
        self.config = config
        let changed = (try? FileManager.default.attributesOfItem(atPath: store.url.path))?[.modificationDate] as? Date
        gate = GuestRoomGate.restored(fileChanged: changed)
    }

    func roomClosed() -> Bool {
        gate.closed(live: store.links(), now: Date())
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        guard let wait = GuestRoomGate.nextExpiry(store.links(), now: Date()) else { return }
        let t = Timer(timeInterval: wait + 0.1, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.expired() } }
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
    }

    private func expired() {
        gate.linkEnded(now: Date())
        sweep()
        changed()
    }

    var allowControl: Bool {
        RemoteControlSwitch.enabled(stored: UserDefaults.standard.object(forKey: RemoteControlSwitch.settingKey))
    }

    var switchOverridden: Bool { RemoteControlSwitch.overridden() }

    func setAllowControl(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: RemoteControlSwitch.settingKey)
        Log.info("settings: allow remote control \(on ? "on" : "off")\(switchOverridden ? " (saved; \(RemoteControlSwitch.envKey) decides this run)" : "")", .trust)
        host?.controlSwitchChanged()
        if allowControl { for who in Array(prompts.keys) { closePrompt(who) } }
        changed()
    }

    func attach(to host: HostRoom) {
        self.host = host
        let store = store
        host.guestLink = { who in GuestIdentity.linkID(who).flatMap { store.link(id: $0) } }
        host.guestControlSwitch = { [weak self] in self?.allowControl ?? false }
        host.shareLinksExist = { [weak self] in self?.roomClosed() ?? !store.links().isEmpty }
        host.onGuestAsk = { [weak self] who, link in self?.ask(who, link) }
        host.onGuestRefused = { [weak self] who in self?.kick(who, why: "(its share link expired or was revoked)") }
        host.onGuestsChanged = { [weak self] in
            guard let self else { return }
            for who in Array(self.prompts.keys) where self.host?.asking[who] == nil { self.closePrompt(who) }
            self.changed()
        }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sweep() } }
        RunLoop.main.add(t, forMode: .common)
        sweepTimer = t
    }

    private func changed() {
        linksWindow?.reload()
        onChange?()
        scheduleExpiry()
        Task { await host?.updateTrackPermissions() }
    }

    var links: [ShareLink] { store.links() }

    func guests(of link: ShareLink) -> [String] {
        host?.guestIdentities.filter { GuestIdentity.linkID($0) == link.id } ?? []
    }

    var pendingAsks: [(who: String, link: ShareLink)] {
        (host?.asking ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func mint(window: WindowInfo?, control: Bool, ttl: TimeInterval) -> (link: ShareLink, urls: [ShareURLs.Item])? {
        guard let minted = store.mint(window: window?.id, label: window?.portalTitle ?? ShareLinks.pickerLabel, control: control, ttl: ttl) else { return nil }
        Log.info("share link \(minted.link.id) made: \(minted.link.isPicker ? "picker" : "window \(minted.link.window ?? 0)"), \(minted.link.accessLabel), \(ShareLinks.ttlLabel(ttl))", .trust)
        changed()
        return (minted.link, urls(token: minted.token, window: window?.id, wifiOnly: false))
    }

    func urls(token: String, window: UInt32?, wifiOnly: Bool) -> [ShareURLs.Item] {
        ShareURLs.make(token: token, window: window, lan: lanAddress(), tailnet: tailscaleAddress(), port: config.httpPort, wifiOnly: wifiOnly)
    }

    func revoke(_ link: ShareLink) {
        guard let gone = store.revoke(id: link.id) else { return }
        revoked(gone)
        changed()
    }

    func revokeAll() {
        let all = store.links()
        store.revokeAll()
        for l in all { revoked(l) }
        changed()
    }

    nonisolated func revokedFromCLI(_ link: ShareLink) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.revoked(link); self.changed() } }
    }

    nonisolated func changedFromCLI() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.changed() } }
    }

    private func revoked(_ link: ShareLink) {
        gate.linkEnded(now: Date())
        Log.info("share link \(link.id) revoked", .trust)
        for who in host?.guestIdentities ?? [] where GuestIdentity.linkID(who) == link.id { kick(who, why: "(its share link was revoked)") }
    }

    private func sweep() {
        guard let host else { return }
        for who in host.guestIdentities where host.guestLink?(who) == nil { kick(who, why: "(its share link expired)") }
        if linksWindow?.isVisible == true { linksWindow?.reload() }
        Task { await host.updateTrackPermissions() }
    }

    private var kicking: Set<String> = []

    private func kick(_ who: String, why: String) {
        guard !kicking.contains(who) else { return }
        kicking.insert(who)
        closePrompt(who)
        let config = config
        Task {
            await RoomAdmin.remove(who, config: config, why: why)
            self.kicking.remove(who)
        }
    }

    private func ask(_ who: String, _ link: ShareLink) {
        guard prompts[who] == nil else { return }
        guard throttle.mayShowPanel(link: link.id, now: Date()) else {
            Log.info("guest \(who) asks to control; link \(link.id) already has a panel or had one in the last \(Int(AskThrottle.cooldown)) s, so the ask waits in the menu", .trust)
            changed()
            return
        }
        promptLinks[who] = link.id
        let panel = GuestAskPanel(link: link) { [weak self] allow in
            self?.host?.answerAsk(who, allow: allow)
            self?.closePrompt(who)
        }
        prompts[who] = panel
        Power.wakeDisplay()
        panel.center()
        panel.orderFrontRegardless()
        NSSound(named: "Ping")?.play()
        changed()
    }

    func answer(_ who: String, allow: Bool) {
        host?.answerAsk(who, allow: allow)
        closePrompt(who)
    }

    private func closePrompt(_ who: String) {
        prompts.removeValue(forKey: who)?.close()
        if let link = promptLinks.removeValue(forKey: who) { throttle.panelClosed(link: link, now: Date()) }
    }

    func showShareWindow(picker: Bool) {
        let w = shareWindow ?? ShareWindowPanel(guests: self)
        shareWindow = w
        w.present(picker: picker)
    }

    func showLinks() {
        let w = linksWindow ?? SharedLinksWindow(guests: self)
        linksWindow = w
        w.present()
    }
}

@MainActor
final class GuestAskPanel: GuardedPanel {
    private var actions: [ClickAction] = []

    init(link: ShareLink, answer: @escaping (Bool) -> Void) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 380, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        title = "Porthole Host"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        let icon = NSImageView(image: NSImage(systemSymbolName: "hand.raised", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        let head = NSTextField(wrappingLabelWithString: "A guest wants to control \(link.isPicker ? "this Mac's shared windows" : "“\(link.label)”")")
        head.font = .boldSystemFont(ofSize: 13)
        let body = NSTextField(wrappingLabelWithString: "They opened a share link (\(link.id), \(link.accessLabel.lowercased())). Allow lets them type and click in it until they leave. Turn on Allow Remote Control in the menu to answer yes at once.")
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        let deny = ClickAction { answer(false) }
        let allow = ClickAction { answer(true) }
        actions = [deny, allow]
        let no = NSButton(title: "Don't Allow", target: deny, action: #selector(ClickAction.fire))
        no.keyEquivalent = "\u{1b}"
        let yes = NSButton(title: "Allow", target: allow, action: #selector(ClickAction.fire))
        let buttons = NSStackView(views: [NSView(), no, yes])
        let text = NSStackView(views: [head, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        let top = NSStackView(views: [icon, text])
        top.alignment = .top
        top.spacing = 12
        let root = NSStackView(views: [top, buttons])
        root.orientation = .vertical
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        for v in [top, buttons] { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true }
        head.preferredMaxLayoutWidth = 290
        body.preferredMaxLayoutWidth = 290
        contentView = root
    }
}

@MainActor
final class ShareWindowPanel: GuardedPanel {
    private unowned let guests: HostGuests
    private let target = NSPopUpButton(frame: .zero, pullsDown: false)
    private let control = NSButton(checkboxWithTitle: "Guests may type and click", target: nil, action: nil)
    private let expiry = NSPopUpButton(frame: .zero, pullsDown: false)
    private let controlNote = NSTextField(wrappingLabelWithString: "")
    private let result = NSStackView()
    private var windows: [WindowInfo] = []
    private var actions: [ClickAction] = []

    init(guests: HostGuests) {
        self.guests = guests
        super.init(contentRect: CGRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Share a Window"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        target.widthAnchor.constraint(equalToConstant: 330).isActive = true
        for ttl in ShareLinks.ttlChoices { expiry.addItem(withTitle: ShareLinks.ttlLabel(ttl)) }
        expiry.selectItem(at: ShareLinks.ttlChoices.firstIndex(of: ShareLinks.defaultTTL) ?? 0)
        controlNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        controlNote.textColor = .secondaryLabelColor
        controlNote.preferredMaxLayoutWidth = 330
        let make = Form.button("Create Link", self, #selector(create), symbol: "link")
        make.keyEquivalent = "\r"
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = 6
        let grid = Form.grid([
            [Form.label("Share:"), target],
            [Form.label("Guests:"), Form.column([control, controlNote])],
            [Form.label("Link works for:"), expiry],
            [NSView(), make],
        ])
        let intro = Form.note("Anyone with the link can watch in a browser, from this Wi-Fi or your tailnet, without the password. A link never pairs a Mac, never sees the clipboard and shows only what it shares. Revoke it any time in Shared Links….", width: 470)
        let root = NSStackView(views: [intro, grid, result])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        contentView = root
    }

    func present(picker: Bool) {
        title = picker ? "Share the Window Picker" : "Share a Window"
        result.arrangedSubviews.forEach { $0.removeFromSuperview() }
        control.state = .off
        refreshNote()
        target.removeAllItems()
        target.addItem(withTitle: ShareLinks.pickerLabel)
        target.lastItem?.tag = -1
        target.isEnabled = false
        Task {
            windows = (try? await WindowCatalog.list()) ?? []
            target.removeAllItems()
            target.addItem(withTitle: ShareLinks.pickerLabel)
            target.lastItem?.tag = -1
            target.menu?.addItem(.separator())
            for (i, w) in windows.enumerated() {
                target.addItem(withTitle: w.pickerLabel)
                target.lastItem?.tag = i
            }
            if !picker, !windows.isEmpty { target.selectItem(withTag: 0) }
            target.isEnabled = true
        }
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    private func refreshNote() {
        controlNote.stringValue = guests.allowControl
            ? "Allow Remote Control is on: a control link may type and click at once, and a view-only guest who asks is let in at once."
            : "Allow Remote Control is off: every link watches, and a guest who asks to control waits for you to answer here."
    }

    @objc private func create() {
        guard !GuardedPanel.currentEventInjected else { return }
        let tag = target.selectedTag()
        let window = tag >= 0 && tag < windows.count ? windows[tag] : nil
        let ttl = ShareLinks.ttlChoices[safe: expiry.indexOfSelectedItem] ?? ShareLinks.defaultTTL
        result.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = []
        guard let made = guests.mint(window: window, control: control.state == .on, ttl: ttl) else {
            result.addArrangedSubview(Form.status(false, "The link couldn't be saved."))
            return
        }
        if made.urls.isEmpty { result.addArrangedSubview(Form.status(false, "This Mac has no local network or tailnet address.")) }
        for item in made.urls {
            let field = NSTextField(labelWithString: item.url)
            field.isSelectable = true
            field.lineBreakMode = .byTruncatingMiddle
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 330).isActive = true
            let copy = ClickAction { Form.copy(item.url) }
            actions.append(copy)
            let b = NSButton(title: "Copy", target: copy, action: #selector(ClickAction.fire))
            b.controlSize = .small
            b.bezelStyle = .rounded
            let label = Form.label(item.kind == "wifi" ? "This Wi-Fi:" : "Tailnet:")
            label.widthAnchor.constraint(equalToConstant: 76).isActive = true
            result.addArrangedSubview(Form.row([label, field, b]))
        }
        result.addArrangedSubview(Form.note("\(made.link.accessLabel), \(ShareLinks.expiryLabel(made.link, now: Date())). Link ID \(made.link.id).", width: 470))
        if let first = made.urls.first { Form.copy(first.url) }
    }
}

@MainActor
final class SharedLinksWindow: GuardedPanel {
    private unowned let guests: HostGuests
    private let list = NSStackView()
    private let header = NSTextField(wrappingLabelWithString: "")
    private var actions: [ClickAction] = []

    init(guests: HostGuests) {
        self.guests = guests
        super.init(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Shared Links"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 420, height: 200)
        header.textColor = .secondaryLabelColor
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        let root = NSStackView(views: [header, list, NSView()])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for v in root.arrangedSubviews { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true }
        contentView = root
    }

    func present() {
        reload()
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func reload() {
        let links = guests.links
        header.stringValue = "Browser links to this Mac's windows. Revoking one disconnects its guests at once. Allow Remote Control is \(guests.allowControl ? "on" : "off")."
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = []
        for (who, link) in guests.pendingAsks {
            let text = NSTextField(labelWithString: "A guest of \(link.label) asks to control")
            text.font = .systemFont(ofSize: 12, weight: .semibold)
            let no = ClickAction { [weak self] in self?.guests.answer(who, allow: false) }
            let yes = ClickAction { [weak self] in self?.guests.answer(who, allow: true) }
            actions += [no, yes]
            let row = NSStackView(views: [text, NSView(), NSButton(title: "Don't Allow", target: no, action: #selector(ClickAction.fire)),
                                          NSButton(title: "Allow", target: yes, action: #selector(ClickAction.fire))])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        if links.isEmpty {
            let empty = NSTextField(labelWithString: "No share links. Make one with Share Window… or Share Picker… in the menu.")
            empty.textColor = .tertiaryLabelColor
            list.addArrangedSubview(empty)
            return
        }
        for link in links {
            let name = NSTextField(labelWithString: link.label)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            let n = guests.guests(of: link).count
            let info = NSTextField(labelWithString: "\(link.kindLabel) · \(link.accessLabel) · \(ShareLinks.expiryLabel(link, now: Date())) · \(n == 1 ? "1 guest" : "\(n) guests") · \(link.id)")
            info.font = .systemFont(ofSize: 11)
            info.textColor = .secondaryLabelColor
            let text = NSStackView(views: [name, info])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let action = ClickAction { [weak self] in self?.guests.revoke(link) }
            actions.append(action)
            let button = NSButton(title: "Revoke", target: action, action: #selector(ClickAction.fire))
            button.bezelStyle = .rounded
            let row = NSStackView(views: [text, NSView(), button])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let all = ClickAction { [weak self] in self?.guests.revokeAll() }
        actions.append(all)
        list.addArrangedSubview(NSButton(title: "Revoke All", target: all, action: #selector(ClickAction.fire)))
    }
}
