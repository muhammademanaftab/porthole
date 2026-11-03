import AppKit
import CoreGraphics

public extension Modifiers {
    static let flagKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(_ f: NSEvent.ModifierFlags) {
        self.init()
        if f.contains(.shift) { insert(.shift) }
        if f.contains(.control) { insert(.control) }
        if f.contains(.option) { insert(.option) }
        if f.contains(.command) { insert(.command) }
    }

    var cgEventFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    static func forKeyCode(_ code: UInt16) -> Modifiers? {
        switch code {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 55, 54: return .command
        default: return nil
        }
    }
}

public enum MouseMapping {
    public static func button(_ btn: Int) -> CGMouseButton {
        btn == 1 ? .right : (btn == 2 ? .center : .left)
    }

    public static func eventType(_ kind: Message.MouseKind, button btn: Int) -> CGEventType {
        switch kind {
        case .down: return btn == 1 ? .rightMouseDown : (btn == 2 ? .otherMouseDown : .leftMouseDown)
        case .up: return btn == 1 ? .rightMouseUp : (btn == 2 ? .otherMouseUp : .leftMouseUp)
        case .drag: return btn == 1 ? .rightMouseDragged : (btn == 2 ? .otherMouseDragged : .leftMouseDragged)
        case .move: return .mouseMoved
        }
    }

    public static func clickState(_ clicks: Int?) -> Int64? {
        guard let clicks, clicks > 1 else { return nil }
        return Int64(clicks)
    }

    public static func wheelDeltas(dx: Double?, dy: Double?) -> (Int32, Int32) {
        (Int32((dy ?? 0).rounded()), Int32((dx ?? 0).rounded()))
    }
}

public func utf16Chunks(_ s: String, size: Int = 20) -> [[UInt16]] {
    let units = Array(s.utf16)
    var out: [[UInt16]] = []
    var i = 0
    while i < units.count {
        out.append(Array(units[i..<min(i + size, units.count)]))
        i += size
    }
    return out
}

public func resizeTarget(w: Double?, h: Double?) -> CGSize? {
    guard let w, let h, w >= 100, h >= 80 else { return nil }
    return CGSize(width: w, height: h)
}
