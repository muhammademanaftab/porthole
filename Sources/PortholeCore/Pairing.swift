import CryptoKit
import Foundation

public struct PairRequester: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id; self.name = cleanDeviceName(name)
    }
}

public struct GuessBudget: Codable, Equatable, Sendable {
    public static let wrongPerPause = 10
    public static let firstPause: TimeInterval = 60
    public static let longestPause: TimeInterval = 86_400

    public var strikes = 0
    public var pauses = 0
    public var pausedUntil: Date?

    public init() {}

    public func secondsPaused(now: Date) -> Int? {
        guard let until = pausedUntil, now < until else { return nil }
        return Int(until.timeIntervalSince(now).rounded(.up))
    }

    public mutating func wrongGuess(now: Date) {
        strikes += 1
        guard strikes >= Self.wrongPerPause else { return }
        strikes = 0
        pauses += 1
        pausedUntil = now.addingTimeInterval(min(Self.longestPause, Self.firstPause * pow(2, Double(min(pauses - 1, 20)))))
    }

    public mutating func ownerReset() {
        strikes = 0
        pausedUntil = nil
    }

    public mutating func paired() {
        strikes = 0
        pauses = 0
        pausedUntil = nil
    }

    public static func decode(_ data: Data?) -> GuessBudget {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return data.flatMap { try? dec.decode(GuessBudget.self, from: $0) } ?? GuessBudget()
    }

    public var encoded: Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }
}

public struct PairingCodes: Sendable {
    public enum Outcome: Equatable, Sendable { case accepted, wrong(left: Int), locked, expired, noCode, paused(seconds: Int), forOther(name: String) }
    public enum State: Equatable, Sendable { case idle, active(code: String, secondsLeft: Int), used, expired, locked }

    public static let lifetime: TimeInterval = 120
    public static let maxWrongTries = 5
    public static let requestWindow: TimeInterval = 600
    public static let maxRequests = 6
    public static let maxRequestsPerDevice = 3

    public enum RequestOutcome: Equatable, Sendable { case issued(String), same(String), busy(seconds: Int), throttled, paused(seconds: Int) }

    private var code: String?
    private var expires = Date.distantPast
    private var wrong = 0
    private var ended: State = .idle
    public private(set) var requester: PairRequester?
    private var requestTimes: [Date] = []
    private var deviceRequestTimes: [String: [Date]] = [:]
    private var fromOwner = false
    public var budget = GuessBudget()

    public init(budget: GuessBudget = GuessBudget()) { self.budget = budget }

    public mutating func issue(now: Date, random: () -> UInt32 = { UInt32.random(in: 0..<1_000_000) },
                               for requester: PairRequester? = nil) -> String {
        budget.ownerReset()
        return makeCode(now: now, random: random, for: requester, fromOwner: true)
    }

    private mutating func makeCode(now: Date, random: () -> UInt32, for requester: PairRequester?, fromOwner: Bool) -> String {
        let c = String(format: "%06u", random() % 1_000_000)
        code = c
        expires = now.addingTimeInterval(Self.lifetime)
        wrong = 0
        ended = .idle
        self.requester = requester
        self.fromOwner = fromOwner
        return c
    }

    public mutating func cancel() {
        code = nil
        ended = .idle
        requester = nil
    }

    public mutating func request(from who: PairRequester, now: Date,
                                 random: () -> UInt32 = { UInt32.random(in: 0..<1_000_000) }) -> RequestOutcome {
        expireIfDue(now)
        if let code, requester?.id == who.id {
            requester = who
            return .same(code)
        }
        if code != nil { return .busy(seconds: Int(expires.timeIntervalSince(now).rounded(.up))) }
        if let paused = budget.secondsPaused(now: now) { return .paused(seconds: paused) }
        let recent = { (times: [Date]) in times.filter { now.timeIntervalSince($0) < Self.requestWindow } }
        requestTimes = recent(requestTimes)
        deviceRequestTimes = deviceRequestTimes.compactMapValues { let kept = recent($0); return kept.isEmpty ? nil : kept }
        let mine = deviceRequestTimes[who.id] ?? []
        guard mine.count < Self.maxRequestsPerDevice, requestTimes.count < Self.maxRequests else { return .throttled }
        requestTimes.append(now)
        deviceRequestTimes[who.id] = mine + [now]
        return .issued(makeCode(now: now, random: random, for: who, fromOwner: false))
    }

