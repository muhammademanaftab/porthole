import CoreGraphics

public struct TitleBarReveal: Equatable, Sendable {
    public static let edge: CGFloat = 8
    public static let keep: CGFloat = 44
    public static let hideDelay: Double = 0.6
    public static let pollSeconds: Double = 0.08

    public private(set) var shown = false
    private var leftAt: Double?

    public init() {}

    public static let envKey = "PORTHOLE_AUTO_HIDE_BAR"

    public static func autoHide(global: Bool, override: Bool?) -> Bool { override ?? global }

    public static func global(saved: Bool, environment: [String: String]) -> Bool {
        switch environment[envKey] {
        case "1": return true
        case "0": return false
        default: return saved
        }
    }

    public static func distanceFromTop(pointer p: CGPoint, frame: CGRect) -> CGFloat? {
        guard p.x >= frame.minX, p.x <= frame.maxX, p.y >= frame.minY, p.y <= frame.maxY + 1 else { return nil }
        return max(0, frame.maxY - p.y)
    }

    @discardableResult
    public mutating func pointer(distanceFromTop d: CGFloat?, now: Double) -> Bool {
        if let d, d <= Self.edge {
            shown = true
            leftAt = nil
        } else if shown, let d, d <= Self.keep {
            leftAt = nil
        } else if shown {
            if leftAt == nil { leftAt = now }
            if let t = leftAt, now - t >= Self.hideDelay { shown = false; leftAt = nil }
        }
        return shown
    }

    public mutating func hide() {
        shown = false
        leftAt = nil
    }
}
