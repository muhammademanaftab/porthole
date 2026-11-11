import ApplicationServices
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AXWindows {
    static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    static func windowID(_ element: AXUIElement) -> UInt32? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }

    static func window(id: UInt32, pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { windowID($0) == id }
    }

    static let attachedRoles: Set<String> = ["AXSheet", "AXPopover", "AXDrawer"]

    static func attachedWindowIDs(parent: UInt32, pid: pid_t) -> Set<UInt32> {
        guard let w = window(id: parent, pid: pid) else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        var out = Set<UInt32>()
        for c in children {
            guard let role = string(c, kAXRoleAttribute), attachedRoles.contains(role), let id = windowID(c), id != parent else { continue }
            out.insert(id)
        }
        return out
    }

    static func isFullscreen(_ w: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    @discardableResult
    static func setFullscreen(_ w: AXUIElement, _ on: Bool) -> Bool {
        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    static func isDialog(id: UInt32, pid: pid_t) -> Bool {
        guard let w = window(id: id, pid: pid) else { return false }
        if boolValue(w, kAXModalAttribute as String) == true { return true }
        return ["AXDialog", "AXSystemDialog"].contains(string(w, kAXSubroleAttribute as String) ?? "")
    }

    static func boolValue(_ e: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func focusedElementPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(v as! AXUIElement, &pid) == .success ? pid : nil
    }

    static func focusedWindowID(pid: pid_t) -> UInt32? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return windowID(v as! AXUIElement)
    }

    static func position(_ w: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ w: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult
    static func setPosition(_ w: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ w: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) == .success
    }
}
