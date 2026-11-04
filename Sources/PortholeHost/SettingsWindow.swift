import AppKit
import CoreGraphics
import PortholeCore

@MainActor
final class SettingsWindow: NSWindow, NSWindowDelegate {
    private let tabs = SettingsTabs()
    private let general: GeneralPane
    private let sharing: SharingPane
    private let help = HelpPane()

    init(link: @escaping () -> String, password: @escaping () -> String, trust: HostTrust) {
        general = GeneralPane(deviceID: trust.identity.id)
        sharing = SharingPane(link: link, password: password, trust: trust)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        delegate = self
        tabs.tabStyle = .toolbar
        for (pane, label, symbol) in [(general as NSViewController, "General", "gearshape"),
                                      (sharing, "Sharing This Mac", "macwindow.on.rectangle"),
                                      (help, "Help", "questionmark.circle")] {
            let item = NSTabViewItem(viewController: pane)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        contentViewController = tabs
        toolbarStyle = .preference
        title = "General"
    }

    func present(tab: Int? = nil) {
        refresh()
        if let tab { tabs.selectedTabViewItemIndex = tab }
        title = tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.label ?? title
        tabs.fitWindow(animate: false)
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func refresh() {
        general.refresh()
        sharing.refresh()
        help.refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}

final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let label = item?.label { view.window?.title = label }
        fitWindow(animate: view.window?.isVisible == true)
    }

    func fitWindow(animate: Bool) {
        guard let pane = tabViewItems[safe: selectedTabViewItemIndex]?.viewController?.view, let w = view.window else { return }
        pane.layoutSubtreeIfNeeded()
        let size = NSSize(width: 560, height: pane.fittingSize.height)
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
        w.setFrame(frame, display: true, animate: animate)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

@MainActor
enum Form {
    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.rowAlignment = .firstBaseline
        for (i, row) in rows.enumerated() where row.count == 1 {
            grid.row(at: i).mergeCells(in: NSRange(location: 0, length: 2))
        }
        return grid
    }

    static func label(_ s: String) -> NSTextField {
        NSTextField(labelWithString: s)
    }

    static func note(_ s: String, width: CGFloat = 340) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.textColor = .secondaryLabelColor
        t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        t.preferredMaxLayoutWidth = width
        t.widthAnchor.constraint(equalToConstant: width).isActive = true
        return t
    }

    static func column(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector, symbol: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        if let symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
        }
        return b
    }

    static func pane(_ content: NSView) -> NSView {
        let v = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
            v.widthAnchor.constraint(equalToConstant: 560),
        ])
        return v
    }

    static func status(_ ok: Bool, _ text: String) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                              accessibilityDescription: nil)!)
        icon.contentTintColor = ok ? .systemGreen : .systemOrange
        return row([icon, label(text)], spacing: 5)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

@MainActor
final class GeneralPane: NSViewController {
    private let keepRunning = NSButton(checkboxWithTitle: "Keep Porthole Host running on this Mac", target: nil, action: nil)
    private let keepStatus = NSTextField(wrappingLabelWithString: "")
    private let approve = NSButton(title: "Open Login Items…", target: nil, action: nil)
    private let deviceID: String
    private var lastError: String?

    init(deviceID: String) {
        self.deviceID = deviceID
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        keepRunning.target = self
        keepRunning.action = #selector(toggleKeepRunning)
        keepStatus.textColor = .systemOrange
        keepStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keepStatus.preferredMaxLayoutWidth = 340
        approve.target = self
        approve.action = #selector(openLoginItems)
        approve.bezelStyle = .rounded
        approve.controlSize = .small
        let keep = Form.column([
            keepRunning,
            Form.note("Starts it at login, relaunches it after a crash or a hang, and lets a Mac viewing one of its windows restart it. Quit from the menu keeps it stopped until you open it again or restart this Mac."),
            keepStatus, approve,
        ])
        keep.setCustomSpacing(8, after: keepStatus)

        let name = Form.label(HTTPServer.computerName)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let id = Form.label(deviceID)
        id.isSelectable = true
        id.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        id.textColor = .secondaryLabelColor
        let grid = Form.grid([
            [Form.label("This Mac:"), name],
            [Form.label("Device ID:"), id],
            [Form.label("Startup:"), keep],
        ])
        grid.row(at: 2).topPadding = 8
        view = Form.pane(grid)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let on = HostSettings(lookup: { UserDefaults.standard.object(forKey: $0) }).keepRunning
        keepRunning.state = on ? .on : .off
        let status = KeepRunning.status
        approve.isHidden = !(on && status == .requiresApproval)
        if let lastError {
            keepStatus.stringValue = "Couldn't change it: \(lastError)"
        } else if on && status == .requiresApproval {
            keepStatus.stringValue = "macOS needs your approval: turn Porthole Host on in Login Items."
        } else if on && status != .enabled {
            keepStatus.stringValue = "The watchdog isn't registered (\(KeepRunning.describe(status)))."
        } else {
            keepStatus.stringValue = ""
        }
        keepStatus.isHidden = keepStatus.stringValue.isEmpty
    }

