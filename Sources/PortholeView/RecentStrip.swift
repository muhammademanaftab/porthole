import AppKit
import PortholeCore

@MainActor
final class RecentStrip: NSStackView {
    private let heading = NSTextField(labelWithString: "Recent")
    private let row = NSStackView()
    private var chips: [RecentChip] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        addArrangedSubview(heading)
        addArrangedSubview(row)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    struct Item {
        var title: String
        var detail: String
        var icon: NSImage
        var tooltip: String
        var action: () -> Void
    }

    func show(_ items: [Item]) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips = items.map { RecentChip($0) }
        for c in chips { row.addArrangedSubview(c) }
        isHidden = items.isEmpty
    }

    static func icon(bundle: String?) -> NSImage {
        let image = bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 24, height: 24)
        return copy
    }
}

@MainActor
final class RecentChip: NSView {
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ item: RecentStrip.Item) {
        action = item.action
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: item.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [icon, text])
        stack.spacing = 7
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(lessThanOrEqualToConstant: 210),
        ])
        for v in [title, detail] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        toolTip = item.tooltip
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reopen \(item.title)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.quaternaryLabelColor.withAlphaComponent(0.08)).cgColor
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
