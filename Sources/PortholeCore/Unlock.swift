import CoreGraphics
import Foundation

public enum UnlockRefusal: Equatable, Sendable {
    case notOwner
    case notLocked
    case noPassword
    case untypeable
    case noPermission
    case busy
    case tooSoon(seconds: Int)
    case pausedAfterFailures(seconds: Int)

    public var reason: String {
        switch self {
        case .notOwner: return "not an owner"
        case .notLocked: return "the screen is not locked"
        case .noPassword: return "no password"
        case .untypeable: return "the password has characters that can't be typed"
        case .noPermission: return "no Accessibility permission"
        case .busy: return "another attempt is still running"
        case .tooSoon(let s): return "too soon, \(s) s after the last attempt"
        case .pausedAfterFailures(let s): return "paused for \(s) s after \(UnlockLimiter.maxFailures) failed attempts"
        }
    }

    public var message: String {
        switch self {
        case .notOwner: return "Only the Mac's owner can unlock it from here."
        case .notLocked: return "This Mac's screen isn't locked."
        case .noPassword: return "Type the Mac's login password first."
        case .untypeable: return "That password has characters Porthole can't type into the lock screen."
        case .noPermission: return "Porthole Host needs Accessibility permission on the Mac to type into the lock screen."
        case .busy: return "Porthole is already typing a password into the lock screen. Wait for the result."
        case .tooSoon(let s): return "Wait \(s) s before trying again."
        case .pausedAfterFailures(let s): return "Too many wrong passwords. Try again in \(UnlockLimiter.minutesLabel(s))."
        }
    }
}

public enum UnlockOutcome: Equatable, Sendable {
    case unlocked
    case unlockedWhileTyping
    case stillLocked(triesLeft: Int)
    case refused(UnlockRefusal)

    public var isUnlocked: Bool { self == .unlocked || self == .unlockedWhileTyping }

    public var logLine: String {
        switch self {
        case .unlocked: return "unlock: the screen is unlocked"
        case .unlockedWhileTyping: return "unlock: the screen unlocked while Porthole was typing; stopped typing and not counted as a failure"
        case .stillLocked(let left): return "unlock: the screen is still locked (\(left) attempt(s) left before a pause)"
        case .refused(let r): return "unlock: refused (\(r.reason))"
        }
    }

    public var message: String {
        switch self {
        case .unlocked: return "This Mac is unlocked."
        case .unlockedWhileTyping: return "The Mac unlocked while Porthole was typing, so Porthole stopped typing."
        case .stillLocked(let left):
            let pause = UnlockLimiter.minutesLabel(Int(UnlockLimiter.pause))
            let rest = left > 0 ? "\(left) more \(left == 1 ? "try" : "tries") before Porthole pauses unlocking for \(pause)."
                : "Porthole pauses unlocking for \(pause)."
            return "The screen is still locked. The password may be wrong. \(rest)"
        case .refused(let r): return r.message
        }
    }

    public func reply() -> Message {
        var m = Message(.unlock)
        m.on = isUnlocked
        m.msg = message
        return m
    }
}

public struct UnlockLimiter: Equatable, Sendable {
    public static let minGap: TimeInterval = 5
    public static let failureWindow: TimeInterval = 600
    public static let maxFailures = 3
    public static let pause: TimeInterval = 600

    private var lastAttempt: Date?
    private var failures: [Date] = []
    private var pausedUntil: Date?
    public private(set) var running = false

    public init() {}

    public static func minutesLabel(_ seconds: Int) -> String {
        let m = max(1, Int((Double(seconds) / 60).rounded(.up)))
        return "\(m) minute\(m == 1 ? "" : "s")"
    }

    public func refusal(now: Date) -> UnlockRefusal? {
        if running { return .busy }
        if let until = pausedUntil, now < until { return .pausedAfterFailures(seconds: Int(until.timeIntervalSince(now).rounded(.up))) }
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.minGap {
            return .tooSoon(seconds: max(1, Int((Self.minGap - now.timeIntervalSince(last)).rounded(.up))))
        }
        return nil
    }

    public mutating func begin(now: Date) -> UnlockRefusal? {
        if let r = refusal(now: now) { return r }
        lastAttempt = now
        running = true
        return nil
    }

    public mutating func finished(unlocked: Bool, now: Date) -> Int {
        running = false
        failures = failures.filter { now.timeIntervalSince($0) < Self.failureWindow }
        if unlocked { failures.removeAll(); return Self.maxFailures }
        failures.append(now)
        if failures.count >= Self.maxFailures {
            pausedUntil = now.addingTimeInterval(Self.pause)
            failures.removeAll()
            return 0
        }
        return Self.maxFailures - failures.count
    }

    public mutating func abandoned() {
        running = false
    }
}

public enum UnlockPolicy {
    public static let maxLength = 256

    public static func isOwner(_ identity: String) -> Bool {
        !GuestIdentity.isGuest(identity) && WholeMac.viewer(identity) != .other
    }

