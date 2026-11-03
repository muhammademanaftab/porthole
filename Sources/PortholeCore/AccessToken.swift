import CryptoKit
import Foundation

public struct AccessToken {
    public var apiKey: String
    public var apiSecret: String

    public init(apiKey: String, apiSecret: String) {
        self.apiKey = apiKey; self.apiSecret = apiSecret
    }

    public func make(identity: String, room: String, canPublish: Bool, ttl: TimeInterval = 86_400,
                     now: Date = Date()) -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let iat = Int(now.timeIntervalSince1970)
        let claims: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "name": identity,
            "nbf": iat - 10,
            "iat": iat,
            "exp": iat + Int(ttl),
            "video": [
                "room": room,
                "roomJoin": true,
                "canPublish": canPublish,
                "canSubscribe": true,
                "canPublishData": true,
            ] as [String: Any],
        ]
        let h = Self.b64(try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let c = Self.b64(try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
        let input = "\(h).\(c)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: Data(apiSecret.utf8)))
        return "\(input).\(Self.b64(Data(mac)))"
    }

    public static func b64(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public func randomSecret(bytes: Int = 24) -> String {
    var d = Data(count: bytes)
    for i in 0..<bytes { d[i] = UInt8.random(in: 0...255) }
    return AccessToken.b64(d)
}
