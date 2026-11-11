import CryptoKit
import Foundation
import PortholeCore

private func get(_ target: String, method: String = "GET") -> String {
    "\(method) \(target) HTTP/1.1\r\nHost: mini:7878\r\n\r\n"
}

private func body(_ r: HTTPResponse) -> [String: Any]? { json(r.body) }

func pairingTests() {
    let t0 = Date(timeIntervalSince1970: 50_000)
    var codes = PairingCodes()
    expect("pairing: nothing issued is idle", codes.state(now: t0), .idle)
    expect("pairing: redeeming with nothing issued is noCode", codes.redeem("123456", now: t0), .noCode)

    expect("pairing: code is six digits, zero padded", codes.issue(now: t0, random: { 42 }), "000042")
    expect("pairing: random values above 999999 wrap into six digits", PairingCodes().issuing(now: t0, 1_234_567), "234567")
    expect("pairing: fresh code is active for 120 s", codes.state(now: t0), .active(code: "000042", secondsLeft: 120))
    expect("pairing: seconds left round up", codes.state(now: t0.addingTimeInterval(0.4)), .active(code: "000042", secondsLeft: 120))
    expect("pairing: one second before expiry is still active", codes.state(now: t0.addingTimeInterval(119)),
           .active(code: "000042", secondsLeft: 1))
    expect("pairing: right code is accepted", codes.redeem("000042", now: t0.addingTimeInterval(30)), .accepted)
    expect("pairing: state after use is used", codes.state(now: t0.addingTimeInterval(31)), .used)
    expect("pairing: a code is single-use", codes.redeem("000042", now: t0.addingTimeInterval(31)), .noCode)

    var spaced = PairingCodes()
    _ = spaced.issue(now: t0, random: { 123_456 })
    expect("pairing: spaces and dashes in the typed code are ignored", spaced.redeem(" 123-456 ", now: t0), .accepted)

    var exp = PairingCodes()
    _ = exp.issue(now: t0, random: { 111_111 })
    expect("pairing: exactly 120 s later the code has expired", exp.redeem("111111", now: t0.addingTimeInterval(120)), .expired)
    expect("pairing: state after expiry is expired", exp.state(now: t0.addingTimeInterval(121)), .expired)
    expect("pairing: an expired code stays dead", exp.redeem("111111", now: t0.addingTimeInterval(121)), .expired)

    var lock = PairingCodes()
    _ = lock.issue(now: t0, random: { 222_222 })
    var outcomes: [PairingCodes.Outcome] = []
    for guess in ["000000", "222223", "", "22222", "abcdef"] { outcomes.append(lock.redeem(guess, now: t0)) }
    expect("pairing: wrong tries count down then lock on the fifth",
           outcomes, [.wrong(left: 4), .wrong(left: 3), .wrong(left: 2), .wrong(left: 1), .locked])
    expect("pairing: after locking even the right code is refused", lock.redeem("222222", now: t0), .locked)
    expect("pairing: state after locking is locked", lock.state(now: t0), .locked)

    var again = PairingCodes()
    _ = again.issue(now: t0, random: { 333_333 })
    for _ in 0..<4 { _ = again.redeem("999999", now: t0) }
    expect("pairing: four wrong tries still leave the right code usable", again.redeem("333333", now: t0), .accepted)

    var reissue = PairingCodes()
    _ = reissue.issue(now: t0, random: { 444_444 })
    for _ in 0..<5 { _ = reissue.redeem("000000", now: t0) }
    _ = reissue.issue(now: t0.addingTimeInterval(10), random: { 555_555 })
    expect("pairing: a new code resets the wrong-try count", reissue.redeem("000000", now: t0.addingTimeInterval(10)), .wrong(left: 4))
    expect("pairing: a new code replaces the old one", reissue.redeem("444444", now: t0.addingTimeInterval(10)), .wrong(left: 3))
    expect("pairing: the new code works", reissue.redeem("555555", now: t0.addingTimeInterval(10)), .accepted)
    expect("pairing: a new code gets a fresh 120 s", { () -> PairingCodes.State in
        var c = PairingCodes(); _ = c.issue(now: t0, random: { 1 }); _ = c.issue(now: t0.addingTimeInterval(100), random: { 2 })
        return c.state(now: t0.addingTimeInterval(200))
    }(), .active(code: "000002", secondsLeft: 20))

    var cancel = PairingCodes()
    _ = cancel.issue(now: t0, random: { 666_666 })
    cancel.cancel()
    expect("pairing: cancelled code is refused as noCode", cancel.redeem("666666", now: t0), .noCode)
    expect("pairing: state after cancel is idle", cancel.state(now: t0), .idle)

    check("pairing: default random codes are six digits", (0..<50).allSatisfy { _ in
        var c = PairingCodes(); let code = c.issue(now: t0); return code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    })

    expect("pairing code normalize: keeps ASCII digits only", normalizePairingCode(" 12-3 4٥6 "), "12346")
    check("pairing code shape: 123456", looksLikePairingCode("123456"))
    check("pairing code shape: 123 456", looksLikePairingCode("123 456"))
    check("pairing code shape: 123-456", looksLikePairingCode("123-456"))
    check("pairing code shape: a password is not a code", !looksLikePairingCode("aB3_x9Qw-7Lm"))
    check("pairing code shape: five digits is not a code", !looksLikePairingCode("12345"))
    check("pairing code shape: seven digits is not a code", !looksLikePairingCode("1234567"))
    check("pairing code shape: digits with letters is not a code", !looksLikePairingCode("123a456"))
    expect("pairing code display: grouped 3 + 3", displayPairingCode("012345"), "012 345")

    expect("pair message: one try left is singular", pairMessage(.wrong(left: 1)), "Wrong code. 1 try left.")
    expect("pair message: several tries plural", pairMessage(.wrong(left: 3)), "Wrong code. 3 tries left.")
    expect("pair message: accepted has none", pairMessage(.accepted), nil)

    var now = t0
    let desk = PairingDesk(clock: { now }, random: { 987_654 })
    expect("pairing desk: issues through the injected random source", desk.issue(), "987654")
    now = t0.addingTimeInterval(60)
    expect("pairing desk: uses the injected clock", desk.state(), .active(code: "987654", secondsLeft: 60))
    now = t0.addingTimeInterval(120)
    expect("pairing desk: expires on the injected clock", desk.redeem("987654"), .expired)
    _ = desk.issue()
    let group = DispatchGroup()
    var accepted = 0
    let lockCount = NSLock()
    for i in 0..<40 {
        DispatchQueue.global().async(group: group) {
            let r = desk.redeem(i % 10 == 3 ? "000000" : "987654")
            if r == .accepted { lockCount.lock(); accepted += 1; lockCount.unlock() }
        }
    }
    group.wait()
    expect("pairing desk: 40 concurrent redeems (4 wrong) accept the code exactly once", accepted, 1)

    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    var clock = t0
    let routeDesk = PairingDesk(clock: { clock }, random: { 246_810 })
    let trustDir = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-pairing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: trustDir) }
    let routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, suffix: { "s" },
                           pairing: routeDesk, hostName: "Leo\u{2019}s Mac mini", trust: TrustStore(directory: trustDir))
    let dev = "&device=0123456789abcdef"

    let hello = routes.respond(to: get("/hello"))
    check("hello route: 200 JSON", hello.status == "200 OK" && hello.contentType == "application/json")
    expect("hello route: exactly app, name, version", Set(body(hello)?.keys.map { $0 } ?? []), ["app", "name", "version"])
    check("hello route: says porthole, the host name and version 1",
          body(hello)?["app"] as? String == "porthole" && body(hello)?["name"] as? String == "Leo\u{2019}s Mac mini"
          && body(hello)?["version"] as? Int == 1)
    check("hello route: never leaks the password", !String(decoding: hello.body, as: UTF8.self).contains("pw-123"))
    expect("hello route: its JSON parses back", HostHello.parse(hello.body), HostHello(name: "Leo\u{2019}s Mac mini", version: 1))

    let device = "0123456789abcdef"
    let none = pairOverRoutes(routes, code: "246810", device: device)
    check("pair route: with no code issued is 403 with a hint",
          none.start.status == "403 Forbidden" && none.error?.contains("Pair a New Viewer") == true)
    _ = routeDesk.issue()
    let wrong = pairOverRoutes(routes, code: "111111", device: device)
    check("pair route: a wrong code is 403 and says how many tries are left",
          wrong.finish?.status == "403 Forbidden" && wrong.error == "Wrong code. 4 tries left."
          && !String(decoding: wrong.finish?.body ?? Data(), as: UTF8.self).contains("pw-123"))
    check("pair route: the start answer carries no secret and not the code",
          !String(decoding: wrong.start.body, as: UTF8.self).contains("246810") && body(wrong.start)?["secret"] == nil)
    let head = routes.respond(to: get("/pair/finish?device=\(device)&tag=00", method: "HEAD"))
    check("pair route: HEAD is refused so it cannot burn the code", head.status == "405 Method Not Allowed")
    let ok = pairOverRoutes(routes, code: "246 810", device: device)
    check("pair route: the right code returns a sealed device secret", ok.finish?.status == "200 OK"
          && Set(body(ok.finish!)?.keys.map { $0 } ?? []) == ["sealed"])
    if case .paired(let secret, _, let host) = ok.reply {
        check("pair route: the viewer opens the secret and host name", secret.count >= 32 && host == "Leo\u{2019}s Mac mini")
        check("pair route: the secret never travels in clear", !String(decoding: ok.finish!.body, as: UTF8.self).contains(secret))
    } else { check("pair route: the viewer opens the secret and host name", false) }
    let reuse = pairOverRoutes(routes, code: "246810", device: device)
    check("pair route: the code works once", reuse.start.status == "403 Forbidden" && reuse.reply == nil)
    _ = routeDesk.issue()
    clock = t0.addingTimeInterval(121)
    let late = pairOverRoutes(routes, code: "246810", device: device)
    check("pair route: an expired code is refused", late.start.status == "403 Forbidden" && late.error?.contains("expired") == true)
    clock = t0
    _ = routeDesk.issue()
    let orphan = routes.respond(to: get("/pair/finish?device=\(device)&tag=00"))
    check("pair route: a finish without a start is refused and burns no try",
          orphan.status == "403 Forbidden" && routeDesk.state() == .active(code: "246810", secondsLeft: 120))
    expect("pair route: POST is still 405", routes.respond(to: get("/pair/start?device=\(device)", method: "POST")).status, "405 Method Not Allowed")
    expect("pair route: the old one-step route says to update", routes.respond(to: get("/pair?code=246810" + dev)).status, "400 Bad Request")
    check("pair route: the old route burned nothing", routeDesk.state() == .active(code: "246810", secondsLeft: 120))

    let noDesk = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil)
    expect("pair route: without a pairing desk it does not exist", noDesk.respond(to: get("/pair/start?device=0123456789abcdef&v=00")).status, "404 Not Found")
    expect("hello route: default host name is Mac", HostHello.parse(noDesk.respond(to: get("/hello")).body)?.name, "Mac")
    let fav = routes.respond(to: get("/favicon.ico"))
    check("favicon: 204 with an empty body instead of a 404", fav.status == "204 No Content" && fav.body.isEmpty)
    expect("token route: still works next to pairing", routes.respond(to: get("/token?pw=pw-123")).status, "200 OK")

    expect("pair start URL", pairStartURL(hostAddress: "100.101.102.103", device: device, name: "Air", share: "ab")?.absoluteString,
           "http://100.101.102.103:7878/pair/start?device=0123456789abcdef&name=Air&v=ab")
    expect("pair finish URL: keeps a custom port", pairFinishURL(hostAddress: "mini.local:9000", device: device, name: "Air", tag: "cd")?.absoluteString,
           "http://mini.local:9000/pair/finish?device=0123456789abcdef&name=Air&tag=cd")
    expect("pair start URL: bad address gives none", pairStartURL(hostAddress: "mini:abc", device: device, name: "a", share: "ab"), nil)
    check("pair start reply: 403 passes the host's message through",
          parsePairStart(status: 403, body: Data(#"{"error":"Wrong code. 4 tries left."}"#.utf8)).refusal == "Wrong code. 4 tries left.")
    check("pair start reply: 404 from an older host says to update",
          parsePairStart(status: 404, body: Data("not found".utf8)).refusal == "This host runs an older Porthole. Update it, then pair again.")
    let anyKey = SymmetricKey(size: .bits256)
    expect("pair finish reply: an unsealed 200 is refused", parsePairFinish(status: 200, body: Data(#"{"secret":"abc"}"#.utf8), key: anyKey),
           .refused("The answer didn't come from a Mac that knows the code. Nothing was paired."))
    expect("pair finish reply: 403 passes the host's message through",
           parsePairFinish(status: 403, body: Data(#"{"error":"Wrong code. 4 tries left."}"#.utf8), key: anyKey), .refused("Wrong code. 4 tries left."))
}

private extension PairingCodes {
    func issuing(now: Date, _ value: UInt32) -> String {
        var c = self
        return c.issue(now: now, random: { value })
    }
}
