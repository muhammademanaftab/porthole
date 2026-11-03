import AppKit
import LiveKit
import PortholeCore

@MainActor
final class PortalWindow: NSWindow, NSWindowDelegate, TrackDelegate {
    let windowID: UInt32
    let connection: Connection
    let videoView = VideoView()
    let inputView: InputCaptureView
    private var track: VideoTrack?
    var onClose: (() -> Void)?

    init(windowID: UInt32, title: String, size: CGSize, track: VideoTrack, connection: Connection) {
        self.windowID = windowID
        self.connection = connection
        inputView = InputCaptureView(windowID: windowID, connection: connection)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(max(size.width, 320), screen.width), h = min(max(size.height, 200), screen.height)
        super.init(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        delegate = self
        backgroundColor = .black
        tabbingMode = .disallowed

        let content = NSView()
        content.wantsLayer = true
        videoView.layoutMode = .fit
        for v in [videoView, inputView] as [NSView] {
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
        attach(track)
        center()
        makeFirstResponder(inputView)
    }

    func attach(_ track: VideoTrack) {
        self.track = track
        videoView.track = track
        track.add(delegate: self)
        if let d = track.dimensions { inputView.contentPixels = CGSize(width: Int(d.width), height: Int(d.height)) }
    }

    nonisolated func track(_ track: VideoTrack, didUpdateDimensions dimensions: Dimensions?) {
        guard let d = dimensions else { return }
        Task { @MainActor in self.inputView.contentPixels = CGSize(width: Int(d.width), height: Int(d.height)) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let size = contentView?.bounds.size else { return }
        var m = Message(.resize); m.win = windowID; m.w = size.width; m.h = size.height
        connection.send(m)
    }

    func windowWillClose(_ notification: Notification) {
        videoView.track = nil
        onClose?()
    }

    override var canBecomeKey: Bool { true }
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
        var m = Modifiers()
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        return m.rawValue
    }

    private func point(_ e: NSEvent) -> CGPoint? {
        let p = convert(e.locationInWindow, from: nil)
        let content = contentPixels == .zero ? bounds.size : contentPixels
        return normalized(p, content: content, in: bounds)
    }

    private func sendMouse(_ e: NSEvent, kind: Message.MouseKind, button: Int) {
        guard let p = point(e) else { return }
        if kind == .move || kind == .drag {
            guard Date().timeIntervalSince(lastMove) > 1.0 / 60 else { return }
            lastMove = Date()
        }
        var m = Message(.mouse)
        m.win = windowID; m.kind = kind; m.btn = button; m.x = p.x; m.y = p.y
        m.mods = Self.mods(e.modifierFlags)
        if kind == .down || kind == .up { m.clicks = e.clickCount }
        connection.send(m, reliable: kind == .down || kind == .up)
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
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        var m = Message(.scroll)
        m.win = windowID; m.x = p.x; m.y = p.y
        m.dx = e.scrollingDeltaX * k; m.dy = e.scrollingDeltaY * k
        connection.send(m)
    }

    private func sendKey(_ e: NSEvent, down: Bool) {
        var m = Message(.key)
        m.win = windowID; m.code = e.keyCode; m.down = down; m.mods = Self.mods(e.modifierFlags)
        m.s = e.characters
        connection.send(m)
    }

    override func keyDown(with e: NSEvent) { sendKey(e, down: true) }
    override func keyUp(with e: NSEvent) { sendKey(e, down: false) }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return false }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" { return false }
        sendKey(e, down: true)
        sendKey(e, down: false)
        return true
    }
}
