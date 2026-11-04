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

    let none = routes.respond(to: get("/pair?code=246810" + dev))
    check("pair route: with no code issued is 403 with a hint",
          none.status == "403 Forbidden" && (body(none)?["error"] as? String)?.contains("Pair a New Viewer") == true)
    _ = routeDesk.issue()
    let wrong = routes.respond(to: get("/pair?code=111111" + dev))
    check("pair route: wrong code is 403 and says how many tries are left",
          wrong.status == "403 Forbidden" && body(wrong)?["error"] as? String == "Wrong code. 4 tries left."
          && !String(decoding: wrong.body, as: UTF8.self).contains("pw-123"))
    let head = routes.respond(to: get("/pair?code=246810", method: "HEAD"))
    check("pair route: HEAD is refused so it cannot burn the code", head.status == "405 Method Not Allowed")
    let ok = routes.respond(to: get("/pair?code=246%20810" + dev))
    check("pair route: right code returns a device secret", ok.status == "200 OK" && ok.contentType == "application/json"
          && (body(ok)?["secret"] as? String)?.isEmpty == false)
    expect("pair route: body has the secret and host name, never the password", Set(body(ok)?.keys.map { $0 } ?? []), ["secret", "host"])
    let reuse = routes.respond(to: get("/pair?code=246810" + dev))
    check("pair route: the code works once", reuse.status == "403 Forbidden" && body(reuse)?["secret"] == nil)
    _ = routeDesk.issue()
    clock = t0.addingTimeInterval(121)
    let late = routes.respond(to: get("/pair?code=246810" + dev))
    check("pair route: expired code is refused", late.status == "403 Forbidden" && (body(late)?["error"] as? String)?.contains("expired") == true)
    let missing = routes.respond(to: get("/pair?device=0123456789abcdef"))
    check("pair route: missing code is refused", missing.status == "403 Forbidden")
    expect("pair route: POST is still 405", routes.respond(to: get("/pair?code=1", method: "POST")).status, "405 Method Not Allowed")

    let noDesk = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil)
    expect("pair route: without a pairing desk it does not exist", noDesk.respond(to: get("/pair?code=1")).status, "404 Not Found")
    expect("hello route: default host name is Mac", HostHello.parse(noDesk.respond(to: get("/hello")).body)?.name, "Mac")
    let fav = routes.respond(to: get("/favicon.ico"))
    check("favicon: 204 with an empty body instead of a 404", fav.status == "204 No Content" && fav.body.isEmpty)
    expect("token route: still works next to pairing", routes.respond(to: get("/token?pw=pw-123")).status, "200 OK")

    expect("pair URL: digits only, default port", pairURL(hostAddress: "100.101.102.103", code: "123 456")?.absoluteString,
           "http://100.101.102.103:7878/pair?code=123456")
    expect("pair URL: keeps a custom port", pairURL(hostAddress: "mini.local:9000", code: "123456")?.absoluteString,
           "http://mini.local:9000/pair?code=123456")
    expect("pair URL: bad address gives none", pairURL(hostAddress: "mini:abc", code: "123456"), nil)

    expect("pair reply: 200 with password", parsePairReply(status: 200, body: Data(#"{"password":"abc"}"#.utf8)), .password("abc"))
    expect("pair reply: 403 passes the host's message through",
           parsePairReply(status: 403, body: Data(#"{"error":"Wrong code. 4 tries left."}"#.utf8)), .refused("Wrong code. 4 tries left."))
    expect("pair reply: 200 without a password is refused",
           parsePairReply(status: 200, body: Data("{}".utf8)), .refused("The host didn't accept the code (HTTP 200)."))
    expect("pair reply: empty password is refused",
           parsePairReply(status: 200, body: Data(#"{"password":""}"#.utf8)), .refused("The host didn't accept the code (HTTP 200)."))
    expect("pair reply: 404 from an older host says to use the password",
           parsePairReply(status: 404, body: Data("not found".utf8)),
           .refused("This host is an older Porthole without pairing codes. Use its password instead."))
}

private extension PairingCodes {
    func issuing(now: Date, _ value: UInt32) -> String {
        var c = self
        return c.issue(now: now, random: { value })
    }
}
