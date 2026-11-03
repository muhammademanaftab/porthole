import AppKit
import ApplicationServices
import PortholeCore

/// Private but long-standing: maps an Accessibility window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Recreates a viewer's keyboard, pointer and resize input on this Mac.
/// Events are posted system-wide at the window's position, after bringing that window to the front.
@MainActor
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var focusedWindow: UInt32?
    private var buttonsDown: Set<Int> = []

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func handle(_ m: Message) {
        guard let id = m.win, let live = LiveWindow.lookup(id) else { return }
        switch m.t {
        case .mouse: mouse(m, id: id, live: live)
        case .scroll: scroll(m, live: live)
        case .key: key(m, id: id, live: live)
        case .text: text(m, id: id, live: live)
        case .resize: resize(id: id, live: live, w: m.w, h: m.h)
        default: break
        }
    }

    // MARK: Focus

    private func axWindow(id: UInt32, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow(w, &wid) == .success && wid == id
        }
    }

    /// Bring the window's app forward and raise the window, unless it already is in front.
    private func focus(id: UInt32, live: LiveWindow) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == live.pid && focusedWindow == id { return }
        NSRunningApplication(processIdentifier: live.pid)?.activate()
        if let w = axWindow(id: id, pid: live.pid) {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        focusedWindow = id
    }

    // MARK: Pointer

    private func mouse(_ m: Message, id: UInt32, live: LiveWindow) {
        let p = globalPoint(nx: m.x ?? 0.5, ny: m.y ?? 0.5, windowBounds: live.bounds)
        let btn = m.btn ?? 0
        let button: CGMouseButton = btn == 1 ? .right : (btn == 2 ? .center : .left)
        let type: CGEventType
        switch m.kind ?? .move {
        case .down:
            focus(id: id, live: live)
            buttonsDown.insert(btn)
            type = btn == 1 ? .rightMouseDown : (btn == 2 ? .otherMouseDown : .leftMouseDown)
        case .up:
            buttonsDown.remove(btn)
            type = btn == 1 ? .rightMouseUp : (btn == 2 ? .otherMouseUp : .leftMouseUp)
        case .drag:
            type = btn == 1 ? .rightMouseDragged : (btn == 2 ? .otherMouseDragged : .leftMouseDragged)
        case .move:
            type = .mouseMoved
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if let clicks = m.clicks, clicks > 1 { e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        e.flags = flags(m.mods)
        e.post(tap: .cghidEventTap)
    }

    private func scroll(_ m: Message, live: LiveWindow) {
        let p = globalPoint(nx: m.x ?? 0.5, ny: m.y ?? 0.5, windowBounds: live.bounds)
        // Put the pointer over the window first so the scroll lands on the right view.
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32((m.dy ?? 0).rounded()), wheel2: Int32((m.dx ?? 0).rounded()), wheel3: 0) else { return }
        e.location = p
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func flags(_ mods: UInt32?) -> CGEventFlags {
        let m = Modifiers(rawValue: mods ?? 0)
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        return f
    }

    /// Modifier keys themselves: their state travels as flags on every other event instead.
    private static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private func key(_ m: Message, id: UInt32, live: LiveWindow) {
        guard let code = m.code, !Self.modifierCodes.contains(code) else { return }
        let down = m.down ?? true
        if down { focus(id: id, live: live) }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags(m.mods)
        e.post(tap: .cghidEventTap)
    }

    /// Committed text (paste-as-text, dictation, characters with no key): typed in small batches.
    private func text(_ m: Message, id: UInt32, live: LiveWindow) {
        guard let s = m.s, !s.isEmpty else { return }
        focus(id: id, live: live)
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
            i += 20
        }
    }

    // MARK: Resize

    private func resize(id: UInt32, live: LiveWindow, w: Double?, h: Double?) {
        guard let w, let h, w >= 100, h >= 80, let ax = axWindow(id: id, pid: live.pid) else { return }
        var size = CGSize(width: w, height: h)
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, value)
    }
}
