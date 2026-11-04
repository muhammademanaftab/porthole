import AppKit
import PortholeCore

@MainActor
final class ConnectWindow: NSWindow, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onSubmit: ((_ address: String, _ name: String?, _ secret: String?) -> Void)?
    var onRequestPairing: ((_ address: String, _ name: String?) -> Void)?
    var onRefresh: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRecent: ((RecentPortal) -> Void)?
    private let recentStrip = RecentStrip()

    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let address = NSTextField()
    private let addressRow = NSStackView()
    private let disclosure = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Quit", target: nil, action: nil)
    private var chosenName: String?
    private var rows: [(host: DiscoveredHost, address: String, trusted: Bool)] = []
    private var codeSheet: CodeSheet?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 520, height: 500),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Connect"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 440, height: 420)

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let heading = NSTextField(labelWithString: "Choose a Mac")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: "Macs running Porthole Host on this network and your tailnet. A padlock means this Mac hasn't paired with it yet.")
        sub.textColor = .secondaryLabelColor
        sub.font = .systemFont(ofSize: 12)
        let headText = NSStackView(views: [heading, sub])
        headText.orientation = .vertical
        headText.alignment = .leading
        headText.spacing = 3
        let head = NSStackView(views: [icon, headText])
        head.alignment = .centerY
        head.spacing = 12
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56)])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 50
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let well = NSBox()
        well.boxType = .custom
        well.cornerRadius = 10
        well.borderColor = .separatorColor
        well.borderWidth = 1
        well.fillColor = .controlBackgroundColor
        well.contentViewMargins = .zero
        well.contentView = scroll
        well.setContentHuggingPriority(.defaultLow, for: .vertical)
        well.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
                               target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .accessoryBarAction
        refresh.isBordered = false
        refresh.toolTip = "Look for Macs again"
        let statusRow = NSStackView(views: [spinner, status, NSView(), refresh])
        statusRow.spacing = 6

        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggleAddress)
        let disclosureLabel = NSButton(title: "Connect by address", target: self, action: #selector(toggleAddressFromLabel))
        disclosureLabel.isBordered = false
        disclosureLabel.contentTintColor = .secondaryLabelColor
        disclosureLabel.font = .systemFont(ofSize: 12)
        let disclosureRow = NSStackView(views: [disclosure, disclosureLabel])
        disclosureRow.spacing = 2

        address.placeholderString = "Host name or Tailscale address (100.x.y.z), optionally :port"
        address.delegate = self
        address.bezelStyle = .roundedBezel
        address.controlSize = .large
        addressRow.addArrangedSubview(address)
        addressRow.isHidden = true

        message.textColor = .systemRed
        message.font = .systemFont(ofSize: 12)
        message.isHidden = true

        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.target = self
        connectButton.action = #selector(connectClicked)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        let buttons = NSStackView(views: [NSView(), cancelButton, connectButton])

        let root = NSStackView(views: [head, recentStrip, well, statusRow, disclosureRow, addressRow, message, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 34, left: 22, bottom: 20, right: 22)
        root.setCustomSpacing(16, after: head)
        root.setCustomSpacing(14, after: recentStrip)
        root.setCustomSpacing(6, after: well)
        root.setCustomSpacing(4, after: disclosureRow)
        root.setCustomSpacing(16, after: message)
        for v in root.arrangedSubviews { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true }
        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        setStatus(found: 0, scanning: true)
        center()
    }

    func showRecents(_ list: [RecentPortal]) {
        let now = Date()
        recentStrip.show(list.map { p in
            RecentStrip.Item(title: RecentPortals.chipTitle(p), detail: RecentPortals.chipDetail(p, now: now), icon: RecentStrip.icon(bundle: p.bundle),
                             tooltip: "Reopen \(p.title.isEmpty ? p.app : "\(p.app) — \(p.title)") on \(p.hostName)") { [weak self] in self?.onRecent?(p) }
        })
    }

    var cancelQuits = true {
        didSet { cancelButton.title = cancelQuits ? "Quit" : "Cancel" }
    }

    private func setStatus(found: Int, scanning: Bool) {
        status.stringValue = connectStatus(found: found, scanning: scanning)
        spinner.isHidden = !scanning
        if scanning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func show(_ hosts: [DiscoveredHost], scanning: Bool, preferTailscale: Bool, hasAccess: (DiscoveredHost, String) -> Bool = { _, _ in true }) {
        let current = address.stringValue
        rows = hosts.map { h in
            let addr = h.address(preferTailscale: preferTailscale)
            return (h, addr, hasAccess(h, addr))
        }
        setStatus(found: hosts.filter { $0.status != .notFound }.count, scanning: scanning)
        table.reloadData()
        if let i = rows.firstIndex(where: { $0.address == current }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else if !current.isEmpty, !addressRow.isHidden {
            table.deselectAll(nil)
        } else if current.isEmpty, let i = rows.firstIndex(where: { $0.host.status != .notFound }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: HostCell.id, owner: nil) as? HostCell ?? HostCell()
        let r = rows[row]
        cell.configure(r.host, address: r.address, badge: r.host.badge(trusted: r.trusted))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let i = table.selectedRow
        guard rows.indices.contains(i) else { return }
        address.stringValue = rows[i].address
        chosenName = rows[i].host.name
        message.isHidden = true
    }

    @objc private func doubleClicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        submit()
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func connectClicked() { submit() }
    @objc private func cancelClicked() { onCancel?() }

    @objc private func toggleAddressFromLabel() {
        disclosure.state = disclosure.state == .on ? .off : .on
        toggleAddress()
    }

    @objc private func toggleAddress() {
        addressRow.isHidden = disclosure.state != .on
        if !addressRow.isHidden { makeFirstResponder(address) }
    }

    func fill(_ addr: String) {
        address.stringValue = addr
        chosenName = nil
        if let i = rows.firstIndex(where: { $0.address == addr }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            disclosure.state = .on
            addressRow.isHidden = false
        }
        message.isHidden = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === address else { return }
        chosenName = nil
        if let i = rows.firstIndex(where: { $0.address == address.stringValue }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        message.isHidden = true
    }

    func ask(_ prompt: String) {
        let name = chosenName ?? address.stringValue
        if let codeSheet {
            codeSheet.update(prompt: prompt)
            return
        }
        let s = CodeSheet(hostName: name, prompt: prompt)
        s.onSubmit = { [weak self] secret in
            guard let self else { return }
            self.onSubmit?(self.address.stringValue.trimmingCharacters(in: .whitespaces), self.chosenName, secret)
        }
        s.onCancel = { [weak self] in self?.endSheetIfAny() }
        codeSheet = s
        beginSheet(s) { [weak self] _ in self?.codeSheet = nil }
    }

    private func endSheetIfAny() {
        guard let codeSheet else { return }
        endSheet(codeSheet)
        self.codeSheet = nil
    }

    override func close() {
        endSheetIfAny()
        super.close()
    }

    func showError(_ text: String) {
        if let codeSheet {
            codeSheet.showError(text)
            return
        }
        message.stringValue = text
        message.isHidden = false
    }

    func setBusy(_ busy: Bool, _ label: String = "Pairing…") {
        connectButton.isEnabled = !busy
        connectButton.title = busy ? label : "Connect"
        codeSheet?.setBusy(busy)
    }

    private func submit() {
        let addr = address.stringValue.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { showError("Pick a Mac or type its address."); return }
        message.isHidden = true
        onSubmit?(addr, chosenName, nil)
    }
}

final class HostCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("HostCell")
    private let symbol = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let dot = NSImageView()
    private let state = NSTextField(labelWithString: "")
    private let lock = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        symbol.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor
        lock.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Not paired")
        lock.contentTintColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [symbol, text, NSView(), lock, dot, state])
        row.spacing = 8
        row.setCustomSpacing(12, after: symbol)
        row.setCustomSpacing(12, after: lock)
        row.setCustomSpacing(4, after: dot)
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ host: DiscoveredHost, address: String, badge: HostBadge) {
        name.stringValue = host.name
        detail.stringValue = host.detail(address: address)
        state.stringValue = host.statusText
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular))
        switch badge {
        case .ready, .needsPairing: dot.contentTintColor = .systemGreen
        case .older: dot.contentTintColor = .systemOrange
        case .offline: dot.contentTintColor = .tertiaryLabelColor
        }
        lock.isHidden = badge != .needsPairing
        symbol.contentTintColor = badge == .offline ? .tertiaryLabelColor : .labelColor
        name.textColor = badge == .offline ? .secondaryLabelColor : .labelColor
        toolTip = badge.help
        setAccessibilityLabel("\(host.name), \(host.statusText)\(badge == .needsPairing ? ", not paired" : "")")
    }
}

