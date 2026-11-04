import AppKit
import PortholeCore

@MainActor
enum UnlockSheet {
    static func ask(host: String, over window: NSWindow?, send: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = UnlockPrompt.title(host: host)
        alert.informativeText = UnlockPrompt.message(host: host)
        alert.icon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Login password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { response in
            let password = field.stringValue
            field.stringValue = ""
            guard response == .alertFirstButtonReturn, !password.isEmpty else { return }
            send(password)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
            alert.window.makeFirstResponder(field)
        } else {
            alert.layout()
            alert.window.initialFirstResponder = field
            done(alert.runModal())
        }
    }

    static func outcome(_ m: Message, host: String, over window: NSWindow?, again: (() -> Void)?) {
        let alert = NSAlert()
        let unlocked = m.on == true
        alert.messageText = unlocked ? "\(host) Is Unlocked" : "\(host) Is Still Locked"
        alert.informativeText = m.msg ?? ""
        alert.icon = NSImage(systemSymbolName: unlocked ? "lock.open.fill" : "lock.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: "OK")
        if !unlocked, again != nil { alert.addButton(withTitle: "Try Again") }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn { again?() }
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}

extension ViewerApp: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(unlockHost) { return connection?.hostLocked == true && unlockStartedAt == nil }
        return true
    }

    @objc func unlockHost() {
        askUnlock(from: NSApp.keyWindow ?? picker)
    }

    func askUnlock(from window: NSWindow?) {
        guard let c = connection, unlockStartedAt == nil else { return }
        let host = hostName
        UnlockSheet.ask(host: host, over: window) { [weak self, weak c, weak window] password in
            guard let self, let c, self.connection === c, self.unlockStartedAt == nil else { return }
            self.unlockFrom = window
            self.setUnlocking(true)
            let started = Date()
            self.unlockStartedAt = started
            c.unlock(password: password)
            DispatchQueue.main.asyncAfter(deadline: .now() + UnlockPrompt.answerTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.unlockStartedAt == started else { return }
                    var m = Message(.unlock)
                    m.on = false
                    m.msg = UnlockPrompt.noAnswer
                    self.unlockAnswered(m)
                }
            }
        }
    }

    func unlockAnswered(_ m: Message) {
        guard unlockStartedAt != nil else { return }
        if UnlockPrompt.isBusyReply(m) {
            VLog.info("unlock: the host is still busy with an attempt; still waiting for its answer")
            return
        }
        unlockStartedAt = nil
        setUnlocking(false)
        let over = unlockFrom ?? picker
        unlockFrom = nil
        if m.on == true {
            for p in portals.values { p.hostUnlocked() }
            connection?.requestList()
        }
        UnlockSheet.outcome(m, host: hostName, over: over, again: { [weak self, weak over] in self?.askUnlock(from: over) })
    }

    private func setUnlocking(_ on: Bool) {
        picker?.unlocking = on
        for p in portals.values { p.unlocking = on }
    }
}
