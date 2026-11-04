import CryptoKit
import Foundation

public enum HelloProof {
    public static let nonceBytes = 16

    public static func makeNonce(random: () -> UInt8 = { UInt8.random(in: 0...255) }) -> String {
        (0..<nonceBytes).map { _ in String(format: "%02x", random()) }.joined()
    }

    public static func isValidNonce(_ s: String) -> Bool {
        s.utf8.count == nonceBytes * 2 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func viewerKey(_ credential: ViewerCredential) -> Data? {
        switch credential {
        case .password(let pw): return pw.isEmpty ? nil : Data(pw.utf8)
        case .device(_, let secret): return secret.isEmpty ? nil : Data(secretDigest(secret).utf8)
        }
    }

    public static func deviceKey(secretHash: String) -> Data? {
        secretHash.isEmpty ? nil : Data(secretHash.utf8)
    }

    public static func message(nonce: String, hostID: String, address: String) -> Data {
        Data("porthole-hello-v1|\(nonce)|\(hostID)|\(bareHost(address))".utf8)
    }

    public static func proof(key: Data, nonce: String, hostID: String, address: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: message(nonce: nonce, hostID: hostID, address: address), using: SymmetricKey(data: key))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ proof: String?, key: Data?, nonce: String, hostID: String?, address: String) -> Bool {
        guard let proof, let key, let hostID, DeviceIdentity.isValidID(hostID), isValidNonce(nonce) else { return false }
        return constantTimeEqual(proof.lowercased(), self.proof(key: key, nonce: nonce, hostID: hostID, address: address))
    }

    public static func query(_ credential: ViewerCredential, nonce: String) -> KeyValuePairs<String, String> {
        switch credential {
        case .password: return ["pw": "0", "nonce": nonce]
        case .device(let id, _): return ["device": id, "nonce": nonce]
        }
    }

    public static func url(hostAddress: String, credential: ViewerCredential, nonce: String) -> URL? {
        hostURL(hostAddress, path: "/hello", query(credential, nonce: nonce))
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

    public static func hostKey(query: [String: String], password: String, secretHash: (String) -> String?) -> Data? {
        if let device = query["device"], !device.isEmpty {
            guard DeviceIdentity.isValidID(device) else { return nil }
            return secretHash(device).flatMap(deviceKey)
        }
        guard query["pw"] == "0", !password.isEmpty else { return nil }
        return Data(password.utf8)
    }

    public static func answer(query: [String: String], hostHeader: String, hostID: String?, password: String,
                              secretHash: (String) -> String?, ownsAddress: (String) -> Bool) -> String? {
        guard let nonce = query["nonce"], isValidNonce(nonce), let hostID, DeviceIdentity.isValidID(hostID) else { return nil }
        let address = WebRoutes.hostname(from: hostHeader)
        guard ownsAddress(bareHost(address)), let key = hostKey(query: query, password: password, secretHash: secretHash) else {
            return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        return proof(key: key, nonce: nonce, hostID: hostID, address: address)
    }
}
