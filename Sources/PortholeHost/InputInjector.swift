import AppKit
import ApplicationServices
import PortholeCore

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

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

    private func focusedWindowID(pid: pid_t) -> UInt32? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(v as! AXUIElement, &wid) == .success ? wid : nil
    }

    private func focus(id: UInt32, live: LiveWindow) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == live.pid && focusedWindowID(pid: live.pid) == id { return }
        let app = AXUIElementCreateApplication(live.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: live.pid)?.activate()
        if let w = axWindow(id: id, pid: live.pid) {
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
            let type: CGEventType = btn == 1 ? .rightMouseUp : (btn == 2 ? .otherMouseUp : .leftMouseUp)
            let button: CGMouseButton = btn == 1 ? .right : (btn == 2 ? .center : .left)
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
    }


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
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32((m.dy ?? 0).rounded()), wheel2: Int32((m.dx ?? 0).rounded()), wheel3: 0) else { return }
        e.location = p
        e.post(tap: .cghidEventTap)
    }


    private func flags(_ mods: UInt32?) -> CGEventFlags {
        let m = Modifiers(rawValue: mods ?? 0)
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        return f
    }

    private static let modifierCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private func key(_ m: Message, id: UInt32, live: LiveWindow) {
        guard let code = m.code else { return }
        let down = m.down ?? true
        if Self.modifierCodes.contains(code) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = flags(m.mods)
            e.post(tap: .cghidEventTap)
            return
        }
        if down { focus(id: id, live: live) }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags(m.mods)
        e.post(tap: .cghidEventTap)
    }

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


    private func resize(id: UInt32, live: LiveWindow, w: Double?, h: Double?) {
        guard let w, let h, w >= 100, h >= 80, let ax = axWindow(id: id, pid: live.pid) else { return }
        var size = CGSize(width: w, height: h)
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, value)
    }
}