    public static func typeable(_ password: String) -> Bool {
        !password.isEmpty && password.utf16.count <= maxLength
            && !password.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    public static func dropsInput(_ kind: Message.Kind, running: Bool) -> Bool {
        running && [.key, .text, .mouse, .scroll].contains(kind)
    }

    public static func check(identity: String, password: String?, screenLocked: Bool, mayPost: Bool,
                             limiter: inout UnlockLimiter, now: Date) -> UnlockRefusal? {
        guard isOwner(identity) else { return .notOwner }
        guard let password, !password.isEmpty else { return .noPassword }
        guard typeable(password) else { return .untypeable }
        if let r = limiter.refusal(now: now) { return r }
        guard screenLocked else { return .notLocked }
        guard mayPost else { return .noPermission }
        return limiter.begin(now: now)
    }
}

public enum LockScreenTyping {
    public static let returnKey: CGKeyCode = 36

    public static func pieces(_ password: String) -> [[UInt16]] {
        password.map { Array(String($0).utf16) }
    }

    public static func releases(source: CGEventSource?) -> [CGEvent] {
        Modifiers.flagKeyCodes.sorted().compactMap { code in
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
            e.type = .flagsChanged
            e.flags = []
            return e
        }
    }

    public static func sequence(_ password: String, source: CGEventSource?) -> [CGEvent] {
        releases(source: source) + events(password, source: source)
    }

    public static func post(_ events: [CGEvent], stillLocked: () -> Bool, post: (CGEvent) -> Void,
                            pause: () async -> Void) async -> Bool {
        for e in events {
            guard stillLocked() else { return false }
            post(e)
            await pause()
        }
        return true
    }

    public static func events(_ password: String, source: CGEventSource?) -> [CGEvent] {
        var out: [CGEvent] = []
        for chunk in pieces(password) {
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.flags = []
                out.append(e)
            }
        }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: down) else { continue }
            e.flags = []
            out.append(e)
        }
        return out
    }
}

public struct LockScreenUnlock {
    public static let wakeDelay: Double = 1.5
    public static let pollEvery: Double = 0.5
    public static let pollFor: Double = 15

    public enum Result: Equatable, Sendable { case unlocked, stillLocked, unlockedBeforeTyping, unlockedWhileTyping }

    public var isLocked: () async -> Bool
    public var wake: () async -> Void
    public var type: (String) async -> Bool
    public var sleep: (Double) async -> Void
    public var typed: () -> Void

    public init(isLocked: @escaping () async -> Bool, wake: @escaping () async -> Void, type: @escaping (String) async -> Bool,
                sleep: @escaping (Double) async -> Void, typed: @escaping () -> Void = {}) {
        self.isLocked = isLocked; self.wake = wake; self.type = type; self.sleep = sleep; self.typed = typed
    }

    public func run(_ password: String) async -> Result {
        await wake()
        await sleep(Self.wakeDelay)
        guard await isLocked() else { return .unlockedBeforeTyping }
        guard await type(password) else { return .unlockedWhileTyping }
        typed()
        var waited = 0.0
        while waited < Self.pollFor {
            await sleep(Self.pollEvery)
            waited += Self.pollEvery
            if !(await isLocked()) { return .unlocked }
        }
        return .stillLocked
    }
}

public enum UnlockEnv {
    public static let name = "PORTHOLE_OPEN_UNLOCK"
    public static let maxDelay = 600
    public static let relistTries = 3
    public static let relistEvery: Double = 1

    public struct Request: Equatable, Sendable {
        public var delay: Int
        public var password: String

        public init(delay: Int, password: String) { self.delay = delay; self.password = password }
    }

    public static func cliTimeout(_ request: Request?) -> TimeInterval {
        guard let request else { return 25 }
        return 25 + Double(request.delay) + LockScreenUnlock.wakeDelay + LockScreenUnlock.pollFor
            + Double(relistTries) * relistEvery + 10
    }

    public static func scrubbed(_ environment: [String: String]) -> [String: String] {
        environment.filter { $0.key != name }
    }

    public static func shouldRelist(listEmpty: Bool, triesLeft: Int) -> Bool {
        listEmpty && triesLeft > 0
    }

    public static func shouldAsk(lockedSeen: Bool, listEmpty: Bool, tried: Bool) -> Bool {
        lockedSeen && listEmpty && !tried
    }

    public static func parse(_ value: String?) -> Request? {
        guard let value, let colon = value.firstIndex(of: ":") else { return nil }
        guard let secs = Int(value[..<colon]), (0...maxDelay).contains(secs) else { return nil }
        let pw = String(value[value.index(after: colon)...])
        guard UnlockPolicy.typeable(pw) else { return nil }
        return Request(delay: secs, password: pw)
    }
}

public enum UnlockPrompt {
    public static func title(host: String) -> String { "Unlock \(host)" }

    public static func message(host: String) -> String {
        "Type \(host)'s login password. Porthole types it into the lock screen and doesn't keep it."
    }

    public static let working = "Typing the password into the lock screen…"

    public static let answerTimeout: TimeInterval = 25

    public static let noAnswer = "The host didn't answer. It may run a Porthole Host that can't unlock its screen yet."

    public static func isBusyReply(_ m: Message) -> Bool {
        m.t == .unlock && m.on != true && m.msg == UnlockRefusal.busy.message
    }

    public static func isLockNotice(_ msg: String?) -> Bool {
        msg == LockNotice.list || msg == LockNotice.control
    }
}

public enum LockState {
    public static func isLocked(session: [String: Any]?) -> Bool {
        guard let session else { return false }
        func flag(_ key: String) -> Bool { (session[key] as? Bool) ?? ((session[key] as? NSNumber)?.boolValue ?? false) }
        return flag("CGSSessionScreenIsLocked") && flag("kCGSSessionOnConsoleKey")
    }
}
