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
        (wheelValue(dy), wheelValue(dx))
    }

    public static func wheelValue(_ v: Double?) -> Int32 {
        guard let v, !v.isNaN else { return 0 }
        let r = v.rounded()
        if r >= Double(Int32.max) { return .max }
        if r <= Double(Int32.min) { return .min }
        return Int32(r)
    }

    public static func isReliable(_ kind: Message.MouseKind) -> Bool { kind != .move }

    public static func carriesClicks(_ kind: Message.MouseKind) -> Bool { kind == .down || kind == .up }
}

public enum ViewerInput {
    public static let moveInterval: TimeInterval = 1.0 / 60
    public static let pixelsPerScrollLine: Double = 16

    public static func point(_ p: CGPoint, kind: Message.MouseKind?, contentPixels: CGSize, bounds: CGRect, fill: Bool = false) -> CGPoint? {
        let content = contentPixels == .zero ? bounds.size : contentPixels
        if fill {
            let r = filledRect(content: content, in: bounds)
            guard r.width > 0, r.height > 0 else { return nil }
            return CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
        }
        let clamp = kind == .up || kind == .drag
        return clamp ? clampedNormalized(p, content: content, in: bounds) : normalized(p, content: content, in: bounds)
    }

    public static func shouldSendMove(now: Date, last: Date) -> Bool {
        now.timeIntervalSince(last) > moveInterval
    }

    public static func mouseMessage(win: UInt32, kind: Message.MouseKind, button: Int, at p: CGPoint, mods: UInt32,
                                    clickCount: Int) -> (message: Message, reliable: Bool) {
        var m = Message(.mouse)
        m.win = win; m.kind = kind; m.btn = button; m.x = p.x; m.y = p.y; m.mods = mods
        if MouseMapping.carriesClicks(kind) { m.clicks = clickCount }
        return (m, MouseMapping.isReliable(kind))
    }

    public static func scrollPixels(dx: Double, dy: Double, precise: Bool) -> (dx: Double, dy: Double) {
        let k = precise ? 1 : pixelsPerScrollLine
        return (dx * k, dy * k)
    }

    public static func keyEquivalentStaysLocal(_ f: NSEvent.ModifierFlags, characters: String?) -> Bool {
        (f.contains(.command) && characters == "q") || isPasteAsKeystrokes(f, characters: characters)
    }

    public static func isPasteAsKeystrokes(_ f: NSEvent.ModifierFlags, characters: String?) -> Bool {
        f.intersection([.command, .option, .shift, .control]) == [.command, .option, .shift] && characters?.lowercased() == "v"
    }

    public static func routesThroughInputMethod(hasMarkedText: Bool, inputSourceIsInputMode: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        if hasMarkedText { return true }
        guard inputSourceIsInputMode else { return false }
        return flags.intersection([.command, .control]).isEmpty
    }

    public static let textMessageUnits = 4000

    public static func textMessages(win: UInt32, _ s: String, unitsPerMessage: Int = textMessageUnits) -> [Message] {
        var out: [Message] = []
        var run = ""
        var n = 0
        for ch in s {
            let u = ch.utf16.count
            if n > 0 && n + u > unitsPerMessage {
                out.append(textMessage(win: win, run))
                run = ""; n = 0
            }
            run.append(ch); n += u
        }
        if !run.isEmpty { out.append(textMessage(win: win, run)) }
        return out
    }

    static func textMessage(win: UInt32, _ s: String) -> Message {
        var m = Message(.text)
        m.win = win; m.s = s
        return m
    }

    static let deviceMasks: [UInt16: (mine: UInt, other: UInt)] = [
        56: (0x0002, 0x0004), 60: (0x0004, 0x0002),
        59: (0x0001, 0x2000), 62: (0x2000, 0x0001),
        58: (0x0020, 0x0040), 61: (0x0040, 0x0020),
        55: (0x0008, 0x0010), 54: (0x0010, 0x0008),
    ]

    public static func modifierIsDown(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let which = Modifiers.forKeyCode(code), let masks = deviceMasks[code] else { return nil }
        let raw = flags.rawValue
        if raw & (masks.mine | masks.other) == 0 { return Modifiers(flags).contains(which) }
        return raw & masks.mine != 0
    }
}

public enum TextPiece: Equatable, Sendable {
    case text([UInt16])
    case newline
}

public enum TextBatch {
    public static let envKey = "PORTHOLE_TEXT_BATCH"
    public static let defaultUnits = 200
    public static let maxUnits = 2000
    public static let maxMessageUnits = 20000

    public static func units(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment[envKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return defaultUnits }
        switch raw.lowercased() {
        case "0", "off", "no", "false": return 0
        case "1", "on", "yes", "true": return defaultUnits
        default:
            guard let n = Int(raw), n >= 2 else { return defaultUnits }
            return min(n, maxUnits)
        }
    }

    public static func pieces(_ s: String, maxUnits: Int) -> [TextPiece] {
        var out: [TextPiece] = []
        var run: [UInt16] = []
        func flush() {
            if !run.isEmpty { out.append(.text(run)); run = [] }
        }
        for ch in s {
            if ch.isNewline {
                flush()
                out.append(.newline)
                continue
            }
            let units = Array(String(ch).utf16)
            if maxUnits <= 0 {
                out.append(.text(units))
                continue
            }
            if !run.isEmpty && run.count + units.count > maxUnits { flush() }
            run += units
            if run.count >= maxUnits { flush() }
        }
        flush()
        return out
    }

    public static func keyPairs(_ s: String, maxUnits: Int) -> Int {
        pieces(s, maxUnits: maxUnits).count
    }

    public static func limited(_ s: String) -> String {
        guard s.utf16.count > maxMessageUnits else { return s }
        var out = ""
        var n = 0
        for ch in s {
            let u = ch.utf16.count
            if n + u > maxMessageUnits { break }
            out.append(ch)
            n += u
        }
        return out
    }
}

public func resizeTarget(w: Double?, h: Double?) -> CGSize? {
    guard let w, let h, w >= 100, h >= 80 else { return nil }
    return CGSize(width: w, height: h)
}
