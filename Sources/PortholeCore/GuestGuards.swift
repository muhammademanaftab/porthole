import CoreGraphics
import Foundation

public struct TrackPlanSender: Equatable, Sendable {
    enum Known: Equatable, Sendable {
        case serverDefault
        case sent(TrackGrantPlan)
        case unknown
    }

    private var known: Known = .serverDefault

    public init() {}

    public func shouldSend(_ plan: TrackGrantPlan) -> Bool {
        switch known {
        case .serverDefault: return !(plan.allParticipantsAllowed && plan.grants.isEmpty)
        case .sent(let last): return last != plan
        case .unknown: return true
        }
    }

    public mutating func sending(_ plan: TrackGrantPlan) { known = .sent(plan) }

    public mutating func failed() { known = .unknown }

    public var mustRetry: Bool { known == .unknown }
}

public struct GuestRoomGate: Equatable, Sendable {
    public static let margin: TimeInterval = WebRoutes.viewerTokenTTL + 60
    public private(set) var closedUntil: Date?

    public init(closedUntil: Date? = nil) { self.closedUntil = closedUntil }

    public static func restored(fileChanged: Date?) -> GuestRoomGate {
        GuestRoomGate(closedUntil: fileChanged.map { $0.addingTimeInterval(margin) })
    }

    public mutating func closed(live: [ShareLink], now: Date) -> Bool {
        if !live.isEmpty {
            let end = max(now, live.map(\.expires).max() ?? now).addingTimeInterval(Self.margin)
            closedUntil = max(closedUntil ?? end, end)
            return true
        }
        guard let until = closedUntil else { return false }
        return now < until
    }

    public mutating func linkEnded(now: Date) {
        let end = now.addingTimeInterval(Self.margin)
        closedUntil = max(closedUntil ?? end, end)
    }

    public static func nextExpiry(_ live: [ShareLink], now: Date) -> TimeInterval? {
        live.map { $0.expires.timeIntervalSince(now) }.filter { $0 > 0 }.min()
    }
}

public struct AskThrottle: Equatable, Sendable {
    public static let cooldown: TimeInterval = 30
    private var open: Set<String> = []
    private var closedAt: [String: Date] = [:]

    public init() {}

    public mutating func mayShowPanel(link: String, now: Date) -> Bool {
        guard !open.contains(link) else { return false }
        if let at = closedAt[link], now.timeIntervalSince(at) < Self.cooldown { return false }
        open.insert(link)
        return true
    }

    public mutating func panelClosed(link: String, now: Date) {
        guard open.remove(link) != nil else { return }
        closedAt[link] = now
    }

    public func isOpen(_ link: String) -> Bool { open.contains(link) }
}

public extension PortholeEventTag {
    static func isInjected(_ userData: Int64) -> Bool { userData == value }

    static func isInjected(_ event: CGEvent?) -> Bool {
        event.map { isInjected($0.getIntegerValueField(.eventSourceUserData)) } ?? false
    }

    static func source() -> CGEventSource? {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.userData = value
        return s
    }
}

public enum InjectedText {
    public static let returnKey: CGKeyCode = 36

    public static func events(_ pieces: [TextPiece], source: CGEventSource?) -> [CGEvent] {
        var out: [CGEvent] = []
        for piece in pieces {
            for down in [true, false] {
                switch piece {
                case .newline:
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: down) else { continue }
                    e.flags = []
                    out.append(e)
                case .text(let chunk):
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    e.flags = []
                    out.append(e)
                }
            }
        }
        return out
    }
}

public func guardedPanelRect(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
}
