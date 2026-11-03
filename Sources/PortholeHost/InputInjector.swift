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
            CGEvent(mouseEventSource: source, mouseType: MouseMapping.eventType(.up, button: btn), mouseCursorPosition: p,
                    mouseButton: MouseMapping.button(btn))?.post(tap: .cghidEventTap)
        }
        buttonsDown.removeAll()
    }


    private func mouse(_ m: Message, id: UInt32, live: LiveWindow) {
        let p = globalPoint(nx: m.x ?? 0.5, ny: m.y ?? 0.5, windowBounds: live.bounds)
        let btn = m.btn ?? 0
        let kind = m.kind ?? .move
        switch kind {
        case .down:
            focus(id: id, live: live)
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

    private func scroll(_ m: Message, live: LiveWindow) {
        let p = globalPoint(nx: m.x ?? 0.5, ny: m.y ?? 0.5, windowBounds: live.bounds)
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

    private func key(_ m: Message, id: UInt32, live: LiveWindow) {
        guard let code = m.code else { return }
        let down = m.down ?? true
        if Modifiers.flagKeyCodes.contains(code) {
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
        for chunk in utf16Chunks(s) {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
        }
    }


    private func resize(id: UInt32, live: LiveWindow, w: Double?, h: Double?) {
        guard var size = resizeTarget(w: w, h: h), let ax = axWindow(id: id, pid: live.pid) else { return }
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, value)
    }
}
