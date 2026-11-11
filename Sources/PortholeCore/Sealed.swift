import CryptoKit
import Foundation

func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func hexData(_ s: String) -> Data? {
    let chars = Array(s.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out = Data(capacity: chars.count / 2)
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        default: return nil
        }
    }
    for i in stride(from: 0, to: chars.count, by: 2) {
        guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
        out.append(hi << 4 | lo)
    }
    return out
}

public enum Sealed {
    public static func seal(_ body: Data, key: SymmetricKey) -> String? {
        (try? ChaChaPoly.seal(body, using: key))?.combined.base64EncodedString()
    }

    public static func open(_ text: String?, key: SymmetricKey) -> Data? {
        guard let text, let data = Data(base64Encoded: text), let box = try? ChaChaPoly.SealedBox(combined: data) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    public static func sealJSON(_ object: [String: Any], key: SymmetricKey) -> String? {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { seal($0, key: key) }
    }

    public static func openJSON(_ text: String?, key: SymmetricKey) -> [String: Any]? {
        open(text, key: key).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}

public enum TokenProof {
    public static func message(device: String, nonce: String, name: String) -> Data {
        Data("porthole-token-v2|\(device)|\(nonce)|\(name)".utf8)
    }

    public static func mac(key: Data, device: String, nonce: String, name: String) -> String {
        hexString(Data(HMAC<SHA256>.authenticationCode(for: message(device: device, nonce: nonce, name: name), using: SymmetricKey(data: key))))
    }

    public static func sealKey(key: Data, device: String, nonce: String) -> SymmetricKey {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("porthole-token-seal-v2|\(device)|\(nonce)".utf8), using: SymmetricKey(data: key))
        return SymmetricKey(data: Data(mac))
    }

    public static func verify(query: [String: String], secretHash: (String) -> String?) -> (device: String, sealKey: SymmetricKey)? {
        guard let device = query["device"], DeviceIdentity.isValidID(device), let nonce = query["nonce"], HelloProof.isValidNonce(nonce),
              let given = query["mac"], let key = secretHash(device).flatMap(HelloProof.deviceKey) else { return nil }
        guard constantTimeEqual(given.lowercased(), mac(key: key, device: device, nonce: nonce, name: query["name"] ?? "")) else { return nil }
        return (device, sealKey(key: key, device: device, nonce: nonce))
    }

    public static func query(credential: ViewerCredential, name: String, nonce: String) -> [(String, String)]? {
        guard case .device(let id, _) = credential, let key = HelloProof.viewerKey(credential) else { return nil }
        return [("device", id), ("name", name), ("nonce", nonce), ("mac", mac(key: key, device: id, nonce: nonce, name: name))]
    }

    public static func openKey(credential: ViewerCredential, nonce: String) -> SymmetricKey? {
        guard case .device(let id, _) = credential, let key = HelloProof.viewerKey(credential) else { return nil }
        return sealKey(key: key, device: id, nonce: nonce)
    }
}

public enum PairExchange {
    public struct Half {
        let scalar: P256.KeyAgreement.PrivateKey
        public let share: String
    }

    static func generator(code: String, device: String) -> P256.KeyAgreement.PublicKey? {
        for counter in 0..<64 {
            let x = Data(SHA256.hash(data: Data("porthole-pair-v2|\(normalizePairingCode(code))|\(device)|\(counter)".utf8)))
            if let point = try? P256.KeyAgreement.PublicKey(compressedRepresentation: Data([2]) + x) { return point }
        }
        return nil
    }

    static func point(_ share: String) -> P256.KeyAgreement.PublicKey? {
        guard share.utf8.count == 64, let x = hexData(share) else { return nil }
        return try? P256.KeyAgreement.PublicKey(compressedRepresentation: Data([2]) + x)
    }

    public static func begin(code: String, device: String) -> Half? {
        guard let g = generator(code: code, device: device) else { return nil }
        let scalar = P256.KeyAgreement.PrivateKey()
        guard let x = try? scalar.sharedSecretFromKeyAgreement(with: g) else { return nil }
        return Half(scalar: scalar, share: hexString(x.withUnsafeBytes { Data($0) }))
    }

    public static func key(_ half: Half, peer: String, device: String, viewerShare: String, hostShare: String) -> SymmetricKey? {
        guard let p = point(peer), let secret = try? half.scalar.sharedSecretFromKeyAgreement(with: p) else { return nil }
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
                                              sharedInfo: Data("porthole-pair-v2|\(device)|\(viewerShare)|\(hostShare)".utf8), outputByteCount: 32)
    }

    public static func viewerTag(key: SymmetricKey, device: String) -> String {
        hexString(Data(HMAC<SHA256>.authenticationCode(for: Data("porthole-pair-v2|viewer|\(device)".utf8), using: key)))
    }

    public static func tagMatches(_ given: String, key: SymmetricKey, device: String) -> Bool {
        constantTimeEqual(given.lowercased(), viewerTag(key: key, device: device))
    }
}
