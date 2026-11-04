import AppKit
import PortholeCore

@MainActor
final class PickerWindow: NSWindow, NSToolbarDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let onPick: (WindowInfo) -> Void
    private let onRefresh: () -> Void
    private let hostName: String
    private let grid = PickerGridView()
    private let scroll = NSScrollView()
    private let notice = NoticeView()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Double-click or press Return to open")
    private var query = ""
    private var all: [WindowInfo] = []
    private var shown: [WindowInfo] = []
    private var loaded = false
    private var error: String?
    private var icons: [UInt32: NSImage] = [:]
    private var thumbs: [UInt32: NSImage] = [:]
    private var refreshTimer: Timer?
    private let recentStrip = RecentStrip()
    private var scrollTopPlain: NSLayoutConstraint?
    private var scrollTopBelowRecent: NSLayoutConstraint?
    var recents: () -> [RecentPortal] = { [] }
    var hostAddress = ""
    var route: String? { didSet { if route != oldValue { render() } } }
    var onThumbsWanted: (() -> Void)?
    var onIconWanted: ((UInt32) -> Void)?

    init(hostName: String, onPick: @escaping (WindowInfo) -> Void, refresh: @escaping () -> Void) {
        self.onPick = onPick
        self.onRefresh = refresh
        self.hostName = hostName
        super.init(contentRect: CGRect(x: 0, y: 0, width: 760, height: 540),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = hostName
        subtitle = "Connecting…"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 320)
        setFrameAutosaveName("PortholePicker")

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = PickerCard.size
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = false
        grid.backgroundColors = [.clear]
        grid.dataSource = self
        grid.delegate = self
        grid.register(PickerCard.self, forItemWithIdentifier: PickerCard.id)
        grid.onOpen = { [weak self] in self?.openSelection() }

        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true

        let background = NSVisualEffectView()
        background.material = .contentBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        notice.onAction = { [weak self] in self?.refresh() }

        statusIcon.imageScaling = .scaleProportionallyDown
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        let bar = NSStackView(views: [statusIcon, statusLabel, NSView(), hint])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        let line = NSBox()
        line.boxType = .separator

        for v in [scroll, notice, line, bar, recentStrip] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(v)
        }
        let plain = scroll.topAnchor.constraint(equalTo: background.topAnchor)
        let below = scroll.topAnchor.constraint(equalTo: recentStrip.bottomAnchor, constant: 2)
        scrollTopPlain = plain
        scrollTopBelowRecent = below
        contentView = background
        NSLayoutConstraint.activate([
            recentStrip.topAnchor.constraint(equalTo: (contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? background.topAnchor, constant: 12),
            recentStrip.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            recentStrip.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            plain,
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            notice.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: 10),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 24),
            line.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
        ])

        let toolbar = NSToolbar(identifier: "PortholePickerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        toolbarStyle = .unified

        render()
        center()
        initialFirstResponder = grid
    }

    private static let refreshItem = NSToolbarItem.Identifier("refresh")
    private static let searchItem = NSToolbarItem.Identifier("search")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.refreshItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.refreshItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.label = "Refresh"
            item.toolTip = "Ask the host for its windows again (⌘R)"
            item.isBordered = true
            item.target = self
            item.action = #selector(refreshClicked)
            return item
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search windows"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            item.preferredWidthForSearchField = 220
            return item
        default:
            return nil
        }
    }

    @objc private func refreshClicked() { refresh() }

    func refresh() {
        loaded = false
        error = nil
        render()
        onRefresh()
    }

    @objc private func searchChanged(_ field: NSSearchField) {
        query = field.stringValue
        apply()
        showRecents()
    }

    private func showRecents() {
        let picks = query.isEmpty && loaded ? RecentPortals.forPicker(recents(), host: hostAddress, windows: all) : []
        recentStrip.show(picks.map { w in
            RecentStrip.Item(title: w.displayTitle, detail: w.title.isEmpty ? "Recently open" : w.app, icon: icons[w.id] ?? RecentStrip.icon(bundle: w.bundle),
                             tooltip: "Reopen \(w.pickerLabel)") { [weak self] in self?.onPick(w) }
        })
        let visible = !picks.isEmpty
        scrollTopPlain?.isActive = !visible
        scrollTopBelowRecent?.isActive = visible
        scroll.automaticallyAdjustsContentInsets = !visible
        if visible { scroll.contentInsets = NSEdgeInsetsZero }
    }

    func search(for text: String) {
        (toolbar?.items.first(where: { $0.itemIdentifier == Self.searchItem }) as? NSSearchToolbarItem)?.searchField.stringValue = text
        query = text
        apply()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let item = toolbar?.items.first(where: { $0.itemIdentifier == Self.searchItem }) as? NSSearchToolbarItem else { return }
        item.beginSearchInteraction()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "r" { refresh(); return true }
        if flags == .command, event.charactersIgnoringModifiers == "f" { performFindPanelAction(nil); return true }
        if event.keyCode == 36 || event.keyCode == 76, firstResponder is NSText, !shown.isEmpty {
            if grid.selectionIndexPaths.isEmpty { grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)] }
            openSelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func show(_ list: [WindowInfo]) {
        let selected = grid.selectionIndexPaths.first.map { shown[$0.item].id }
        all = list
        loaded = true
        if !list.isEmpty { error = nil }
        let live = Set(list.map(\.id))
        thumbs = thumbs.filter { live.contains($0.key) }
        for info in list where icons[info.id] == nil {
            if let icon = localIcon(info) { icons[info.id] = icon } else { onIconWanted?(info.id) }
        }
        apply(keeping: selected)
        showRecents()
        if !list.isEmpty { onThumbsWanted?() }
        startThumbTimer()
    }

    func showError(_ msg: String) {
        error = msg
        render()
    }

    func setIcon(_ id: UInt32, png: Data) {
        guard let image = NSImage(data: png) else { return }
        icons[id] = image
        reload(id)
    }

    func setThumb(_ id: UInt32, jpeg: Data) {
        guard let image = NSImage(data: jpeg) else { return }
        thumbs[id] = image
        reload(id)
    }

    private func reload(_ id: UInt32) {
        guard let i = shown.firstIndex(where: { $0.id == id }),
              let card = grid.item(at: IndexPath(item: i, section: 0)) as? PickerCard else { return }
        card.configure(shown[i], icon: icons[id], thumb: thumbs[id])
    }

    private func apply(keeping selected: UInt32? = nil) {
        let keep = selected ?? grid.selectionIndexPaths.first.flatMap { $0.item < shown.count ? shown[$0.item].id : nil }
        shown = filterWindows(all, query: query)
        grid.reloadData()
        if let keep, let i = shown.firstIndex(where: { $0.id == keep }) {
            grid.selectionIndexPaths = [IndexPath(item: i, section: 0)]
        } else if !shown.isEmpty {
            grid.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        }
        render()
    }

    private func render() {
        let n = pickerNotice(loaded: loaded, total: all.count, shown: shown.count, query: query, error: error)
        notice.isHidden = n == nil
        scroll.isHidden = n != nil
        hint.isHidden = n != nil
        if let n { notice.show(n) }
        subtitle = loaded ? pickerCountLabel(total: all.count, shown: shown.count) : "Connecting…"
        if let error, !all.isEmpty {
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            statusIcon.contentTintColor = .systemOrange
            statusLabel.stringValue = error
            statusLabel.toolTip = error
        } else {
            statusIcon.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular))
            statusIcon.contentTintColor = loaded ? .systemGreen : .tertiaryLabelColor
            statusLabel.stringValue = loaded ? "Connected to \(hostName)\(route.map { " · \($0)" } ?? "")" : "Connecting to \(hostName)…"
            statusLabel.toolTip = nil
        }
    }

    private func startThumbTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.isKeyWindow, !self.all.isEmpty else { return }
                self.onThumbsWanted?()
            }
        }
    }

    override func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        super.close()
    }

    private func localIcon(_ info: WindowInfo) -> NSImage? {
        if info.screen == true { return NSImage(systemSymbolName: "display", accessibilityDescription: WholeMac.appName) }
        guard let bundle = info.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func openSelection() {
        guard let i = grid.selectionIndexPaths.first?.item, i < shown.count else { return }
        onPick(shown[i])
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let card = collectionView.makeItem(withIdentifier: PickerCard.id, for: indexPath) as! PickerCard
        let info = shown[indexPath.item]
        card.configure(info, icon: icons[info.id], thumb: thumbs[info.id])
        return card
    }
}

