import AppKit
import PortholeCore

final class EventTapCurtain: CurtainTap, @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var blocking = false
    private var escape: (() -> Void)?

    func start(onEscape: @escaping () -> Void) -> Bool {
        stop()
        guard AXIsProcessTrusted() else { Log.info("curtain: no Accessibility permission, so local input is not blocked"); return false }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CurtainFilter.mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EventTapCurtain>.fromOpaque(info).takeUnretainedValue().filter(type, event)
        }, userInfo: me) else {
            Log.info("curtain: could not create the event tap, so local input is not blocked")
            return false
        }
        lock.lock(); port = tap; blocking = true; escape = onEscape; lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            let rl = CFRunLoopGetCurrent()
            self.lock.lock(); self.runLoop = rl; self.lock.unlock()
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "porthole.curtain"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        return true
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock(); let on = blocking; let tap = port; lock.unlock()
        guard on else { return Unmanaged.passUnretained(event) }
        let verdict = CurtainFilter.verdict(type: type, keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                                            flags: event.flags, userData: event.getIntegerValueField(.eventSourceUserData))
        switch verdict {
        case .pass: return Unmanaged.passUnretained(event)
        case .block: return nil
        case .reenable:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .escape:
            lock.lock(); blocking = false; let cb = escape; lock.unlock()
            DispatchQueue.main.async { cb?() }
            return nil
        }
    }

    func stop() {
        lock.lock()
        let tap = port, rl = runLoop
        port = nil; runLoop = nil; blocking = false; escape = nil
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let rl { CFRunLoopStop(rl) }
        thread = nil
    }
}

@MainActor
final class CurtainView: NSView {
    private let notice: CurtainNotice

    init(frame: NSRect, notice: CurtainNotice, frosted: Bool) {
        self.notice = notice
        super.init(frame: frame)
        wantsLayer = true
        if frosted {
            let fx = NSVisualEffectView(frame: bounds)
            fx.autoresizingMask = [.width, .height]
            fx.material = .fullScreenUI
            fx.blendingMode = .behindWindow
            fx.state = .active
            addSubview(fx)
        }
        let card = Self.card(notice)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let g = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.27, alpha: 0.86),
                                    NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.92)])
        g?.draw(in: bounds, angle: -90)
    }

    private static func card(_ n: CurtainNotice) -> NSView {
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.display", accessibilityDescription: nil) ?? NSImage())
        lock.symbolConfiguration = .init(pointSize: 64, weight: .light)
        lock.contentTintColor = .white
        let title = NSTextField(labelWithString: n.title)
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        let body = NSTextField(wrappingLabelWithString: n.message)
        body.font = .systemFont(ofSize: 17)
        body.textColor = NSColor.white.withAlphaComponent(0.85)
        body.alignment = .center
        body.preferredMaxLayoutWidth = 520
        let hint = NSTextField(wrappingLabelWithString: n.hint)
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 520
        let stack = NSStackView(views: [lock, title, body, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(22, after: lock)
        stack.setCustomSpacing(26, after: body)
        return stack
    }

    static func png(size: CGSize, notice: CurtainNotice) -> Data? {
        let v = CurtainView(frame: NSRect(origin: .zero, size: size), notice: notice, frosted: false)
        v.appearance = NSAppearance(named: .darkAqua)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

@MainActor
final class CurtainWindows: @preconcurrency CurtainScreens {
    private var windows: [NSWindow] = []
    private var cursorHidden = false
    var skip: () -> CGDirectDisplayID? = { nil }

    func show(_ notice: CurtainNotice) {
        hide()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
            if let id, id == skip() { continue }
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = level
            w.sharingType = .none
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.contentView = CurtainView(frame: NSRect(origin: .zero, size: screen.frame.size), notice: notice, frosted: true)
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        if !cursorHidden { CGDisplayHideCursor(kCGNullDirectDisplay); cursorHidden = true }
        Log.info("curtain: up on \(windows.count) display(s)")
    }

    func hide() {
        if cursorHidden { CGDisplayShowCursor(kCGNullDirectDisplay); cursorHidden = false }
        guard !windows.isEmpty else { return }
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        Log.info("curtain: lifted")
    }
}
