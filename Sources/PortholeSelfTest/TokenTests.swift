import Foundation
import PortholeCore

func tokenTests() {
    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    let jwt = keys.make(identity: "host", room: "porthole", canPublish: true, now: Date(timeIntervalSince1970: 1_000_000))
    expect("token: matches a known-answer JWT computed with Python hmac/hashlib/base64", jwt,
           "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEwODY0MDAsImlhdCI6MTAwMDAwMCwiaXNzIjoia2V5IiwibmFtZSI6Imhvc3QiLCJuYmYiOjk5OTk5MCwic3ViIjoiaG9zdCIsInZpZGVvIjp7ImNhblB1Ymxpc2giOnRydWUsImNhblB1Ymxpc2hEYXRhIjp0cnVlLCJjYW5TdWJzY3JpYmUiOnRydWUsInJvb20iOiJwb3J0aG9sZSIsInJvb21Kb2luIjp0cnVlfX0.DZil8AHGEPo6tbQKXSw4mxxMPNFc9eanwbBemmalJaI")

    let viewer = keys.make(identity: "view-x-1", room: "lobby", canPublish: false, ttl: 60,
                           now: Date(timeIntervalSince1970: 1_000_000.9))
    let claims = viewer.split(separator: ".").dropFirst().first.flatMap { decodeBase64URL(String($0)) }.flatMap(json)
    let video = claims?["video"] as? [String: Any]
    check("token: fractional now truncates to whole seconds, nbf is 10s earlier, exp honours ttl",
          claims?["iat"] as? Int == 1_000_000 && claims?["nbf"] as? Int == 999_990 && claims?["exp"] as? Int == 1_000_060)
    check("token: viewer grant cannot publish but can join, subscribe and send data",
          video?["canPublish"] as? Bool == false && video?["roomJoin"] as? Bool == true
          && video?["canSubscribe"] as? Bool == true && video?["canPublishData"] as? Bool == true
          && video?["room"] as? String == "lobby" && claims?["sub"] as? String == "view-x-1" && claims?["name"] as? String == "view-x-1")

    expect("base64url: empty", AccessToken.b64(Data()), "")
    expect("base64url: one byte drops both pad chars", AccessToken.b64(Data([0])), "AA")
    expect("base64url: two bytes drop one pad char", AccessToken.b64(Data([0, 0])), "AAA")
    expect("base64url: three bytes need no padding", AccessToken.b64(Data([0, 0, 0])), "AAAA")
    expect("base64url: + and / become - and _", AccessToken.b64(Data([0xFB, 0xFF, 0xBF])), "-_-_")
    expect("base64url: mixed with padding", AccessToken.b64(Data([0xFB, 0xFF])), "-_8")

    for (bytes, length) in [(0, 0), (3, 4), (9, 12), (24, 32), (32, 43)] {
        expect("secret: \(bytes) bytes gives \(length) characters", randomSecret(bytes: bytes).count, length)
    }
    let s = randomSecret()
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    check("secret: only URL-safe base64 characters", s.allSatisfy { allowed.contains($0) })
    expect("secret: decodes back to the requested 24 bytes", decodeBase64URL(s)?.count, 24)
    check("secret: two secrets differ", randomSecret() != randomSecret())
    let bytes = (0..<64).flatMap { _ in decodeBase64URL(randomSecret(bytes: 32)).map(Array.init) ?? [] }
    check("secret: bytes use the full range (some >= 128 across 64 secrets)", bytes.count == 2048 && bytes.contains { $0 >= 128 })
}
