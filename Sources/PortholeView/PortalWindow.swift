import AppKit
import LiveKit
import PortholeCore

@MainActor
final class PortalWindow: NSWindow, NSWindowDelegate, TrackDelegate {
    let windowID: UInt32
    let connection: Connection
    let videoView = VideoView()
    let inputView: InputCaptureView
    private let overlay = PortalOverlay()
    private var track: VideoTrack?
    private var phase: PortalPhase?
    private let appName: String
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?

    init(windowID: UInt32, title: String, subtitle: String, app: String, size: CGSize, connection: Connection) {
        self.windowID = windowID
        self.connection = connection
        self.appName = app
        inputView = InputCaptureView(windowID: windowID, connection: connection)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = portalContentSize(remote: size, screen: screen.size)
        super.init(contentRect: CGRect(origin: .zero, size: fitted),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.title = title
        self.subtitle = subtitle
        isReleasedWhenClosed = false
        delegate = self
        backgroundColor = .black
        tabbingMode = .disallowed

        let content = NSView()
        content.wantsLayer = true
        videoView.layoutMode = .fit
        overlay.onClose = { [weak self] in self?.close() }
        overlay.onRetry = { [weak self] in
            self?.show(.opening(app))
            self?.onRetry?()
        }
        for v in [videoView, inputView, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.topAnchor.constraint(equalTo: content.topAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        contentView = content
        show(.opening(app))
        center()
        makeFirstResponder(inputView)
    }

    func attach(_ track: VideoTrack) {
        self.track?.remove(delegate: self)
        self.track = track
        videoView.track = track
        track.add(delegate: self)
        if let d = track.dimensions {
            inputView.contentPixels = CGSize(width: Int(d.width), height: Int(d.height))
            if case .opening = phase { show(nil) }
        }
    }

    func fit(remote size: CGSize) {
        let screen = self.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = portalContentSize(remote: size, screen: screen.size)
        guard fitted != contentView?.bounds.size else { return }
        let top = frame.maxY
        setContentSize(fitted)
        setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
    }

    func show(_ next: PortalPhase?) {
        if case .opening = next, track?.dimensions != nil { phase = nil } else { phase = next }
        overlay.show(phase)
    }

    var isOpening: Bool {
        if case .opening = phase { return true }
        return false
    }

    func linkChanged(_ state: Connection.LinkState) {
        switch state {
        case .reconnecting: show(.reconnecting)
        case .connected: if phase == .reconnecting { show(track?.dimensions == nil ? .opening(appName) : nil) }
        case .disconnected(let why): show(.disconnected(why))
        }
    }

    nonisolated func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
        guard let d = dimensions else { return }
        Task { @MainActor in
            self.inputView.contentPixels = CGSize(width: Int(d.width), height: Int(d.height))
            if case .opening = self.phase { self.show(nil) }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let size = contentView?.bounds.size else { return }
        var m = Message(.resize); m.win = windowID; m.w = size.width; m.h = size.height
        connection.send(m)
    }

    func windowWillClose(_ notification: Notification) {
        track?.remove(delegate: self)
        videoView.track = nil
        onClose?()
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class PortalOverlay: NSView {
    private let hud = NSVisualEffectView()
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close Window", target: nil, action: nil)
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 16
        hud.layer?.masksToBounds = true
        hud.appearance = NSAppearance(named: .darkAqua)
        spinner.style = .spinning
        spinner.controlSize = .regular
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 260
        retry.bezelStyle = .rounded
        retry.keyEquivalent = "\r"
        retry.target = self
        retry.action = #selector(retryClicked)
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let buttons = NSStackView(views: [closeButton, retry])
        buttons.spacing = 8
        let stack = NSStackView(views: [spinner, icon, heading, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: spinner)
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(14, after: detail)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        hud.addSubview(stack)
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor),
            stack.topAnchor.constraint(equalTo: hud.topAnchor),
            stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor),
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: centerYAnchor),
            hud.widthAnchor.constraint(equalToConstant: 300),
            detail.widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ phase: PortalPhase?) {
        guard let phase else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }, completionHandler: { [weak self] in
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            })
            return
        }
        isHidden = false
        alphaValue = 1
        spinner.isHidden = !phase.busy
        if phase.busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        icon.isHidden = phase.busy
        icon.image = NSImage(systemSymbolName: phase.symbol, accessibilityDescription: nil)
        heading.stringValue = phase.title
        detail.stringValue = phase.detail
        retry.isHidden = !phase.canRetry
        closeButton.isHidden = phase.busy
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    @objc private func retryClicked() { onRetry?() }
    @objc private func closeClicked() { onClose?() }
}

