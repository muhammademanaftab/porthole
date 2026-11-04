import AppKit
import ApplicationServices
import PortholeCore

@MainActor
final class InputInjector {
    private let source: CGEventSource? = PortholeEventTag.source()
    private var focusedWindow: UInt32?
    private var buttonsDown: Set<Int> = []
    private var axWindows: [UInt32: AXUIElement] = [:]
    let textBatch = TextBatch.units()
    static let resizeTimeout: Float = 0.25

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func handle(_ m: Message) {
        guard let id = m.win, let live = LiveWindow.lookup(id) else { return }
        let focus: () -> Void = { [weak self] in self?.focus(id: id, live: live) }
        switch m.t {
        case .mouse: mouse(m, bounds: live.bounds, focus: focus)
        case .scroll: scroll(m, bounds: live.bounds)
        case .key: key(m, focus: focus)
        case .text: text(m, focus: focus)
        case .resize: break
        default: break
        }
    }

    func handle(_ m: Message, screen bounds: CGRect) {
        guard WholeMac.acceptsInput(m.t) else { return }
        let none: () -> Void = {}
        switch m.t {
        case .mouse: mouse(m, bounds: bounds, focus: none)
        case .scroll: scroll(m, bounds: bounds)
        case .key: key(m, focus: none)
        case .text: text(m, focus: none)
        default: break
        }
    }

    private func focus(id: UInt32, live: LiveWindow) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == live.pid && AXWindows.focusedWindowID(pid: live.pid) == id { return }
        let app = AXWindows.app(live.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: live.pid)?.activate()
        if let w = AXWindows.window(id: id, pid: live.pid) {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        focusedWindow = id
    }

    func releaseAllButtons() {
        guard !buttonsDown.isEmpty else { return }
        let p = CGEvent(source: nil)?.location ?? .zero
        for btn in buttonsDown {
            CGEvent(mouseEventSource: source, mouseType: MouseMapping.eventType(.up, button: btn), mouseCursorPosition: p,
                    mouseButton: MouseMapping.button(btn))?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
    }

    private func mouse(_ m: Message, bounds: CGRect, focus: () -> Void) {
        let p = globalPoint(nx: m.x ?? 0.5, ny: m.y ?? 0.5, windowBounds: bounds)
        let btn = m.btn ?? 0
        let kind = m.kind ?? .move
        if kind != .move, WholeMac.blocksInjectedClick(at: p, guarded: WholeMacPrompt.guarded + GuardedPanel.visibleFrames()) {
            Log.info("input: dropped a viewer click on the Whole Mac question")
            return
        }
        switch kind {
        case .down:
            focus()
            buttonsDown.insert(btn)
        case .up:
            buttonsDown.remove(btn)
        case .drag, .move:
            break
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: MouseMapping.eventType(kind, button: btn),
                              mouseCursorPosition: p, mouseButton: MouseMapping.button(btn)) else { return }
        if let clicks = MouseMapping.clickState(m.clicks) { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
        e.flags = flags(m.mods)
        e.post(tap: .cghidEventTap)
    }

    private func scroll(_ m: Message, bounds: CGRect) {
        let p = globalPoint(nx: m.x ?? 0.5, ny: m.y ?? 0.5, windowBounds: bounds)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let (wheel1, wheel2) = MouseMapping.wheelDeltas(dx: m.dx, dy: m.dy)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: wheel1, wheel2: wheel2, wheel3: 0) else { return }
        e.location = p
        e.post(tap: .cghidEventTap)
    }

    private func flags(_ mods: UInt32?) -> CGEventFlags {
        Modifiers(rawValue: mods ?? 0).cgEventFlags
    }

    private func key(_ m: Message, focus: () -> Void) {
        guard let code = m.code else { return }
        let down = m.down ?? true
        if Modifiers.flagKeyCodes.contains(code) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = flags(m.mods)
            e.post(tap: .cghidEventTap)
            return
        }
        if down { focus() }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags(m.mods)
        e.post(tap: .cghidEventTap)
    }

    private func text(_ m: Message, focus: () -> Void) {
        guard let s = m.s, !s.isEmpty else { return }
        focus()
        let pieces = TextBatch.pieces(TextBatch.limited(s), maxUnits: textBatch)
        for e in InjectedText.events(pieces, source: source) { e.post(tap: .cghidEventTap) }
        Log.debug("text: \(s.utf16.count) UTF-16 units typed as \(pieces.count) key pair(s), batch \(textBatch)")
    }

    func resize(_ m: Message) -> (asked: CGSize, actual: CGSize)? {
        guard let id = m.win, let live = LiveWindow.lookup(id), let asked = resizeTarget(w: m.w, h: m.h) else { return nil }
        let plan = ResizePlan.make(window: live.bounds, asked: asked, areas: Self.usableAreas())
        for attempt in 0..<2 {
            guard let ax = axWindow(id, pid: live.pid) else {
                Log.info("resize: window \(id) of pid \(live.pid) has no accessibility element")
                return nil
            }
            if let origin = plan.origin { AXWindows.setPosition(ax, origin) }
            if AXWindows.setSize(ax, plan.size) || attempt == 1 { return (asked, AXWindows.size(ax) ?? plan.size) }
            axWindows[id] = nil
        }
        return nil
    }

    private func axWindow(_ id: UInt32, pid: pid_t) -> AXUIElement? {
        if let cached = axWindows[id] { return cached }
        guard let w = AXWindows.window(id: id, pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(w, Self.resizeTimeout)
        axWindows[id] = w
        return w
    }

    func forget(_ id: UInt32) {
        axWindows[id] = nil
    }

    static func usableAreas() -> [CGRect] {
        guard let primary = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { s in
            let v = s.visibleFrame
            return CGRect(x: v.minX, y: primary - v.maxY, width: v.width, height: v.height)
        }
    }
}
