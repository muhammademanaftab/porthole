import AppKit
import PortholeCore

@MainActor
final class PairingWindow: NSPanel, NSWindowDelegate {
    private let desk: PairingDesk
    private let codeLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(desk: PairingDesk) {
        self.desk = desk
        super.init(contentRect: CGRect(x: 0, y: 0, width: 360, height: 200),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Pair a New Viewer"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        delegate = self

        let intro = NSTextField(wrappingLabelWithString:
            "On the other Mac, open Porthole, choose Connect to Host…, pick this Mac and type this code.")
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.isSelectable = true
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        let again = NSButton(title: "New Code", target: self, action: #selector(newCode))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [again, NSView(), done])
        let root = NSStackView(views: [intro, codeLabel, detail, buttons])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for v in [intro, codeLabel, detail, buttons] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        contentView = root
    }

    func present() {
        newCode()
        center()
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    @objc private func newCode() {
        _ = desk.issue()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.showState() }
        }
        showState()
    }

    private func showState() {
        switch desk.state() {
        case .active(let code, let left):
            codeLabel.stringValue = displayPairingCode(code)
            codeLabel.textColor = .labelColor
            detail.stringValue = "Valid for \(left / 60):\(String(format: "%02d", left % 60)), one viewer, \(PairingCodes.maxWrongTries) tries."
            return
        case .used:
            detail.stringValue = "Paired. The viewer has this Mac's password now."
            Log.info("a viewer paired with a code")
        case .expired: detail.stringValue = "The code expired. Click New Code for another."
        case .locked:
            detail.stringValue = "Too many wrong tries, so the code was cancelled."
            Log.info("pairing code cancelled after too many wrong tries")
        case .idle: detail.stringValue = ""
        }
        codeLabel.textColor = .tertiaryLabelColor
        timer?.invalidate()
        timer = nil
    }

    @objc private func finish() { close() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        desk.cancel()
    }
}