@MainActor
final class InputCaptureView: NSView {
    let windowID: UInt32
    let connection: Connection
    var contentPixels = CGSize.zero
    private var lastMove = Date.distantPast

    init(windowID: UInt32, connection: Connection) {
        self.windowID = windowID
        self.connection = connection
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        Modifiers(f).rawValue
    }

    private func point(_ e: NSEvent, kind: Message.MouseKind? = nil) -> CGPoint? {
        ViewerInput.point(convert(e.locationInWindow, from: nil), kind: kind, contentPixels: contentPixels, bounds: bounds)
    }

    private func sendMouse(_ e: NSEvent, kind: Message.MouseKind, button: Int) {
        guard let p = point(e, kind: kind) else { return }
        if kind == .move || kind == .drag {
            guard ViewerInput.shouldSendMove(now: Date(), last: lastMove) else { return }
            lastMove = Date()
        }
        let out = ViewerInput.mouseMessage(win: windowID, kind: kind, button: button, at: p,
                                           mods: Self.mods(e.modifierFlags), clickCount: e.clickCount)
        connection.send(out.message, reliable: out.reliable)
    }

    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); sendMouse(e, kind: .down, button: 0) }
    override func mouseUp(with e: NSEvent) { sendMouse(e, kind: .up, button: 0) }
    override func mouseDragged(with e: NSEvent) { sendMouse(e, kind: .drag, button: 0) }
    override func mouseMoved(with e: NSEvent) { sendMouse(e, kind: .move, button: 0) }
    override func rightMouseDown(with e: NSEvent) { sendMouse(e, kind: .down, button: 1) }
    override func rightMouseUp(with e: NSEvent) { sendMouse(e, kind: .up, button: 1) }
    override func rightMouseDragged(with e: NSEvent) { sendMouse(e, kind: .drag, button: 1) }
    override func otherMouseDown(with e: NSEvent) { sendMouse(e, kind: .down, button: 2) }
    override func otherMouseUp(with e: NSEvent) { sendMouse(e, kind: .up, button: 2) }

    override func scrollWheel(with e: NSEvent) {
        guard let p = point(e) else { return }
        let d = ViewerInput.scrollPixels(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas)
        var m = Message(.scroll)
        m.win = windowID; m.x = p.x; m.y = p.y
        m.dx = d.dx; m.dy = d.dy
        connection.send(m)
    }

    private func sendKey(_ e: NSEvent, down: Bool) {
        var m = Message(.key)
        m.win = windowID; m.code = e.keyCode; m.down = down; m.mods = Self.mods(e.modifierFlags)
        m.s = e.characters
        connection.send(m)
    }

    override func flagsChanged(with e: NSEvent) {
        guard let down = ViewerInput.modifierIsDown(code: e.keyCode, flags: e.modifierFlags) else { return }
        var m = Message(.key)
        m.win = windowID; m.code = e.keyCode; m.down = down; m.mods = Self.mods(e.modifierFlags)
        connection.send(m)
    }

    override func keyDown(with e: NSEvent) { sendKey(e, down: true) }
    override func keyUp(with e: NSEvent) { sendKey(e, down: false) }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return false }
        if ViewerInput.keyEquivalentStaysLocal(e.modifierFlags, characters: e.charactersIgnoringModifiers) { return false }
        sendKey(e, down: true)
        sendKey(e, down: false)
        return true
    }
}