    public mutating func currentOrIssue(now: Date, random: () -> UInt32 = { UInt32.random(in: 0..<1_000_000) }) -> String {
        expireIfDue(now)
        budget.ownerReset()
        if let code { fromOwner = true; return code }
        return issue(now: now, random: random)
    }

    public mutating func state(now: Date) -> State {
        expireIfDue(now)
        guard let code else { return ended }
        return .active(code: code, secondsLeft: Int(expires.timeIntervalSince(now).rounded(.up)))
    }

    public mutating func offer(device: String?, now: Date) -> (code: String?, refusal: Outcome?) {
        expireIfDue(now)
        guard let code else {
            switch ended {
            case .expired: return (nil, .expired)
            case .locked: return (nil, .locked)
            default: return (nil, .noCode)
            }
        }
        if let requester, requester.id != device { return (nil, .forOther(name: requester.name)) }
        if !fromOwner, let paused = budget.secondsPaused(now: now) { return (nil, .paused(seconds: paused)) }
        return (code, nil)
    }

    public mutating func redeem(_ input: String, device: String? = nil, now: Date) -> Outcome {
        let (code, refusal) = offer(device: device, now: now)
        guard let code else { return refusal ?? .noCode }
        return settle(matched: constantTimeEqual(normalizePairingCode(input), code), now: now)
    }

