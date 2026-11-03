import AppKit
import PortholeCore

@MainActor
final class SettingsWindow: NSWindow, NSWindowDelegate {
    private let keepRunning = NSButton(checkboxWithTitle: "Keep Porthole Host running on this Mac", target: nil, action: nil)
    private let keepStatus = NSTextField(wrappingLabelWithString: "")
    private let approve = NSButton(title: "Open Login Items…", target: nil, action: nil)
    private let linkLabel = NSTextField(labelWithString: "")
    private let verbose = NSButton(checkboxWithTitle: "Verbose logging", target: nil, action: nil)
    private let link: () -> String
    private let password: () -> String
    private var lastError: String?

    init(link: @escaping () -> String, password: @escaping () -> String) {
        self.link = link
        self.password = password
        super.init(contentRect: CGRect(x: 0, y: 0, width: 480, height: 400),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Porthole Host Settings"
        isReleasedWhenClosed = false
        delegate = self

        keepRunning.target = self
        keepRunning.action = #selector(toggleKeepRunning)
        let keepNote = note("Starts it at login, relaunches it after a crash or a hang, and lets your paired Macs restart it. Quit keeps it stopped until you open it again or log in again.")
        keepStatus.textColor = .systemOrange
        approve.target = self
        approve.action = #selector(openLoginItems)
        let approveRow = NSStackView(views: [keepStatus, approve])
        approveRow.alignment = .centerY

        let name = NSTextField(labelWithString: "This Mac: \(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)")
        linkLabel.isSelectable = true
        linkLabel.lineBreakMode = .byTruncatingMiddle
        linkLabel.textColor = .secondaryLabelColor
        let copyLink = NSButton(title: "Copy Link", target: self, action: #selector(copyLinkClicked))
        let linkRow = NSStackView(views: [NSTextField(labelWithString: "Browser link:"), linkLabel, copyLink])
        linkRow.alignment = .firstBaseline
        linkLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copyPassword = NSButton(title: "Copy Password", target: self, action: #selector(copyPasswordClicked))

        let openLogs = NSButton(title: "Open Log Folder", target: self, action: #selector(openLogFolder))
        verbose.target = self
        verbose.action = #selector(toggleVerbose)
        let verboseNote = note("Also logs every key and mouse event viewers send. Logs are in ~/Library/Logs/Porthole.")

        let views: [NSView] = [heading("Sharing This Mac"), keepRunning, keepNote, approveRow, name, linkRow, copyPassword,
                               separator(), heading("Help"), openLogs, verbose, verboseNote]
        let root = NSStackView(views: views)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [keepNote, approveRow, linkRow, verboseNote, views[7]] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        root.setCustomSpacing(4, after: keepRunning)
        root.setCustomSpacing(4, after: verbose)
        root.setCustomSpacing(16, after: approveRow)
        contentView = root
        refresh()
    }

    private func heading(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        return t
    }

    private func note(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.textColor = .secondaryLabelColor
        t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return t
    }

    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    func present() {
        refresh()
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let on = HostSettings(lookup: { UserDefaults.standard.object(forKey: $0) }).keepRunning
        keepRunning.state = on ? .on : .off
        verbose.state = Log.verbose ? .on : .off
        linkLabel.stringValue = link()
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
        approve.superview?.isHidden = keepStatus.isHidden && approve.isHidden
    }

    @objc private func toggleKeepRunning() {
        let on = keepRunning.state == .on
        UserDefaults.standard.set(on, forKey: HostSettings.keepRunningKey)
        Log.info("settings: keep running \(on ? "on" : "off")")
        lastError = KeepRunning.apply(on)
        refresh()
    }

    @objc private func toggleVerbose() {
        Log.verbose = verbose.state == .on
        UserDefaults.standard.set(Log.verbose, forKey: HostSettings.verboseKey)
        Log.info("settings: verbose logging \(Log.verbose ? "on" : "off")")
    }

    @objc private func openLoginItems() { KeepRunning.openLoginItems() }
    @objc private func openLogFolder() { NSWorkspace.shared.open(Log.url.deletingLastPathComponent()) }
    @objc private func copyLinkClicked() { copy(link()) }
    @objc private func copyPasswordClicked() { copy(password()) }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}
