import AppKit
import PortholeCore

@MainActor
final class PairedMacsWindow: NSPanel {
    private unowned let trust: HostTrust
    private let list = NSStackView()
    private let header = NSTextField(wrappingLabelWithString: "")
    private var actions: [ClickAction] = []
    private let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(trust: HostTrust) {
        self.trust = trust
        super.init(contentRect: CGRect(x: 0, y: 0, width: 440, height: 300),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Paired Macs"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 360, height: 200)

        header.textColor = .secondaryLabelColor
        header.isSelectable = true
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
        header.stringValue = "These Macs may view this one without a password. Unpairing one disconnects it at once.\nThis Mac's device ID: \(trust.identity.id)"
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = []
        let devices = trust.store.devices()
        if devices.isEmpty {
            let empty = NSTextField(labelWithString: "No Macs are paired with this one yet.")
            empty.textColor = .tertiaryLabelColor
            list.addArrangedSubview(empty)
            return
        }
        for device in devices.sorted(by: { normalizedHostName($0.name) < normalizedHostName($1.name) }) {
            let name = NSTextField(labelWithString: device.name)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            let info = NSTextField(labelWithString: "\(device.id)  ·  paired \(dates.string(from: device.pairedAt))")
            info.font = .systemFont(ofSize: 11)
            info.textColor = .secondaryLabelColor
            info.isSelectable = true
            let text = NSStackView(views: [name, info])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let action = ClickAction { [weak self] in self?.trust.unpair(device) }
            actions.append(action)
            let button = NSButton(title: "Unpair", target: action, action: #selector(ClickAction.fire))
            button.bezelStyle = .rounded
            let row = NSStackView(views: [text, NSView(), button])
            row.orientation = .horizontal
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}

final class ClickAction: NSObject {
    private let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn() }
}
