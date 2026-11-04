import AppKit
import PortholeCore

@MainActor
final class ConnectWindow: NSWindow, NSTextFieldDelegate {
    var onSubmit: ((_ address: String, _ name: String?, _ secret: String?) -> Void)?
    var onRequestPairing: ((_ address: String, _ name: String?) -> Void)?
    var onRefresh: (() -> Void)?
    var onCancel: (() -> Void)?

    private let list = NSStackView()
    private let status = NSTextField(labelWithString: "Looking for hosts…")
    private let address = NSTextField()
    private let secretPrompt = NSTextField(wrappingLabelWithString: "")
    private let secret = NSSecureTextField()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Quit", target: nil, action: nil)
    private var chosenName: String?
    private var targets: [ClosureTarget] = []
    private var rows: [(NSButton, String)] = []

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 460, height: 420),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Connect to a Porthole Host"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 380, height: 360)

        let heading = NSTextField(labelWithString: "Hosts on this network and your tailnet")
        heading.font = .boldSystemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let refresh = button("Refresh") { [weak self] in self?.onRefresh?() }
        let top = NSStackView(views: [status, NSView(), refresh])

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        address.placeholderString = "Host name or Tailscale address (100.x.y.z), optionally :port"
        address.delegate = self
        secret.placeholderString = "Pairing code or password"
        secretPrompt.isHidden = true
        secret.isHidden = true
        message.textColor = .systemRed
        message.isHidden = true

        connectButton.keyEquivalent = "\r"
        let connectAction = ClosureTarget { [weak self] in self?.submit() }
        connectButton.target = connectAction; connectButton.action = #selector(ClosureTarget.fire)
        let cancelAction = ClosureTarget { [weak self] in self?.onCancel?() }
        cancelButton.target = cancelAction; cancelButton.action = #selector(ClosureTarget.fire)
        targets += [connectAction, cancelAction]
        let buttons = NSStackView(views: [NSView(), cancelButton, connectButton])

        let root = NSStackView(views: [heading, top, scroll, NSTextField(labelWithString: "Address"), address,
                                       secretPrompt, secret, message, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in root.arrangedSubviews { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        contentView = root
        center()
    }

    var cancelQuits = true {
        didSet { cancelButton.title = cancelQuits ? "Quit" : "Cancel" }
    }

    private func button(_ title: String, _ fn: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        let t = ClosureTarget(fn)
        targets.append(t)
        b.target = t; b.action = #selector(ClosureTarget.fire)
        return b
    }

    func show(_ hosts: [DiscoveredHost], scanning: Bool, preferTailscale: Bool, hasAccess: (DiscoveredHost, String) -> Bool = { _, _ in true }) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeAll { $0.tag >= 0 }
        rows = []
        let online = hosts.filter { $0.status != .notFound }.count
        status.stringValue = scanning ? "Looking for hosts…"
            : online == 0 ? "No hosts found. Type an address below." : "\(online) host\(online == 1 ? "" : "s") found"
        for (i, host) in hosts.enumerated() {
            let addr = host.address(preferTailscale: preferTailscale)
            let b = NSButton(title: "", target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .recessed
            b.alignment = .left
            b.lineBreakMode = .byTruncatingTail
            b.attributedTitle = rowTitle(host, address: addr)
            let trusted = hasAccess(host, addr)
            let symbol = host.status == .notFound ? "desktopcomputer.trianglebadge.exclamationmark" : trusted ? "desktopcomputer" : "lock.fill"
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: trusted ? nil : "Not paired")
            b.imagePosition = .imageLeading
            b.toolTip = trusted ? nil : "Not paired yet. Pick it to ask that Mac to show a pairing code."
            b.state = addr == address.stringValue ? .on : .off
            let t = ClosureTarget { [weak self] in self?.choose(host, address: addr, trusted: trusted) }
            t.tag = i
            targets.append(t)
            b.target = t; b.action = #selector(ClosureTarget.fire)
            list.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -8).isActive = true
            rows.append((b, addr))
        }
    }

    private func rowTitle(_ host: DiscoveredHost, address: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: host.name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        let color: NSColor = host.status == .online ? .secondaryLabelColor : .tertiaryLabelColor
        s.append(NSAttributedString(string: "   \(address)  ·  \(host.label)",
                                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]))
        return s
    }

    private func choose(_ host: DiscoveredHost, address addr: String, trusted: Bool) {
        address.stringValue = addr
        chosenName = host.name
        for (b, a) in rows { b.state = a == addr ? .on : .off }
        resetSecret()
        makeFirstResponder(address)
        if !trusted && host.status == .online { onRequestPairing?(addr, host.name) }
    }

    func fill(_ addr: String) {
        address.stringValue = addr
        chosenName = nil
        resetSecret()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === address else { return }
        chosenName = nil
        for (b, a) in rows { b.state = a == address.stringValue ? .on : .off }
        resetSecret()
    }

    func ask(_ prompt: String) {
        secretPrompt.stringValue = prompt
        secretPrompt.isHidden = false
        secret.isHidden = false
        secret.stringValue = ""
        message.isHidden = true
        makeFirstResponder(secret)
    }

    func showError(_ text: String) {
        message.stringValue = text
        message.isHidden = false
        if !secret.isHidden { secret.stringValue = ""; makeFirstResponder(secret) }
    }

    func setBusy(_ busy: Bool, _ label: String = "Pairing…") {
        connectButton.isEnabled = !busy
        connectButton.title = busy ? label : "Connect"
    }

    private func resetSecret() {
        secretPrompt.isHidden = true
        secret.isHidden = true
        secret.stringValue = ""
        message.isHidden = true
    }

    private func submit() {
        let addr = address.stringValue.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { showError("Pick a host or type its address."); return }
        message.isHidden = true
        onSubmit?(addr, chosenName, secret.isHidden ? nil : secret.stringValue)
    }
}