final class PickerGridView: NSCollectionView {
    var onOpen: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onOpen?(); return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: p) != nil { onOpen?() }
    }
}

final class PickerCard: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("PickerCard")
    static let size = NSSize(width: 216, height: 186)

    private let frameView = CardBackground()
    private let preview = NSImageView()
    private let placeholder = NSImageView()
    private let badge = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        frameView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(frameView)

        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 8
        well.layer?.masksToBounds = true
        well.layer?.borderWidth = 1
        well.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(well)
        frameView.well = well

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        for v in [placeholder, preview] {
            v.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(v)
        }

        badge.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 12.5, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for v in [badge, name, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            frameView.addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            frameView.topAnchor.constraint(equalTo: root.topAnchor),
            frameView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            well.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 8),
            well.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -8),
            well.topAnchor.constraint(equalTo: frameView.topAnchor, constant: 8),
            well.heightAnchor.constraint(equalToConstant: 125),
            preview.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 6),
            preview.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -6),
            preview.topAnchor.constraint(equalTo: well.topAnchor, constant: 6),
            preview.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -6),
            placeholder.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 64),
            placeholder.heightAnchor.constraint(equalToConstant: 64),
            badge.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 9),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 7),
            name.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 9),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
        view = root
    }

    func configure(_ info: WindowInfo, icon: NSImage?, thumb: NSImage?) {
        let appIcon = icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
        preview.image = thumb
        preview.isHidden = thumb == nil
        placeholder.image = appIcon
        placeholder.isHidden = thumb != nil
        badge.image = appIcon
        name.stringValue = info.displayTitle
        detail.stringValue = info.displaySubtitle
        view.toolTip = info.pickerLabel
        view.setAccessibilityLabel(info.pickerLabel)
    }

    override var isSelected: Bool {
        didSet { frameView.selected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { frameView.hovered = highlightState == .forSelection }
    }
}