    public mutating func settle(matched: Bool, now: Date) -> Outcome {
        guard code != nil else { return .noCode }
        if matched {
            self.code = nil
            ended = .used
            budget.paired()
            return .accepted
        }
        budget.wrongGuess(now: now)
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
    private var codes: PairingCodes
    private let lock = NSLock()
    private let clock: () -> Date
    private let random: () -> UInt32
    private let budgetFile: URL?

    public init(clock: @escaping () -> Date = Date.init,
                random: @escaping () -> UInt32 = { UInt32.random(in: 0..<1_000_000) }, budgetFile: URL? = nil) {
        self.clock = clock
        self.random = random
        self.budgetFile = budgetFile
        codes = PairingCodes(budget: GuessBudget.decode(budgetFile.flatMap { try? Data(contentsOf: $0) }))
    }

    public var budget: GuessBudget {
        lock.lock(); defer { lock.unlock() }
        return codes.budget
    }

    private func saving<T>(_ body: (inout PairingCodes) -> T) -> T {
        let before = codes.budget
        let result = body(&codes)
        if let budgetFile, codes.budget != before { _ = writePrivately(codes.budget.encoded, to: budgetFile) }
        return result
    }

    public func issue() -> String {
        lock.lock(); defer { lock.unlock() }
        return saving { $0.issue(now: clock(), random: random) }
    }

    public func reissue() -> String {
        lock.lock(); defer { lock.unlock() }
        return saving { $0.issue(now: clock(), random: random, for: $0.requester) }
    }

    public func request(from who: PairRequester) -> PairingCodes.RequestOutcome {
        lock.lock(); defer { lock.unlock() }
        return codes.request(from: who, now: clock(), random: random)
    }

    public func currentOrIssue() -> (code: String, requester: PairRequester?, secondsLeft: Int) {
        lock.lock(); defer { lock.unlock() }
        let c = saving { $0.currentOrIssue(now: clock(), random: random) }
        if case .active(_, let left) = codes.state(now: clock()) { return (c, codes.requester, left) }
        return (c, codes.requester, Int(PairingCodes.lifetime))
    }

    public var requester: PairRequester? {
        lock.lock(); defer { lock.unlock() }
        return codes.requester
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        codes.cancel()
    }

    public func state() -> PairingCodes.State {
        lock.lock(); defer { lock.unlock() }
        return codes.state(now: clock())
    }

    public func redeem(_ code: String, device: String? = nil) -> PairingCodes.Outcome {
        lock.lock(); defer { lock.unlock() }
        return saving { $0.redeem(code, device: device, now: clock()) }
    }

    public enum Start { case share(String), refused(PairingCodes.Outcome), invalid }

    public static let maxPending = 8
    private var pending: [String: (key: SymmetricKey, code: String)] = [:]

    public func start(device: String, viewerShare: String) -> Start {
        lock.lock(); defer { lock.unlock() }
        let (code, refusal) = codes.offer(device: device, now: clock())
        guard let code else { return .refused(refusal ?? .noCode) }
        guard let half = PairExchange.begin(code: code, device: device),
              let key = PairExchange.key(half, peer: viewerShare, device: device, viewerShare: viewerShare, hostShare: half.share) else { return .invalid }
        if pending.count >= Self.maxPending { pending.removeAll() }
        pending[device] = (key, code)
        return .share(half.share)
    }

    public func finish(device: String, tag: String) -> (outcome: PairingCodes.Outcome, key: SymmetricKey?) {
        lock.lock(); defer { lock.unlock() }
        guard let p = pending.removeValue(forKey: device) else { return (.noCode, nil) }
        let (code, refusal) = codes.offer(device: device, now: clock())
        guard let code else { return (refusal ?? .noCode, nil) }
        guard code == p.code else { return (.expired, nil) }
        let matched = PairExchange.tagMatches(tag, key: p.key, device: device)
        let now = clock()
        let outcome = saving { $0.settle(matched: matched, now: now) }
        if outcome != .accepted { pending.removeAll() }
        return (outcome, outcome == .accepted ? p.key : nil)
    }
}

public func pairStartURL(hostAddress: String, device: String, name: String, share: String) -> URL? {
    hostURL(hostAddress, path: "/pair/start", ["device": device, "name": name, "v": share])
}

public func pairFinishURL(hostAddress: String, device: String, name: String, tag: String) -> URL? {
    hostURL(hostAddress, path: "/pair/finish", ["device": device, "name": name, "tag": tag])
}

public func parsePairStart(status: Int, body: Data) -> (share: String?, refusal: String?) {
    let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    if status == 200, let h = obj?["h"] as? String { return (h, nil) }
    if let msg = obj?["error"] as? String, !msg.isEmpty { return (nil, msg) }
    if status == 404 { return (nil, "This host runs an older Porthole. Update it, then pair again.") }
    return (nil, "The host didn't accept the pairing (HTTP \(status)).")
}

public func parsePairFinish(status: Int, body: Data, key: SymmetricKey) -> PairReply {
    let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    if status == 200 {
        guard let inner = Sealed.openJSON(obj?["sealed"] as? String, key: key), let secret = inner["secret"] as? String, !secret.isEmpty else {
            return .refused("The answer didn't come from a Mac that knows the code. Nothing was paired.")
        }
        let id = (inner["host_id"] as? String).flatMap { DeviceIdentity.isValidID($0) ? $0 : nil }
        return .paired(secret: secret, hostID: id, hostName: inner["host"] as? String)
    }
    if let msg = obj?["error"] as? String, !msg.isEmpty { return .refused(msg) }
    return .refused("The host didn't accept the code (HTTP \(status)).")
}

public enum PairReply: Equatable, Sendable {
    case paired(secret: String, hostID: String?, hostName: String?)
    case refused(String)
}

public func pairMessage(_ outcome: PairingCodes.Outcome) -> String? {
    switch outcome {
    case .accepted: return nil
    case .wrong(let left): return "Wrong code. \(left) \(left == 1 ? "try" : "tries") left."
    case .locked: return "Too many wrong tries. Ask for a new code on the host."
    case .expired: return "That code has expired. Ask for a new code on the host."
    case .noCode: return "No pairing code is active. On the host, choose Pair a New Viewer… from the menu-bar icon."
    case .paused(let seconds):
        let minutes = (seconds + 59) / 60
        return "Too many wrong codes on this host. Pairing is paused for \(minutes) \(minutes == 1 ? "minute" : "minutes")."
    case .forOther(let name):
        return "The code on the host is for \(name). Wait for it to finish, or ask for a new code on the host."
    }
}
