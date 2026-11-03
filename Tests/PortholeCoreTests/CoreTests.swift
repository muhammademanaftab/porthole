import CryptoKit
import Foundation
import XCTest
@testable import PortholeCore

final class MessageTests: XCTestCase {
    func testRoundTrip() {
        var m = Message(.mouse)
        m.win = 42; m.kind = .down; m.btn = 0; m.x = 0.25; m.y = 0.75; m.clicks = 2; m.mods = Modifiers.command.rawValue
        XCTAssertEqual(Message.decode(m.encoded()), m)
    }

    func testDecodesBrowserJSON() throws {
        let json = #"{"t":"key","win":7,"code":0,"down":true,"mods":9,"s":"a"}"#
        let m = try XCTUnwrap(Message.decode(Data(json.utf8)))
        XCTAssertEqual(m.t, .key)
        XCTAssertEqual(m.code, 0)
        XCTAssertEqual(Modifiers(rawValue: m.mods!), [.shift, .command])
    }

    func testUnknownKindIsRejected() {
        XCTAssertNil(Message.decode(Data(#"{"t":"nope"}"#.utf8)))
    }

    func testTrackNames() {
        XCTAssertEqual(Message.trackName(for: 123), "win-123")
        XCTAssertEqual(Message.windowID(fromTrackName: "win-123"), 123)
        XCTAssertNil(Message.windowID(fromTrackName: "screen"))
    }
}

final class GeometryTests: XCTestCase {
    func testGlobalPoint() {
        let b = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertEqual(globalPoint(nx: 0.5, ny: 0.5, windowBounds: b), CGPoint(x: 500, y: 350))
        XCTAssertEqual(globalPoint(nx: -1, ny: 2, windowBounds: b), CGPoint(x: 100, y: 650))
    }

    func testLetterboxedNormalization() {
        // 16:9 video in a square view: bars top and bottom.
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1600)
        let content = CGSize(width: 1600, height: 900)
        XCTAssertEqual(fittedRect(content: content, in: bounds), CGRect(x: 0, y: 350, width: 1600, height: 900))
        XCTAssertNil(normalized(CGPoint(x: 800, y: 100), content: content, in: bounds))
        let p = normalized(CGPoint(x: 800, y: 800), content: content, in: bounds)!
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
    }
}

final class TokenTests: XCTestCase {
    func testTokenIsValidHS256() throws {
        let t = AccessToken(apiKey: "key", apiSecret: "secret")
        let jwt = t.make(identity: "host", room: "porthole", canPublish: true, now: Date(timeIntervalSince1970: 1_000_000))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(parts[0]).\(parts[1])".utf8), using: SymmetricKey(data: Data("secret".utf8)))
        XCTAssertEqual(AccessToken.b64(Data(mac)), parts[2])

        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base64Encoded: b64)!) as? [String: Any])
        XCTAssertEqual(claims["iss"] as? String, "key")
        XCTAssertEqual(claims["sub"] as? String, "host")
        let video = try XCTUnwrap(claims["video"] as? [String: Any])
        XCTAssertEqual(video["room"] as? String, "porthole")
        XCTAssertEqual(video["canPublish"] as? Bool, true)
    }
}
