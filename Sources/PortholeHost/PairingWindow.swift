import AppKit
import PortholeCore

@MainActor
final class PairingWindow: NSPanel, NSWindowDelegate {
    private let desk: PairingDesk
    private let codeLabel = NSTextField(labelWithString: "")
    private let intro = NSTextField(wrappingLabelWithString: "")
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
        _ = desk.issue()
        show()
    }

    func presentRequest() {
        show()
    }

    private func show() {
        if let who = desk.requester {
            title = "\(who.name) wants to view this Mac"
            intro.stringValue = "Type this code on \(who.name) to let it view this Mac's windows from now on. Pairing is one way."
        } else {
            title = "Pair a New Viewer"
            intro.stringValue = "On the other Mac, open Porthole, choose Connect to Host…, pick this Mac and type this code."
        }
        watch()
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    @objc private func newCode() {
        _ = desk.reissue()
        watch()
    }

    private func watch() {
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
            let who = desk.requester?.name ?? "The viewer"
            detail.stringValue = "Paired. \(who) can view this Mac from now on."
            Log.info("\(who) paired with a code")
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