@MainActor
final class CodeSheet: NSWindow, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var entry = CodeEntry()
    private var boxes: [NSTextField] = []
    private let prompt = NSTextField(wrappingLabelWithString: "")
    private let error = NSTextField(wrappingLabelWithString: "")
    private let password = NSSecureTextField()
    private let modeButton = NSButton(title: "Use Password Instead", target: nil, action: nil)
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)
    private let digitsRow = NSStackView()
    private var usingPassword = false
    private var busy = false
    private let digitEditor = DigitFieldEditor()

    init(hostName: String, prompt text: String) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)!)
        lock.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        lock.contentTintColor = .controlAccentColor
        let heading = NSTextField(labelWithString: "Pair with \(hostName)")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.alignment = .center
        heading.lineBreakMode = .byTruncatingMiddle
        prompt.stringValue = text
        prompt.alignment = .center
        prompt.textColor = .secondaryLabelColor
        prompt.font = .systemFont(ofSize: 12)

        digitsRow.spacing = 8
        for i in 0..<CodeEntry.length {
            let box = DigitBox()
            box.delegate = self
            box.tag = i
            boxes.append(box)
            digitsRow.addArrangedSubview(box)
            if i == 2 {
                let dash = NSTextField(labelWithString: "–")
                dash.font = .systemFont(ofSize: 22, weight: .light)
                dash.textColor = .tertiaryLabelColor
                digitsRow.addArrangedSubview(dash)
            }
        }
        password.placeholderString = "Host password"
        password.bezelStyle = .roundedBezel
        password.controlSize = .large
        password.isHidden = true
        password.widthAnchor.constraint(equalToConstant: 300).isActive = true

        error.textColor = .systemRed
        error.alignment = .center
        error.font = .systemFont(ofSize: 12)
        error.isHidden = true

        modeButton.isBordered = false
        modeButton.contentTintColor = .linkColor
        modeButton.font = .systemFont(ofSize: 12)
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        pairButton.keyEquivalent = "\r"
        pairButton.controlSize = .large
        pairButton.target = self
        pairButton.action = #selector(pair)
        let buttons = NSStackView(views: [modeButton, NSView(), cancel, pairButton])

        let root = NSStackView(views: [lock, heading, prompt, digitsRow, password, error, buttons])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        root.setCustomSpacing(18, after: prompt)
        root.setCustomSpacing(18, after: error)
        for v in [heading, prompt, error, buttons] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        }
        contentView = root
        setContentSize(NSSize(width: 440, height: root.fittingSize.height))
        initialFirstResponder = boxes.first
        refreshPairButton()
    }

    func update(prompt text: String) {
        prompt.stringValue = text
        error.isHidden = true
    }

    func showError(_ text: String) {
        error.stringValue = text
        error.isHidden = false
        entry.clear()
        syncBoxes()
        password.stringValue = ""
        makeFirstResponder(usingPassword ? password : boxes.first)
        refreshPairButton()
        shake()
    }

    func setBusy(_ busy: Bool) {
        self.busy = busy
        for b in boxes { b.isEnabled = !busy }
        password.isEnabled = !busy
        pairButton.title = busy ? "Pairing…" : "Pair"
        refreshPairButton()
    }

    private var ready: Bool { usingPassword ? !password.stringValue.isEmpty : entry.isComplete }

    private func refreshPairButton() { pairButton.isEnabled = ready && !busy }

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        guard object is DigitBox else { return super.fieldEditor(createFlag, for: object) }
        digitEditor.isFieldEditor = true
        return digitEditor
    }

    private func syncBoxes() {
        for (i, b) in boxes.enumerated() where b.stringValue != entry.digits[i] { b.stringValue = entry.digits[i] }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === password { refreshPairButton(); return }
        guard let box = obj.object as? DigitBox else { return }
        let next = entry.type(box.stringValue, at: box.tag, replacing: digitEditor.replacedAll)
        digitEditor.replacedAll = false
        syncBoxes()
        error.isHidden = true
        refreshPairButton()
        if entry.isComplete && box.tag == CodeEntry.length - 1 || entry.isComplete && next == CodeEntry.length - 1 && !entry.digits[box.tag].isEmpty && box.stringValue.count > 1 {
            pair()
            return
        }
        if next != box.tag { makeFirstResponder(boxes[next]) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let box = control as? DigitBox else { return false }
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            let to = entry.backspace(at: box.tag)
            syncBoxes()
            refreshPairButton()
            makeFirstResponder(boxes[to])
            return true
        case #selector(NSResponder.moveLeft(_:)):
            makeFirstResponder(boxes[max(0, box.tag - 1)])
            return true
        case #selector(NSResponder.moveRight(_:)):
            makeFirstResponder(boxes[min(CodeEntry.length - 1, box.tag + 1)])
            return true
        default:
            return false
        }
    }

    @objc private func toggleMode() {
        usingPassword.toggle()
        digitsRow.isHidden = usingPassword
        password.isHidden = !usingPassword
        modeButton.title = usingPassword ? "Use Pairing Code Instead" : "Use Password Instead"
        error.isHidden = true
        makeFirstResponder(usingPassword ? password : boxes[0])
        refreshPairButton()
    }

    @objc private func pair() {
        guard ready, !busy else { return }
        onSubmit?(usingPassword ? password.stringValue : entry.code)
    }

    @objc private func cancel() { onCancel?() }

    private func shake() {
        let f = frame
        let anim = CAKeyframeAnimation()
        let path = CGMutablePath()
        path.move(to: f.origin)
        for i in 0..<6 { path.addLine(to: CGPoint(x: f.minX + (i.isMultiple(of: 2) ? -6 : 6), y: f.minY)) }
        path.addLine(to: f.origin)
        anim.path = path
        anim.duration = 0.3
        animations = ["frameOrigin": anim]
        animator().setFrameOrigin(f.origin)
    }
}

final class DigitFieldEditor: NSTextView {
    var replacedAll = false

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let length = (string as NSString).length
        replacedAll = length > 0 && affectedCharRange.location == 0 && affectedCharRange.length == length
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }
}

final class DigitBox: NSTextField {
    init() {
        super.init(frame: .zero)
        font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        alignment = .center
        bezelStyle = .roundedBezel
        focusRingType = .exterior
        usesSingleLineMode = true
        cell?.isScrollable = false
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 44), heightAnchor.constraint(equalToConstant: 52)])
        setAccessibilityLabel("Pairing code digit")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { currentEditor()?.selectAll(nil) }
        return ok
    }
}
