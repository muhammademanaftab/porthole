import CryptoKit
import Foundation

public func isIPLiteral(_ host: String) -> Bool {
    let h = bareHost(host)
    return parseDottedQuad(h) != nil || parseIPv6(h) != nil
}

public enum HelloProof {
    public static let nonceBytes = 16

    public static func makeNonce(random: () -> UInt8 = { UInt8.random(in: 0...255) }) -> String {
        (0..<nonceBytes).map { _ in String(format: "%02x", random()) }.joined()
    }

    public static func isValidNonce(_ s: String) -> Bool {
        s.utf8.count == nonceBytes * 2 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func viewerKey(_ credential: ViewerCredential) -> Data? {
        guard case .device(_, let secret) = credential, !secret.isEmpty else { return nil }
        return Data(secretDigest(secret).utf8)
    }

    public static func deviceKey(secretHash: String) -> Data? {
        secretHash.isEmpty ? nil : Data(secretHash.utf8)
    }

    public static func message(nonce: String, hostID: String, address: String) -> Data {
        Data("porthole-hello-v1|\(nonce)|\(hostID)|\(bareHost(address))".utf8)
    }

    static let decoyKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

    public static func proof(key: Data, nonce: String, hostID: String, address: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message(nonce: nonce, hostID: hostID, address: address), using: SymmetricKey(data: key))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ proof: String?, key: Data?, nonce: String, hostID: String?, address: String) -> Bool {
        guard let proof, let key, let hostID, DeviceIdentity.isValidID(hostID), isValidNonce(nonce), isIPLiteral(address) else { return false }
        return constantTimeEqual(proof.lowercased(), self.proof(key: key, nonce: nonce, hostID: hostID, address: address))
    }

    public static func url(hostAddress: String, credential: ViewerCredential, nonce: String) -> URL? {
        guard case .device(let id, _) = credential else { return nil }
        return hostURL(hostAddress, path: "/hello", ["device": id, "nonce": nonce])
    }

    public enum Answer: Equatable, Sendable {
        case confirmed(HostHello)
        case unconfirmed(HostHello?)
    }

    public static func check(status: Int?, body: Data?, credential: ViewerCredential, nonce: String, expectedID: String?, address: String) -> Answer {
        guard status == 200, let body, let hello = HostHello.parse(body) else { return .unconfirmed(nil) }
        if let expectedID, hello.id != expectedID { return .unconfirmed(hello) }
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let ok = verify(obj?["proof"] as? String, key: viewerKey(credential), nonce: nonce, hostID: hello.id, address: address)
        return ok ? .confirmed(hello) : .unconfirmed(hello)
    }

    public static func namesOtherHost(_ answer: Answer, expectedID: String?) -> Bool {
        guard case .unconfirmed(let hello) = answer, let expectedID, let id = hello?.id else { return false }
        return id != expectedID
    }

    public static func answer(query: [String: String], hostHeader: String, hostID: String?,
                              secretHash: (String) -> String?, ownsAddress: (String) -> Bool) -> String? {
        guard let nonce = query["nonce"], isValidNonce(nonce), let device = query["device"], !device.isEmpty,
              let hostID, DeviceIdentity.isValidID(hostID) else { return nil }
        let address = bareHost(WebRoutes.hostname(from: hostHeader))
        guard isIPLiteral(address), ownsAddress(address), DeviceIdentity.isValidID(device),
              let key = secretHash(device).flatMap(deviceKey) else {
            return proof(key: decoyKey, nonce: nonce, hostID: device, address: address)
        }
        return proof(key: key, nonce: nonce, hostID: hostID, address: address)
    }
}

public final class PasswordThrottle: @unchecked Sendable {
    public static let maxSources = 1024
    private let lock = NSLock()
    private var budgets: [String: (budget: GuessBudget, touched: Date)] = [:]
    private let clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    public func secondsPaused(_ source: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return budgets[source]?.budget.secondsPaused(now: clock())
    }

    public func failed(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        var b = budgets[source]?.budget ?? GuessBudget()
        b.wrongGuess(now: now)
        budgets[source] = (b, now)
        if budgets.count > Self.maxSources {
            let idle = budgets.filter { $0.value.budget.secondsPaused(now: now) == nil }.sorted { $0.value.touched < $1.value.touched }
            for (key, _) in idle.prefix(budgets.count - Self.maxSources) { budgets[key] = nil }
        }
    }

    public func succeeded(_ source: String) {
        lock.lock(); defer { lock.unlock() }
        budgets[source] = nil
    }
}