    @objc private func toggleKeepRunning() {
        let on = keepRunning.state == .on
        UserDefaults.standard.set(on, forKey: HostSettings.keepRunningKey)
        Log.info("settings: keep running \(on ? "on" : "off")", .ui)
        lastError = KeepRunning.apply(on)
        refresh()
    }

    @objc private func openLoginItems() { KeepRunning.openLoginItems() }
}

@MainActor
final class SharingPane: NSViewController {
    private let link: () -> String
    private let password: () -> String
    private unowned let trust: HostTrust
    private let linkLabel = NSTextField(labelWithString: "")
    private let passwordLabel = NSTextField(labelWithString: "")
    private let reveal = NSButton()
    private let screenRow = NSStackView()
    private let accessRow = NSStackView()
    private let pairedLabel = NSTextField(labelWithString: "")
    private let dialogs = NSButton(checkboxWithTitle: "Show Dialogs as Their Own Windows", target: nil, action: nil)
    private let wholeMac = NSPopUpButton()
    private let curtain = NSButton(checkboxWithTitle: "Curtain while the whole Mac is shared", target: nil, action: nil)
    private var revealed = false

    init(link: @escaping () -> String, password: @escaping () -> String, trust: HostTrust) {
        self.link = link
        self.password = password
        self.trust = trust
        super.init(nibName: nil, bundle: nil)
        title = "Sharing This Mac"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let pair = Form.button("Pair a New Viewer…", self, #selector(pairNew), symbol: "plus.circle")
        let paired = Form.button("Paired Macs…", self, #selector(showPaired))
        pairedLabel.textColor = .secondaryLabelColor
        pairedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let viewers = Form.column([Form.row([pair, paired]), pairedLabel], spacing: 6)

        linkLabel.isSelectable = true
        linkLabel.lineBreakMode = .byTruncatingMiddle
        linkLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        linkLabel.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let copyLink = Form.button("Copy", self, #selector(copyLinkClicked), symbol: "doc.on.doc")
        copyLink.controlSize = .small
        passwordLabel.isSelectable = true
        passwordLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        passwordLabel.widthAnchor.constraint(equalToConstant: 226).isActive = true
        reveal.bezelStyle = .accessoryBarAction
        reveal.isBordered = false
        reveal.title = ""
        reveal.imagePosition = .imageOnly
        reveal.widthAnchor.constraint(equalToConstant: 24).isActive = true
        reveal.target = self
        reveal.action = #selector(toggleReveal)
        let copyPassword = Form.button("Copy", self, #selector(copyPasswordClicked), symbol: "doc.on.doc")
        copyPassword.controlSize = .small

        for r in [screenRow, accessRow] { r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY }
        dialogs.target = self
        dialogs.action = #selector(toggleDialogs)
        let windows = Form.column([dialogs, Form.note("A sheet, alert, Save or Print panel that opens over a shared window gets its own window on the viewer, next to that window. Off: sheets and menus are drawn into the window's picture.")])
        wholeMac.addItems(withTitles: WholeMacMode.allCases.map(\.label))
        wholeMac.target = self
        wholeMac.action = #selector(wholeMacChanged)
        curtain.target = self
        curtain.action = #selector(toggleCurtain)
        let whole = Form.column([
            Form.row([Form.label("Allow Whole Mac:"), wholeMac]),
            Form.note("Paired Macs and password viewers get a Whole Mac card that shows and controls this Mac's entire screen. Ask: a notice here asks the first time each viewer opens it. On a Mac with no screen attached, the Stage at the viewer's size becomes the screen."),
            curtain,
            Form.note("A frosted notice covers this Mac's screens and its keyboard, mouse and trackpad are paused while the whole Mac is shared. \(CurtainFilter.escapeHint) takes it back; it also lifts after 30 minutes."),
        ])
        whole.setCustomSpacing(10, after: whole.arrangedSubviews[1])

        let grid = Form.grid([
            [Form.label("Viewers:"), viewers],
            [Form.label("Browser link:"), Form.column([Form.row([linkLabel, copyLink]),
                                                        Form.note("Opens this Mac's windows in any browser with the password.")])],
            [Form.label("Password:"), Form.row([passwordLabel, reveal, copyPassword], spacing: 4)],
            [Form.label("Windows:"), windows],
            [Form.label("Whole Mac:"), whole],
            [Form.label("Screen Recording:"), screenRow],
            [Form.label("Accessibility:"), accessRow],
        ])
        grid.row(at: 1).topPadding = 10
        grid.row(at: 3).topPadding = 10
        grid.row(at: 4).topPadding = 10
        grid.row(at: 5).topPadding = 10
        view = Form.pane(grid)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        linkLabel.stringValue = link()
        linkLabel.toolTip = link()
        passwordLabel.stringValue = revealed ? password() : String(repeating: "•", count: min(password().count, 16))
        reveal.image = NSImage(systemSymbolName: revealed ? "eye.slash" : "eye", accessibilityDescription: revealed ? "Hide" : "Show")
        let n = trust.store.devices().count
        pairedLabel.stringValue = n == 0 ? "No Macs are paired yet." : "\(n) Mac\(n == 1 ? " is" : "s are") paired with this one."
        dialogs.state = CompanionRules.enabled(stored: UserDefaults.standard.object(forKey: CompanionRules.settingKey), environment: [:]) ? .on : .off
        let mode = WholeMac.mode(stored: UserDefaults.standard.object(forKey: WholeMac.settingKey), environment: [:])
        wholeMac.selectItem(at: WholeMacMode.allCases.firstIndex(of: mode) ?? 1)
        curtain.state = CurtainSetting.enabled(stored: UserDefaults.standard.object(forKey: CurtainSetting.settingKey), environment: [:]) ? .on : .off
        curtain.isEnabled = mode != .off
        fill(screenRow, ok: CGPreflightScreenCaptureAccess(), action: #selector(openScreenSettings))
        fill(accessRow, ok: InputInjector.isTrusted, action: #selector(openAXSettings))
    }

    private func fill(_ row: NSStackView, ok: Bool, action: Selector) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        row.addArrangedSubview(Form.status(ok, ok ? "Allowed" : "Not allowed"))
        if !ok {
            let b = Form.button("Open System Settings…", self, action)
            b.controlSize = .small
            row.addArrangedSubview(b)
        }
    }

    @objc private func toggleDialogs() {
        let on = dialogs.state == .on
        UserDefaults.standard.set(on, forKey: CompanionRules.settingKey)
        Log.info("settings: show dialogs as their own windows \(on ? "on" : "off")")
    }

    @objc private func wholeMacChanged() {
        let mode = WholeMacMode.allCases[max(0, wholeMac.indexOfSelectedItem)]
        UserDefaults.standard.set(mode.rawValue, forKey: WholeMac.settingKey)
        Log.info("settings: allow whole mac \(mode.rawValue)")
        refresh()
    }

    @objc private func toggleCurtain() {
        let on = curtain.state == .on
        UserDefaults.standard.set(on, forKey: CurtainSetting.settingKey)
        Log.info("settings: curtain while the whole mac is shared \(on ? "on" : "off")")
        (NSApp.delegate as? HostApp)?.host.wholeMacChanged()
    }

    @objc private func pairNew() { trust.presentNewCode() }
    @objc private func showPaired() { trust.showPaired() }
    @objc private func toggleReveal() { revealed.toggle(); refresh() }
    @objc private func copyLinkClicked() { Form.copy(link()) }
    @objc private func copyPasswordClicked() { Form.copy(password()) }
    @objc private func openScreenSettings() { HostSystemSettings.openScreenRecording() }
    @objc private func openAXSettings() { HostSystemSettings.openAccessibility() }
}

@MainActor
final class HelpPane: NSViewController {
    private let verbose = NSButton(checkboxWithTitle: "Verbose logging", target: nil, action: nil)

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Help"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        verbose.target = self
        verbose.action = #selector(toggleVerbose)
        let logs = Form.button("Open Log Folder", self, #selector(openLogFolder), symbol: "folder")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
        let about = Form.label("Porthole Host \(version)")
        about.textColor = .secondaryLabelColor
        let grid = Form.grid([
            [Form.label("Logs:"), Form.column([logs, Form.note("~/Library/Logs/Porthole. Nothing is uploaded.")], spacing: 6)],
            [Form.label("Diagnostics:"), Form.column([verbose, Form.note("Also logs every key and mouse event viewers send.")])],
            [Form.label("Version:"), about],
        ])
        grid.row(at: 1).topPadding = 8
        grid.row(at: 2).topPadding = 8
        view = Form.pane(grid)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        verbose.state = Log.verbose ? .on : .off
    }

    @objc private func toggleVerbose() {
        Log.verbose = verbose.state == .on
        UserDefaults.standard.set(Log.verbose, forKey: HostSettings.verboseKey)
        Log.info("settings: verbose logging \(Log.verbose ? "on" : "off")", .ui)
    }

    @objc private func openLogFolder() { NSWorkspace.shared.open(Log.url.deletingLastPathComponent()) }
}

enum HostSystemSettings {
    static func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    static func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
