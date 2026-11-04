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
    private var throttle = LiveResizeThrottle()
    private var limits = PortalSizing.Limits()
    private var resizeEndedAt: Double?
    let isCompanion: Bool
    var companionOf: UInt32?
    var companionOffer: Message?
    var closedByHost = false
    var onLayout: (() -> Void)?
    private var autoHideGlobal = false
    private(set) var autoHideOverride: Bool?
    private var reveal = TitleBarReveal()
    private var revealTimer: Timer?
    private let barBackdrop = TitleBarBackdrop()
    private var barTop: NSLayoutConstraint?

    init(windowID: UInt32, title: String, subtitle: String, app: String, size: CGSize, connection: Connection, companion: Bool = false) {
        self.windowID = windowID
        self.connection = connection
        self.appName = app
        self.isCompanion = companion
        inputView = InputCaptureView(windowID: windowID, connection: connection)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = portalContentSize(remote: size, screen: screen.size)
        super.init(contentRect: CGRect(origin: .zero, size: fitted),
                   styleMask: companion ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
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
        barBackdrop.translatesAutoresizingMaskIntoConstraints = false
        barBackdrop.isHidden = true
        content.addSubview(barBackdrop, positioned: .below, relativeTo: overlay)
        let top = barBackdrop.topAnchor.constraint(equalTo: content.topAnchor)
        barTop = top
        NSLayoutConstraint.activate([
            barBackdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            barBackdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            top,
            barBackdrop.heightAnchor.constraint(equalToConstant: 28),
        ])
        contentView = content
        contentMinSize = CGSize(width: 100, height: 80)
        show(.opening(app))
        if companion { hasShadow = true; alphaValue = 0 } else { center() }
        makeFirstResponder(inputView)
    }

    func attach(_ track: VideoTrack) {
        self.track?.remove(delegate: self)
        self.track = track
        videoView.track = track
        track.add(delegate: self)
        if let d = track.dimensions {
            inputView.contentPixels = CGSize(width: Int(d.width), height: Int(d.height))
            if phase?.clearsOnPicture == true { show(nil) }
            if isCompanion { alphaValue = 1 }
        }
        updatePictureMode()
    }

    func reopen() {
        track?.remove(delegate: self)
        track = nil
        videoView.track = nil
        show(.opening(appName))
    }

    private(set) var requests = 0

    func beginRequest() -> Int {
        requests += 1
        return requests
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
        if case .opening = next, track?.dimensions != nil || isCompanion { phase = nil } else if isCompanion, next == .reconnecting { phase = nil } else { phase = next }
        if isCompanion, phase != nil { alphaValue = 1 }
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
            guard track === self.track else { return }
            self.inputView.contentPixels = CGSize(width: Int(d.width), height: Int(d.height))
            if self.phase?.clearsOnPicture == true { self.show(nil) }
            if self.isCompanion { self.alphaValue = 1 }
            self.updatePictureMode()
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if let phase, event.type == .keyDown || event.type == .keyUp, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if event.type == .keyDown, !event.isARepeat, phase.canRetry { overlay.retryClicked() }
            return
        }
        super.sendEvent(event)
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private var pictureSize: CGSize? { contentView?.bounds.size }

    private func sendResize(_ size: CGSize) {
        var m = Message(.resize); m.win = windowID; m.w = size.width; m.h = size.height
        connection.send(m)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        updatePictureMode()
    }

    func windowDidResize(_ notification: Notification) {
        onLayout?()
        guard inLiveResize, let size = pictureSize else { return }
        if let s = throttle.during(size, now: Self.now) { sendResize(s) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let size = pictureSize else { return }
        sendResize(throttle.finish(size, now: Self.now))
        resizeEndedAt = Self.now
        updatePictureMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + PictureFit.settleSeconds + 0.05) { [weak self] in self?.updatePictureMode() }
    }

    func hostSized(_ m: Message) {
        guard let w = m.w, let h = m.h, let aw = m.aw, let ah = m.ah else { return }
        let actual = CGSize(width: w, height: h), asked = CGSize(width: aw, height: ah)
        limits.learn(asked: asked, actual: actual)
        contentMinSize = CGSize(width: max(100, limits.minimum.width), height: max(80, limits.minimum.height))
        contentMaxSize = limits.maximum
        let screen = self.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        guard let target = PortalSizing.snap(asked: asked, lastSent: throttle.lastSent, actual: actual,
                                             liveResizing: inLiveResize, screen: screen),
              target != pictureSize else { return }
        let top = frame.maxY
        setContentSize(target)
        setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top))
    }

    func updatePictureMode() {
        let video = track?.dimensions.map { CGSize(width: Int($0.width), height: Int($0.height)) }
        let since = resizeEndedAt.map { Self.now - $0 }
        let mode = PictureFit.mode(liveResizing: inLiveResize, video: video, view: pictureSize ?? .zero, sinceResizeEnd: since)
        let layout: VideoView.LayoutMode = mode == .fill ? .fill : .fit
        if videoView.layoutMode != layout { videoView.layoutMode = layout }
        inputView.fill = mode == .fill
        onLayout?()
    }

    var pictureOnScreen: CGRect? {
        guard let content = contentView else { return nil }
        let px = inputView.contentPixels
        let r = px == .zero ? content.bounds : fittedRect(content: px, in: content.bounds)
        return convertToScreen(content.convert(r, to: nil))
    }

    func place(companion m: Message, over parent: PortalWindow) {
        guard let picture = parent.pictureOnScreen, let w = m.w, let h = m.h else { return }
        companionOffer = m
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let r = CompanionRules.placement(offset: CGPoint(x: m.x ?? 0, y: m.y ?? 0), size: CGSize(width: w, height: h),
                                         parentSize: CGSize(width: m.pw ?? 0, height: m.ph ?? 0), picture: picture, screen: screen)
        if r != frame { setFrame(r, display: true) }
    }

    var autoHidesTitleBar: Bool { !isCompanion && TitleBarReveal.autoHide(global: autoHideGlobal, override: autoHideOverride) }

    func applyTitleBar(global: Bool) {
        autoHideGlobal = global
        applyTitleBarMode()
    }

    @objc func toggleTitleBarAutoHide(_ sender: Any?) {
        let next = !autoHidesTitleBar
        autoHideOverride = next == autoHideGlobal ? nil : next
        applyTitleBarMode()
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTitleBarAutoHide(_:)) {
            item.state = autoHidesTitleBar ? .on : .off
            return !isCompanion && !styleMask.contains(.fullScreen)
        }
        return super.validateMenuItem(item)
    }

    private var titlebarContainer: NSView? { standardWindowButton(.closeButton)?.superview?.superview }

    private func applyTitleBarMode() {
        guard !isCompanion else { return }
        let on = autoHidesTitleBar
        guard on != styleMask.contains(.fullSizeContentView) else { return }
        let keep = pictureSize ?? .zero
        let top = frame.maxY
        if on {
            styleMask.insert(.fullSizeContentView)
            titlebarAppearsTransparent = true
            titleVisibility = .hidden
        } else {
            styleMask.remove(.fullSizeContentView)
            titlebarAppearsTransparent = false
            titleVisibility = .visible
        }
        keepPictureSize(keep, top: top)
        reveal.hide()
        if on {
            barBackdrop.isHidden = false
            showBar(false, animated: false)
            startRevealTimer()
        } else {
            revealTimer?.invalidate(); revealTimer = nil
            barBackdrop.isHidden = true
            titlebarContainer?.isHidden = false
            titlebarContainer?.alphaValue = 1
        }
    }

    private func keepPictureSize(_ size: CGSize, top: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        for _ in 0..<2 {
            guard let now = pictureSize, now != size else { break }
            let f = CGRect(x: frame.minX, y: top - (frame.height + size.height - now.height),
                           width: frame.width + size.width - now.width, height: frame.height + size.height - now.height)
            setFrame(f, display: true)
        }
    }

    private func startRevealTimer() {
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: TitleBarReveal.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
    }

    private func pollPointer() {
        guard autoHidesTitleBar, isVisible, !styleMask.contains(.fullScreen) else { return }
        let was = reveal.shown
        let d = TitleBarReveal.distanceFromTop(pointer: NSEvent.mouseLocation, frame: frame)
        let shown = reveal.pointer(distanceFromTop: (NSApp.isActive || isKeyWindow) ? d : nil, now: Self.now)
        if shown != was { showBar(shown, animated: true) }
    }

    private func showBar(_ shown: Bool, animated: Bool) {
        guard let bar = titlebarContainer else { return }
        let height = max(28, frame.height - contentLayoutRect.height)
        barTop?.constant = shown ? 0 : -height
        if shown {
            bar.isHidden = false
            titleVisibility = .visible
        }
        let finish = { [weak self, weak bar] in
            guard let self, let bar, !self.reveal.shown, self.autoHidesTitleBar else { return }
            bar.isHidden = true
            self.titleVisibility = .hidden
        }
        guard animated else {
            bar.alphaValue = shown ? 1 : 0
            barBackdrop.alphaValue = shown ? 1 : 0
            contentView?.layoutSubtreeIfNeeded()
            if !shown { finish() }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            bar.animator().alphaValue = shown ? 1 : 0
            barBackdrop.animator().alphaValue = shown ? 1 : 0
            contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { MainActor.assumeIsolated { if !shown { finish() } } })
    }

    func windowWillClose(_ notification: Notification) {
        revealTimer?.invalidate(); revealTimer = nil
        track?.remove(delegate: self)
        videoView.track = nil
        onClose?()
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class TitleBarBackdrop: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .titlebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

    @objc func retryClicked() { onRetry?() }
    @objc private func closeClicked() { onClose?() }
}

@MainActor
final class InputCaptureView: NSView {
    let windowID: UInt32
    let connection: Connection
    var contentPixels = CGSize.zero
    var fill = false
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
        ViewerInput.point(convert(e.locationInWindow, from: nil), kind: kind, contentPixels: contentPixels, bounds: bounds, fill: fill)
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