final class CardBackground: NSView {
    weak var well: NSView?
    var selected = false { didSet { needsDisplay = true } }
    var hovered = false { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = selected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        let fill: NSColor = selected ? .controlAccentColor.withAlphaComponent(0.14) : hovered ? .quaternaryLabelColor : .clear
        layer?.backgroundColor = fill.cgColor
        well?.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
        well?.layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

final class NoticeView: NSStackView {
    private let icon = NSImageView()
    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let action = NSButton(title: "Refresh", target: nil, action: nil)
    var onAction: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .regular
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.alignment = .center
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 360
        action.bezelStyle = .rounded
        action.target = self
        action.action = #selector(fire)
        for v in [spinner, icon, heading, body, action] { addArrangedSubview(v) }
        setCustomSpacing(14, after: icon)
        setCustomSpacing(14, after: spinner)
        setCustomSpacing(16, after: body)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onAction?() }

    func show(_ n: PickerNotice) {
        let loading = n == .loading
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        icon.isHidden = loading
        icon.image = NSImage(systemSymbolName: n.symbol, accessibilityDescription: nil)
        icon.contentTintColor = n == .locked ? .systemOrange : { if case .error = n { return .systemRed } else { return .tertiaryLabelColor } }()
        heading.stringValue = n.title
        body.stringValue = n.message
        switch n {
        case .loading, .noMatches: action.isHidden = true
        default: action.isHidden = false
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ClosureTarget: NSObject {
    let fn: () -> Void
    var tag = -1
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn() }
}
