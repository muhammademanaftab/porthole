import AppKit
import PortholeCore

@MainActor
final class PickerWindow: NSWindow {
    private let stack = NSStackView()
    private let status = NSTextField(labelWithString: "Connecting…")
    private let onPick: (WindowInfo) -> Void
    private var items: [WindowInfo] = []

    init(hostName: String, onPick: @escaping (WindowInfo) -> Void, refresh: @escaping () -> Void) {
        self.onPick = onPick
        super.init(contentRect: CGRect(x: 0, y: 0, width: 420, height: 480),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        title = "Windows on \(hostName)"
        isReleasedWhenClosed = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let doc = FlippedView()
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
        refreshButton.bezelStyle = .rounded
        let action = ClosureTarget(refresh)
        refreshButton.target = action; refreshButton.action = #selector(ClosureTarget.fire)
        targets.append(action)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let bar = NSStackView(views: [status, NSView(), refreshButton])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let root = NSStackView(views: [scroll, bar])
        root.orientation = .vertical
        root.spacing = 0
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentView = root
        center()
    }

    private var targets: [ClosureTarget] = []

    func show(_ list: [WindowInfo]) {
        items = list
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        targets.removeAll { $0.tag >= 0 }
        status.stringValue = list.isEmpty ? "No windows to share on the host." : "\(list.count) windows. Click one to open it."
        for (i, info) in list.enumerated() {
            let b = NSButton(title: info.pickerLabel, target: nil, action: nil)
            b.bezelStyle = .recessed
            b.isBordered = false
            b.alignment = .left
            b.lineBreakMode = .byTruncatingTail
            b.font = .systemFont(ofSize: 13)
            if let bundle = info.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 18, height: 18)
                b.image = icon
                b.imagePosition = .imageLeading
            }
            let t = ClosureTarget { [weak self] in self?.onPick(info) }
            t.tag = i
            targets.append(t)
            b.target = t; b.action = #selector(ClosureTarget.fire)
            stack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
    }

    func showError(_ msg: String) { status.stringValue = msg }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ClosureTarget: NSObject {
    let fn: () -> Void
    var tag = -1
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn() }
}
