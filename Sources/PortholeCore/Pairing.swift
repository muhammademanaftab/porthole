import Foundation

public struct PairingCodes: Sendable {
    public enum Outcome: Equatable, Sendable { case accepted, wrong(left: Int), locked, expired, noCode }
    public enum State: Equatable, Sendable { case idle, active(code: String, secondsLeft: Int), used, expired, locked }

    public static let lifetime: TimeInterval = 120
    public static let maxWrongTries = 5

    private var code: String?
    private var expires = Date.distantPast
    private var wrong = 0
    private var ended: State = .idle

    public init() {}

    public mutating func issue(now: Date, random: () -> UInt32 = { UInt32.random(in: 0..<1_000_000) }) -> String {
        let c = String(format: "%06u", random() % 1_000_000)
        code = c
        expires = now.addingTimeInterval(Self.lifetime)
        wrong = 0
        ended = .idle
        return c
    }

    public mutating func cancel() {
        code = nil
        ended = .idle
    }

    public mutating func state(now: Date) -> State {
        expireIfDue(now)
        guard let code else { return ended }
        return .active(code: code, secondsLeft: Int(expires.timeIntervalSince(now).rounded(.up)))
    }

    public mutating func redeem(_ input: String, now: Date) -> Outcome {
        expireIfDue(now)
        guard let code else {
            switch ended {
            case .expired: return .expired
            case .locked: return .locked
            default: return .noCode
            }
        }
        if Self.sameDigits(normalizePairingCode(input), code) {
            self.code = nil
            ended = .used
            return .accepted
        }
        wrong += 1
        guard wrong < Self.maxWrongTries else {
            self.code = nil
            ended = .locked
            return .locked
        }
        return .wrong(left: Self.maxWrongTries - wrong)
    }

    private mutating func expireIfDue(_ now: Date) {
        guard code != nil, now >= expires else { return }
        code = nil
        ended = .expired
    }

    private static func sameDigits(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public func normalizePairingCode(_ s: String) -> String {
    String(s.filter { $0.isASCII && $0.isNumber })
}

public func looksLikePairingCode(_ s: String) -> Bool {
    let allowed = s.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" }
    return allowed && normalizePairingCode(s).count == 6
}

public func displayPairingCode(_ code: String) -> String {
    guard code.count == 6 else { return code }
    return "\(code.prefix(3)) \(code.suffix(3))"
}

public final class PairingDesk: @unchecked Sendable {
    private var codes = PairingCodes()
    private let lock = NSLock()
    private let clock: () -> Date
    private let random: () -> UInt32

    public init(clock: @escaping () -> Date = Date.init,
                random: @escaping () -> UInt32 = { UInt32.random(in: 0..<1_000_000) }) {
        self.clock = clock
        self.random = random
    }

    public func issue() -> String {
        lock.lock(); defer { lock.unlock() }
        return codes.issue(now: clock(), random: random)
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        codes.cancel()
    }

    public func state() -> PairingCodes.State {
        lock.lock(); defer { lock.unlock() }
        return codes.state(now: clock())
    }

    public func redeem(_ code: String) -> PairingCodes.Outcome {
        lock.lock(); defer { lock.unlock() }
        return codes.redeem(code, now: clock())
    }
}

public func pairURL(hostAddress: String, code: String) -> URL? {
    guard let (host, port) = splitHostAddress(hostAddress) else { return nil }
    var comps = URLComponents()
    comps.scheme = "http"
    comps.host = host
    comps.port = port
    comps.path = "/pair"
    comps.queryItems = [URLQueryItem(name: "code", value: normalizePairingCode(code))]
    return comps.url
}

public enum PairReply: Equatable, Sendable {
    case password(String)
    case refused(String)
}

public func parsePairReply(status: Int, body: Data) -> PairReply {
    let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    if status == 200, let pw = obj?["password"] as? String, !pw.isEmpty { return .password(pw) }
    if let msg = obj?["error"] as? String, !msg.isEmpty { return .refused(msg) }
    if status == 404 { return .refused("This host is an older Porthole without pairing codes. Use its password instead.") }
    return .refused("The host didn't accept the code (HTTP \(status)).")
}

public func pairMessage(_ outcome: PairingCodes.Outcome) -> String? {
    switch outcome {
    case .accepted: return nil
    case .wrong(let left): return "Wrong code. \(left) \(left == 1 ? "try" : "tries") left."
    case .locked: return "Too many wrong tries. Ask for a new code on the host."
    case .expired: return "That code has expired. Ask for a new code on the host."
    case .noCode: return "No pairing code is active. On the host, choose Pair a New Viewer… from the menu-bar icon."
    }
}
