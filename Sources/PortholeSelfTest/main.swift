import CoreGraphics
import CryptoKit
import Foundation
import PortholeCore

var failures = 0
func check(_ name: String, _ ok: @autoclosure () -> Bool) {
    if ok() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

var m = Message(.mouse)
m.win = 42; m.kind = .down; m.btn = 0; m.x = 0.25; m.y = 0.75; m.clicks = 2; m.mods = Modifiers.command.rawValue
check("message round trip", Message.decode(m.encoded()) == m)

let browser = Message.decode(Data(#"{"t":"key","win":7,"code":0,"down":true,"mods":9,"s":"a"}"#.utf8))
check("decodes browser key JSON", browser?.t == .key && browser?.code == 0 && browser?.win == 7)
check("modifier bits shift+command", Modifiers(rawValue: browser?.mods ?? 0) == [.shift, .command])
check("unknown message kind rejected", Message.decode(Data(#"{"t":"nope"}"#.utf8)) == nil)

check("track name from id", Message.trackName(for: 123) == "win-123")
check("id from track name", Message.windowID(fromTrackName: "win-123") == 123)
check("non-window track ignored", Message.windowID(fromTrackName: "screen") == nil)

let b = CGRect(x: 100, y: 50, width: 800, height: 600)
check("global point centre", globalPoint(nx: 0.5, ny: 0.5, windowBounds: b) == CGPoint(x: 500, y: 350))
check("global point clamps", globalPoint(nx: -1, ny: 2, windowBounds: b) == CGPoint(x: 100, y: 650))

let square = CGRect(x: 0, y: 0, width: 1600, height: 1600)
let wide = CGSize(width: 1600, height: 900)
check("letterbox rect", fittedRect(content: wide, in: square) == CGRect(x: 0, y: 350, width: 1600, height: 900))
check("click on letterbox bar ignored", normalized(CGPoint(x: 800, y: 100), content: wide, in: square) == nil)
let c = normalized(CGPoint(x: 800, y: 800), content: wide, in: square)
check("click in picture centre", c.map { abs($0.x - 0.5) < 1e-9 && abs($0.y - 0.5) < 1e-9 } ?? false)

let jwt = AccessToken(apiKey: "key", apiSecret: "secret")
    .make(identity: "host", room: "porthole", canPublish: true, now: Date(timeIntervalSince1970: 1_000_000))
let parts = jwt.split(separator: ".").map(String.init)
check("token has three parts", parts.count == 3)
let mac = HMAC<SHA256>.authenticationCode(for: Data("\(parts[0]).\(parts[1])".utf8), using: SymmetricKey(data: Data("secret".utf8)))
check("token signature is HS256", parts.count == 3 && Data(mac).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == parts[2])
var p = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
while p.count % 4 != 0 { p += "=" }
let claims = (Data(base64Encoded: p)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
let video = claims?["video"] as? [String: Any]
check("token claims", claims?["iss"] as? String == "key" && claims?["sub"] as? String == "host"
      && video?["room"] as? String == "porthole" && video?["canPublish"] as? Bool == true)

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
