import Foundation
import PortholeCore

private func get(_ target: String, method: String = "GET", host: String = "mini:7878", extra: [String] = []) -> String {
    "\(method) \(target) HTTP/1.1\r\nHost: \(host)\r\n" + extra.map { $0 + "\r\n" }.joined() + "\r\n"
}

private func body(_ r: HTTPResponse) -> [String: Any]? { json(r.body) }

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-trust-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? nil
}

private func claims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".").map(String.init)
    guard parts.count == 3 else { return nil }
    return decodeBase64URL(parts[1]).flatMap(json)
}

private let viewerA = "0123456789abcdef"
private let viewerB = "fedcba9876543210"
private let hostID = "aaaabbbbccccdddd"

func trustTests() {
    identityTests()
    trustStoreTests()
    tokenAuthTests()
    requestStateTests()
    trustRouteTests()
    localRouteTests()
    viewerSideTests()
    commandTests()
    budgetTests()
    lockoutTests()
    privateFileTests()
}

private func identityTests() {
    var bytes: [UInt8] = [0, 1, 0xab, 0xff, 0x10, 0x20, 0x30, 0x40]
    expect("device id: 16 lowercase hex characters from 8 random bytes",
           DeviceIdentity.makeID(random: { bytes.removeFirst() }), "0001abff10203040")
    check("device id: default ids are valid", (0..<20).allSatisfy { _ in DeviceIdentity.isValidID(DeviceIdentity.makeID()) })
    check("device id: two default ids differ", DeviceIdentity.makeID() != DeviceIdentity.makeID())
    for bad in ["", "0123456789ABCDEF", "0123456789abcde", "0123456789abcdef0", "0123456789abcdeg", "../../etc/passwd"] {
        check("device id: \"\(bad)\" is not valid", !DeviceIdentity.isValidID(bad))
    }

    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = DeviceIdentity.loadOrCreate(in: dir, makeID: { viewerA })
    expect("device identity: created on first use", first.id, viewerA)
    expect("device identity: stable on the next load", DeviceIdentity.loadOrCreate(in: dir, makeID: { viewerB }).id, viewerA)
    expect("device identity: file is 0600", mode(dir.appendingPathComponent("identity.json")), 0o600)
    try? Data("{garbage".utf8).write(to: dir.appendingPathComponent("identity.json"))
    expect("device identity: an unreadable file is replaced", DeviceIdentity.loadOrCreate(in: dir, makeID: { viewerB }).id, viewerB)
    try? Data(#"{"id":"NOT-HEX"}"#.utf8).write(to: dir.appendingPathComponent("identity.json"))
    expect("device identity: an invalid id is replaced", DeviceIdentity.loadOrCreate(in: dir, makeID: { viewerA }).id, viewerA)

    expect("support dir: PORTHOLE_HOME overrides", portholeSupportDirectory(environment: ["PORTHOLE_HOME": "/tmp/ph"]).path, "/tmp/ph")
    check("support dir: default is Application Support/Porthole",
          portholeSupportDirectory(environment: [:]).path.hasSuffix("Library/Application Support/Porthole"))
    check("support dir: empty PORTHOLE_HOME is ignored",
          portholeSupportDirectory(environment: ["PORTHOLE_HOME": ""]).path.hasSuffix("Application Support/Porthole"))

    expect("device name: trimmed", cleanDeviceName("  Renée's MacBook \n"), "Renée's MacBook")
    expect("device name: control characters dropped", cleanDeviceName("Evil\u{7}\u{1b}[31mMac"), "Evil[31mMac")
    expect("device name: empty becomes Mac", cleanDeviceName("  "), "Mac")
    expect("device name: nil becomes Mac", cleanDeviceName(nil), "Mac")
    expect("device name: cut to 64 characters", cleanDeviceName(String(repeating: "x", count: 100)).count, 64)
}

private func trustStoreTests() {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let d = PairedDevice(id: viewerA, name: "Air", secretHash: secretDigest("s3"), pairedAt: t0)
    expect("paired list: encode then decode round trips", PairedDevices.decode(PairedDevices.encode([d])), [d])
    check("paired list: file is versioned and stores dates as ISO 8601", {
        let s = String(decoding: PairedDevices.encode([d]), as: UTF8.self)
        return s.contains(#""version" : 1"#) && s.contains("2023-11-14T22:13:20Z")
    }())
    expect("paired list: garbage decodes to nil", PairedDevices.decode(Data("nope".utf8)), nil)
    let mixed = #"{"version":1,"devices":[{"id":"BAD","name":"x","secretHash":"h","pairedAt":"2023-11-14T22:13:20Z"},{"id":"0123456789abcdef","name":"ok","secretHash":"h","pairedAt":"2023-11-14T22:13:20Z"},{"id":"fedcba9876543210","name":"nohash","secretHash":"","pairedAt":"2023-11-14T22:13:20Z"}]}"#
    expect("paired list: entries with bad ids or no hash are dropped", PairedDevices.decode(Data(mixed.utf8))?.map(\.name), ["ok"])
    let again = PairedDevice(id: viewerA, name: "Air 2", secretHash: "x", pairedAt: t0)
    expect("paired list: pairing the same device again replaces it",
           PairedDevices.adding(again, to: [d]).map(\.name), ["Air 2"])

    expect("secret digest: SHA-256 hex", secretDigest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    check("paired device: accepts its secret", d.accepts("s3"))
    check("paired device: refuses another secret", !d.accepts("s4"))
    check("paired device: refuses an empty secret", !PairedDevice(id: viewerA, name: "", secretHash: secretDigest(""), pairedAt: t0).accepts(""))

    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TrustStore(directory: dir, clock: { t0 })
    expect("trust store: starts empty", store.devices(), [])
    expect("trust store: refuses an invalid device id", store.pair(id: "nope", name: "x", secret: "s"), nil)
    expect("trust store: pairing returns the secret", store.pair(id: viewerA, name: " Air ", secret: "secret-a"), "secret-a")
    check("trust store: generated secrets are long and random", {
        guard let a = store.pair(id: viewerB, name: "B"), let b = store.pair(id: viewerB, name: "B") else { return false }
        return a.count >= 32 && a != b
    }())
    expect("trust store: file is 0600", mode(store.url), 0o600)
    check("trust store: the file never holds a plain secret",
          !String(decoding: (try? Data(contentsOf: store.url)) ?? Data(), as: UTF8.self).contains("secret-a"))
    expect("trust store: verify with the right secret", store.verify(id: viewerA, secret: "secret-a")?.name, "Air")
    expect("trust store: verify with the wrong secret", store.verify(id: viewerA, secret: "secret-b"), nil)
    expect("trust store: verify with another device's id", store.verify(id: viewerB, secret: "secret-a"), nil)
    check("trust store: a second store on the same folder sees the pairing",
          TrustStore(directory: dir).verify(id: viewerA, secret: "secret-a") != nil)
    expect("trust store: re-pairing the same device keeps one entry", store.devices().filter { $0.id == viewerB }.count, 1)
    expect("trust store: unpair by name", store.unpair("air"), .found(PairedDevice(id: viewerA, name: "Air", secretHash: secretDigest("secret-a"), pairedAt: t0)))
    expect("trust store: unpaired device is refused at once", store.verify(id: viewerA, secret: "secret-a"), nil)
    check("trust store: unpaired device is gone from the file", !TrustStore(directory: dir).isPaired(viewerA))
    expect("trust store: unpairing again finds nothing", store.unpair(viewerA), .none)
    check("trust store: the other device stays", store.isPaired(viewerB))

    let a = PairedDevice(id: viewerA, name: "Mac", secretHash: "h", pairedAt: t0)
    let b = PairedDevice(id: viewerB, name: "Mac", secretHash: "h", pairedAt: t0)
    let c = PairedDevice(id: "0123000000000000", name: "Studio", secretHash: "h", pairedAt: t0)
    expect("find paired: by exact id", findPaired(viewerB, in: [a, b, c]), .found(b))
    expect("find paired: id match ignores case", findPaired(viewerB.uppercased(), in: [a, b, c]), .found(b))
    expect("find paired: by name, case and curly quotes ignored", findPaired("studio", in: [a, b, c]), .found(c))
    expect("find paired: two Macs with one name is ambiguous", findPaired("mac", in: [a, b, c]), .ambiguous([a, b]))
    expect("find paired: unique id prefix of 4+", findPaired("fedc", in: [a, b, c]), .found(b))
    expect("find paired: shared id prefix is ambiguous", findPaired("0123", in: [a, b, c]), .ambiguous([a, c]))
    expect("find paired: prefix under 4 characters is not used", findPaired("fed", in: [a, b, c]), .none)
    expect("find paired: blank finds nothing", findPaired("  ", in: [a, b, c]), .none)
}

private func tokenAuthTests() {
    let t0 = Date(timeIntervalSince1970: 0)
    let dev = PairedDevice(id: viewerA, name: "Air", secretHash: secretDigest("s"), pairedAt: t0)
    let verify: (String, String) -> PairedDevice? = { id, secret in id == viewerA && secret == "s" ? dev : nil }
    expect("token auth: right password", authorizeToken(query: ["pw": "pw"], password: "pw", verify: verify), .password)
    expect("token auth: wrong password", authorizeToken(query: ["pw": "x"], password: "pw", verify: verify), .refused)
    expect("token auth: nothing given", authorizeToken(query: [:], password: "pw", verify: verify), .refused)
    expect("token auth: paired device with its secret", authorizeToken(query: ["device": viewerA, "secret": "s"], password: "pw", verify: verify), .device(dev))
    expect("token auth: paired device with a wrong secret is unpaired",
           authorizeToken(query: ["device": viewerA, "secret": "x"], password: "pw", verify: verify), .unpaired)
    expect("token auth: unknown device is unpaired", authorizeToken(query: ["device": viewerB, "secret": "s"], password: "pw", verify: verify), .unpaired)
    expect("token auth: device without a secret is unpaired", authorizeToken(query: ["device": viewerA], password: "pw", verify: verify), .unpaired)
    expect("token auth: a failed device still accepts the right password",
           authorizeToken(query: ["device": viewerB, "secret": "s", "pw": "pw"], password: "pw", verify: verify), .password)
    expect("token auth: empty device falls back to the password rule",
           authorizeToken(query: ["device": "", "pw": "x"], password: "pw", verify: verify), .refused)

    let ident = pairedIdentity(name: "Renée's Air", suffix: "a-_b", device: viewerA)
    expect("paired identity: viewer identity plus .device", ident, "view-RenéesAir-a-_b.\(viewerA)")
    expect("paired identity: device id parses back", deviceID(fromIdentity: ident), viewerA)
    expect("paired identity: password viewers have no device", deviceID(fromIdentity: "view-browser-abcd"), nil)
    expect("paired identity: the host has no device", deviceID(fromIdentity: "host"), nil)
    expect("paired identity: a name cannot smuggle a device in",
           deviceID(fromIdentity: WebRoutes.viewerIdentity(name: "x.\(viewerA)", suffix: "s")), nil)
    let ids = ["host", "view-a-s", "view-b-s.\(viewerA)", "view-c-t.\(viewerA)", "view-d-s.\(viewerB)"]
    expect("revoked: only identities of devices no longer paired", revokedIdentities(ids, isPaired: { $0 == viewerB }),
           ["view-b-s.\(viewerA)", "view-c-t.\(viewerA)"])
    expect("identities of a device: every connection of that device", identities(ids, of: viewerB), ["view-d-s.\(viewerB)"])

    let keys = AccessToken(apiKey: "k", apiSecret: "s")
    let admin = claims(keys.make(identity: "host-admin", room: "porthole", canPublish: false, ttl: 60, roomAdmin: true))
    check("admin token: grants roomAdmin for the room", (admin?["video"] as? [String: Any])?["roomAdmin"] as? Bool == true
          && (admin?["video"] as? [String: Any])?["room"] as? String == "porthole")
    check("viewer token: has no roomAdmin", (claims(keys.make(identity: "v", room: "porthole", canPublish: false))?["video"] as? [String: Any])?["roomAdmin"] == nil)
    let req = removeParticipantRequest(livekitPort: 7880, token: "tok", room: "porthole", identity: "view-a.\(viewerA)")
    check("remove participant: POSTs to the LiveKit RoomService on localhost",
          req?.httpMethod == "POST" && req?.url?.absoluteString == "http://127.0.0.1:7880/twirp/livekit.RoomService/RemoveParticipant"
          && req?.value(forHTTPHeaderField: "Authorization") == "Bearer tok"
          && req?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    expect("remove participant: body names the room and identity",
           req?.httpBody.map { String(decoding: $0, as: UTF8.self) }, #"{"identity":"view-a.0123456789abcdef","room":"porthole"}"#)
}

private func requestStateTests() {
    let t0 = Date(timeIntervalSince1970: 90_000)
    let a = PairRequester(id: viewerA, name: "Air")
    let b = PairRequester(id: viewerB, name: "Studio")
    var codes = PairingCodes()
    expect("request: first request issues a code", codes.request(from: a, now: t0, random: { 111_111 }), .issued("111111"))
    expect("request: code is bound to the requester", codes.requester, a)
    expect("request: the same Mac asking again gets the same code",
           codes.request(from: a, now: t0.addingTimeInterval(5), random: { 222_222 }), .same("111111"))
    expect("request: asking again does not extend the code", codes.state(now: t0.addingTimeInterval(60)),
           .active(code: "111111", secondsLeft: 60))
    expect("request: another Mac's code does not redeem from here", codes.redeem("111111", device: viewerB, now: t0), .wrong(left: 5))
    expect("request: no device id does not redeem a bound code", codes.redeem("111111", now: t0), .wrong(left: 5))
    expect("request: guesses from other Macs touch neither the tries nor the budget", codes.budget, GuessBudget())
    expect("request: the requester redeems its code", codes.redeem("111111", device: viewerA, now: t0), .accepted)
    expect("request: requester is kept after use for the host's message", codes.requester, a)

    var menu = PairingCodes()
    _ = menu.issue(now: t0, random: { 333_333 })
    expect("menu code: not bound to any Mac", menu.requester, nil)
    expect("menu code: any device may redeem it", menu.redeem("333333", device: viewerB, now: t0), .accepted)

    var swap = PairingCodes()
    _ = swap.request(from: a, now: t0, random: { 444_444 })
    expect("request: another Mac cannot replace a pending code", swap.request(from: b, now: t0.addingTimeInterval(20), random: { 555_555 }),
           .busy(seconds: 100))
    expect("request: the pending code still works for its Mac", swap.redeem("444444", device: viewerA, now: t0.addingTimeInterval(21)), .accepted)
    expect("request: once it is used another Mac may ask", swap.request(from: b, now: t0.addingTimeInterval(22), random: { 555_555 }),
           .issued("555555"))
    var menuFirst = PairingCodes()
    _ = menuFirst.issue(now: t0, random: { 1 })
    expect("request: a code from the host's menu is not replaced either", menuFirst.request(from: a, now: t0, random: { 2 }), .busy(seconds: 120))
    expect("request: a new request after expiry resets wrong tries", { () -> PairingCodes.Outcome in
        var c = PairingCodes()
        _ = c.request(from: a, now: t0, random: { 1 })
        _ = c.redeem("000000", device: viewerA, now: t0)
        _ = c.request(from: a, now: t0.addingTimeInterval(PairingCodes.lifetime), random: { 666_666 })
        return c.redeem("000000", device: viewerA, now: t0.addingTimeInterval(PairingCodes.lifetime))
    }(), .wrong(left: 4))

    var flood = PairingCodes()
    var outcomes: [PairingCodes.RequestOutcome] = []
    for i in 0..<7 {
        outcomes.append(flood.request(from: i % 2 == 0 ? a : b, now: t0.addingTimeInterval(Double(i)), random: { UInt32(i) }))
        flood.cancel()
    }
    expect("request: at most 6 new codes per 10 minutes", outcomes.last, .throttled)
    expect("request: the first 6 were issued", outcomes.prefix(6).allSatisfy { if case .issued = $0 { return true }; return false }, true)

    var expire = PairingCodes()
    _ = expire.request(from: a, now: t0, random: { 1 })
    expect("request: after expiry the same Mac gets a fresh code",
           expire.request(from: a, now: t0.addingTimeInterval(PairingCodes.lifetime), random: { 2 }), .issued("000002"))

    var current = PairingCodes()
    expect("paircode: with nothing active a fresh code is issued", current.currentOrIssue(now: t0, random: { 777_777 }), "777777")
    expect("paircode: that code is unbound", current.requester, nil)
    expect("paircode: a pending menu code blocks requests", current.request(from: a, now: t0.addingTimeInterval(1)), .busy(seconds: 119))
    current.cancel()
    _ = current.request(from: a, now: t0.addingTimeInterval(1), random: { 888_888 })
    expect("paircode: returns the code a Mac is waiting for", current.currentOrIssue(now: t0.addingTimeInterval(2), random: { 9 }), "888888")
    expect("paircode: does not unbind it", current.requester, a)

    var now = t0
    let desk = PairingDesk(clock: { now }, random: { 121_212 })
    _ = desk.request(from: a)
    now = t0.addingTimeInterval(30)
    let cur = desk.currentOrIssue()
    check("desk paircode: code, requester and seconds left", cur.code == "121212" && cur.requester == a && cur.secondsLeft == 90)
    _ = desk.reissue()
    expect("desk new code: stays bound to the requester", desk.requester, a)
    desk.cancel()
    expect("desk cancel: forgets the requester", desk.requester, nil)
}

private func trustRouteTests() {
    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TrustStore(directory: dir)
    var clock = Date(timeIntervalSince1970: 100_000)
    let desk = PairingDesk(clock: { clock }, random: { 135_790 })
    var routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, suffix: { "sfx" },
                           pairing: desk, hostName: "Mini", trust: store, hostID: hostID)
    let asked = NSLock()
    var requests: [(PairRequester, String)] = []
    routes.onPairRequest = { who, code in asked.lock(); requests.append((who, code)); asked.unlock() }

    let hello = routes.respond(to: get("/hello"))
    check("hello route: carries this Mac's device id", body(hello)?["id"] as? String == hostID)
    expect("hello route: id parses back", HostHello.parse(hello.body)?.id, hostID)
    expect("hello: invalid id is dropped", HostHello.parse(Data(#"{"app":"porthole","name":"m","version":1,"id":"x"}"#.utf8))?.id, nil)

    let req = routes.respond(to: get("/pair/request?device=\(viewerA)&name=Ren%C3%A9e%27s%20Air"))
    check("pair request: 200 says it was shown and names the host",
          req.status == "200 OK" && body(req)?["requested"] as? Bool == true && body(req)?["host"] as? String == "Mini")
    check("pair request: never reveals the code or the password", {
        let s = String(decoding: req.body, as: UTF8.self)
        return !s.contains("135790") && !s.contains("pw-123")
    }())
    check("pair request: the host is told who asked, with the code to show",
          requests.count == 1 && requests[0].0 == PairRequester(id: viewerA, name: "Renée's Air") && requests[0].1 == "135790")
    expect("pair request: the code is now active", desk.state(), .active(code: "135790", secondsLeft: 120))
    expect("pair request: a bad device id is 400", routes.respond(to: get("/pair/request?device=../x&name=a")).status, "400 Bad Request")
    expect("pair request: a missing device id is 400", routes.respond(to: get("/pair/request?name=a")).status, "400 Bad Request")
    expect("pair request: HEAD is refused", routes.respond(to: get("/pair/request?device=\(viewerA)", method: "HEAD")).status, "405 Method Not Allowed")
    expect("pair request: POST is refused like every other route", routes.respond(to: get("/pair/request?device=\(viewerA)", method: "POST")).status,
           "405 Method Not Allowed")
    let noTrust = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, pairing: desk)
    expect("pair request: without a trust store it does not exist",
           noTrust.respond(to: get("/pair/request?device=\(viewerA)")).status, "404 Not Found")

    let other = routes.respond(to: get("/pair?code=135790&device=\(viewerB)&name=Thief"))
    check("pair: the right code from another Mac is refused", other.status == "403 Forbidden" && body(other)?["secret"] == nil)
    expect("pair: a bad device id is 400 and burns no try", routes.respond(to: get("/pair?code=135790&device=XYZ")).status, "400 Bad Request")
    let ok = routes.respond(to: get("/pair?code=135%20790&device=\(viewerA)&name=Air"))
    let secret = body(ok)?["secret"] as? String ?? ""
    check("pair: the requester gets a device secret, the host's id and name",
          ok.status == "200 OK" && secret.count >= 32 && body(ok)?["host_id"] as? String == hostID && body(ok)?["host"] as? String == "Mini")
    check("pair: a device pairing never hands out the password",
          body(ok)?["password"] == nil && !String(decoding: ok.body, as: UTF8.self).contains("pw-123"))
    expect("pair: the host stored the device under its name", store.devices().map(\.name), ["Air"])
    expect("pair: the parsed reply", parsePairReply(status: 200, body: ok.body), .paired(secret: secret, hostID: hostID, hostName: "Mini"))

    let tok = routes.respond(to: get("/token?device=\(viewerA)&secret=\(secret)&name=air"))
    let tokClaims = (body(tok)?["token"] as? String).flatMap(claims)
    check("token: a paired device needs no password", tok.status == "200 OK")
    expect("token: identity carries the device id", tokClaims?["sub"] as? String, "view-air-sfx.\(viewerA)")
    let bad = routes.respond(to: get("/token?device=\(viewerA)&secret=nope"))
    check("token: a wrong device secret is 403 marked unpaired",
          bad.status == "403 Forbidden" && body(bad)?["unpaired"] as? Bool == true)
    expect("token reply: unpaired is recognised", parseTokenReply(status: 403, body: bad.body),
           .unpaired("This Mac isn't paired with Mini any more. Pair it again."))
    expect("token: the shared password still works", routes.respond(to: get("/token?pw=pw-123")).status, "200 OK")
    expect("token: the browser's wrong password reply is unchanged", String(decoding: routes.respond(to: get("/token?pw=x")).body, as: UTF8.self),
           #"{"error":"wrong password"}"#)
    _ = store.unpair(viewerA)
    let after = routes.respond(to: get("/token?device=\(viewerA)&secret=\(secret)"))
    check("token: after unpairing the device is refused at once", after.status == "403 Forbidden" && body(after)?["unpaired"] as? Bool == true)

    _ = desk.issue()
    let legacy = routes.respond(to: get("/pair?code=135790"))
    check("pair: without a device id the code is refused and the password never sent",
          legacy.status == "400 Bad Request" && !String(decoding: legacy.body, as: UTF8.self).contains("pw-123"))
    check("pair: that refusal burned nothing", desk.state() == .active(code: "135790", secondsLeft: 120))
    let busy = routes.respond(to: get("/pair/request?device=\(viewerB)&name=B"))
    check("pair request: another Mac's pending code is not replaced (409)",
          busy.status == "409 Conflict" && desk.state() == .active(code: "135790", secondsLeft: 120))
    desk.cancel()

    var statuses: [String] = []
    for i in 0..<7 {
        desk.cancel()
        statuses.append(routes.respond(to: get("/pair/request?device=\(i % 2 == 0 ? viewerA : viewerB)")).status)
    }
    expect("pair request: flooding is answered with 429", statuses.last, "429 Too Many Requests")

    let token = (body(routes.respond(to: get("/token?pw=pw-123")))?["token"] as? String).flatMap(claims)
    check("token: viewer tokens last 10 minutes", {
        guard let exp = token?["exp"] as? Int, let iat = token?["iat"] as? Int else { return false }
        return exp - iat == 600
    }())
}

private func localRouteTests() {
    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TrustStore(directory: dir)
    _ = store.pair(id: viewerA, name: "Air", secret: "s")
    _ = store.pair(id: viewerB, name: "Studio", secret: "t")
    let desk = PairingDesk(random: { 246_802 })
    var routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, pairing: desk, hostName: "Mini",
                           trust: store, hostID: hostID)
    var gone: [PairedDevice] = []
    routes.onUnpair = { gone.append($0) }
    let local = String(repeating: "k", count: 43)
    routes.localSecret = local
    let header = "\(localRouteHeader): \(local)"

    let okCode = routes.respond(to: get("/local/paircode", host: "127.0.0.1:7878", extra: [header]), fromLoopback: true)
    check("local paircode: loopback with the header gets a fresh code",
          okCode.status == "200 OK" && body(okCode)?["code"] as? String == "246802" && body(okCode)?["seconds"] as? Int == 120)
    expect("local paircode: that code is live", desk.state(), .active(code: "246802", secondsLeft: 120))
    desk.cancel()
    _ = desk.request(from: PairRequester(id: viewerB, name: "Studio"))
    let waiting = routes.respond(to: get("/local/paircode", host: "localhost:7878", extra: [header]), fromLoopback: true)
    check("local paircode: names the Mac that is waiting", body(waiting)?["for"] as? String == "Studio" && body(waiting)?["device"] as? String == viewerB)
    let denied: [(String, String, [String], Bool)] = [
        ("from the network", "127.0.0.1:7878", [header], false),
        ("without the header", "127.0.0.1:7878", [], true),
        ("with the old fixed header value", "127.0.0.1:7878", ["\(localRouteHeader): 1"], true),
        ("with a wrong local secret", "127.0.0.1:7878", ["\(localRouteHeader): " + String(repeating: "j", count: 43)], true),
        ("with another Host (DNS rebinding)", "evil.example:7878", [header], true),
        ("to the Tailscale address", "100.101.102.103:7878", [header], true),
    ]
    for (why, host, extra, loop) in denied {
        let r = routes.respond(to: get("/local/paircode", host: host, extra: extra), fromLoopback: loop)
        check("local paircode: \(why) is a plain 404", r.status == "404 Not Found" && !String(decoding: r.body, as: UTF8.self).contains("code"))
    }
    expect("local paircode: HEAD is refused", routes.respond(to: get("/local/paircode", method: "HEAD", host: "127.0.0.1", extra: [header]),
                                                             fromLoopback: true).status, "405 Method Not Allowed")
    check("pair window: shown by default", showsPairingWindow(environment: [:]))
    check("pair window: PORTHOLE_PAIR_HEADLESS=1 only prints the code", !showsPairingWindow(environment: ["PORTHOLE_PAIR_HEADLESS": "1"]))
    check("pair window: other values still show it", showsPairingWindow(environment: ["PORTHOLE_PAIR_HEADLESS": "0"]))
    expect("local host header: [::1] counts", isLocalHostHeader("[::1]:7878"), true)
    expect("local host header: a LAN name does not", isLocalHostHeader("mini.local"), false)

    let un = routes.respond(to: get("/local/unpair?who=air", host: "127.0.0.1:7878", extra: [header]), fromLoopback: true)
    check("local unpair: by name removes it and reports it",
          un.status == "200 OK" && body(un)?["id"] as? String == viewerA && body(un)?["name"] as? String == "Air")
    expect("local unpair: the host is told so it can disconnect the viewer", gone.map(\.id), [viewerA])
    check("local unpair: the device is gone", !store.isPaired(viewerA) && store.isPaired(viewerB))
    let miss = routes.respond(to: get("/local/unpair?who=nobody", host: "127.0.0.1", extra: [header]), fromLoopback: true)
    check("local unpair: no match is 404 with a message", miss.status == "404 Not Found" && (body(miss)?["error"] as? String)?.contains("nobody") == true)
    let remote = routes.respond(to: get("/local/unpair?who=studio", host: "127.0.0.1", extra: [header]), fromLoopback: false)
    check("local unpair: refused from the network", remote.status == "404 Not Found" && store.isPaired(viewerB))
    _ = store.pair(id: "0123000000000000", name: "Studio", secret: "u")
    let amb = routes.respond(to: get("/local/unpair?who=Studio", host: "127.0.0.1", extra: [header]), fromLoopback: true)
    check("local unpair: two Macs with the name is 409 listing both",
          amb.status == "409 Conflict" && (body(amb)?["matches"] as? [[String: String]])?.count == 2 && store.devices().count == 2)
    expect("local URL: always 127.0.0.1 with the port", localURL(port: 7999, path: "/local/unpair", ["who": "Renée's Air"])?.absoluteString,
           "http://127.0.0.1:7999/local/unpair?who=Ren%C3%A9e's%20Air")
}

private func viewerSideTests() {
    expect("token URL: device credential", tokenURL(hostAddress: "mini:9000", credential: .device(id: viewerA, secret: "a+b/c"), name: "air")?.absoluteString,
           "http://mini:9000/token?device=0123456789abcdef&secret=a%2Bb/c&name=air")
    expect("token URL: password credential is the old URL", tokenURL(hostAddress: "mini", credential: .password("p w"), name: "air"),
           tokenURL(hostAddress: "mini", password: "p w", name: "air"))
    expect("pair request URL", pairRequestURL(hostAddress: "100.101.102.103", device: viewerA, name: "Air")?.absoluteString,
           "http://100.101.102.103:7878/pair/request?device=0123456789abcdef&name=Air")
    expect("pair URL: with this Mac's device", pairURL(hostAddress: "mini", code: "123 456", device: viewerA, name: "Air")?.absoluteString,
           "http://mini:7878/pair?code=123456&device=0123456789abcdef&name=Air")
    expect("pair request URL: bad address", pairRequestURL(hostAddress: "mini:x", device: viewerA, name: "a"), nil)

    expect("pair reply: secret without a host id", parsePairReply(status: 200, body: Data(#"{"secret":"s"}"#.utf8)), .paired(secret: "s", hostID: nil, hostName: nil))
    expect("pair reply: invalid host id is dropped", parsePairReply(status: 200, body: Data(#"{"secret":"s","host_id":"../x","host":"M"}"#.utf8)),
           .paired(secret: "s", hostID: nil, hostName: "M"))
    expect("pair reply: an old host's password still parses", parsePairReply(status: 200, body: Data(#"{"password":"p"}"#.utf8)), .password("p"))

    expect("pair request reply: shown", parsePairRequestReply(status: 200, body: Data(#"{"requested":true,"host":"Mini"}"#.utf8)), .shown(host: "Mini"))
    expect("pair request reply: 404 is an older host", parsePairRequestReply(status: 404, body: Data("not found".utf8)), .older)
    expect("pair request reply: 429 passes the message", parsePairRequestReply(status: 429, body: Data(#"{"error":"Too many"}"#.utf8)), .refused("Too many"))
    expect("pair request reply: anything else", parsePairRequestReply(status: 500, body: Data()), .refused("The host didn't take the pairing request (HTTP 500)."))

    expect("token reply: ok", parseTokenReply(status: 200, body: Data(#"{"url":"ws://m:7880","token":"t"}"#.utf8)), .ok(url: "ws://m:7880", token: "t"))
    expect("token reply: wrong password", parseTokenReply(status: 403, body: Data(#"{"error":"wrong password"}"#.utf8)),
           .refused("The host refused the password, or isn't running."))
    expect("token reply: not JSON", parseTokenReply(status: 502, body: Data("x".utf8)), .refused("The host refused the password, or isn't running."))

    var t = ViewerTrust()
    t.remember(id: hostID, name: "Mini", address: "100.101.102.103")
    expect("viewer trust: found by address", t.host(forAddress: "100.101.102.103:7878")?.id, hostID)
    expect("viewer trust: address match ignores case and default port", ViewerTrust(hosts: [PairedHost(id: "x", name: "m", addresses: ["Mini.local"])])
           .host(forAddress: "mini.local:7878")?.id, "x")
    t.remember(id: hostID, name: "Mini", address: "mini.local")
    expect("viewer trust: a second address is added, newest first", t.hosts.first?.addresses, ["mini.local", "100.101.102.103"])
    t.remember(id: hostID, name: "Mini", address: "mini.local")
    expect("viewer trust: the same address is not duplicated", t.hosts.first?.addresses, ["mini.local", "100.101.102.103"])
    t.remember(id: "1111222233334444", name: "New", address: "mini.local")
    expect("viewer trust: an address moves to the Mac that now answers there", t.host(forAddress: "mini.local")?.id, "1111222233334444")
    expect("viewer trust: the old Mac keeps its other address", t.host(forAddress: "100.101.102.103")?.id, hostID)
    let byID = DiscoveredHost(name: "Mini", lanHost: "other.local", status: .online, hostID: hostID)
    expect("viewer trust: an advertised host id alone never earns the secret", t.host(for: byID), nil)
    let byAddr = DiscoveredHost(name: "x", tailscaleIP: "100.101.102.103", status: .online)
    expect("viewer trust: or by any of its addresses", t.host(for: byAddr)?.id, hostID)
    expect("viewer trust: unknown host", t.host(for: DiscoveredHost(name: "y", lanHost: "y.local", status: .online)), nil)
    expect("viewer trust: encodes and decodes", ViewerTrust.decode(t.encoded), t)
    expect("viewer trust: nothing stored is empty", ViewerTrust.decode(nil), ViewerTrust())
    t.forget(id: hostID)
    expect("viewer trust: forget", t.host(forAddress: "100.101.102.103"), nil)
    expect("trust key: host id when known", hostKeyForTrust(hostID: hostID, address: "m"), hostID)
    expect("trust key: address otherwise", hostKeyForTrust(hostID: nil, address: "Mini.local"), "addr:mini.local:7878")

    let txt = BonjourTXT.make(name: "m", tailscaleIP: nil, localHost: "m.local", id: hostID)
    expect("bonjour TXT: carries the device id", txt["id"], hostID)
    expect("bonjour TXT: invalid id is left out", BonjourTXT.make(name: "m", tailscaleIP: nil, localHost: "m.local", id: "x")["id"], nil)
    expect("bonjour host: id is read back", BonjourTXT.host(serviceName: "s", txt: txt)?.hostID, hostID)
    let merged = mergeHosts([DiscoveredHost(name: "Mini", lanHost: "mini.local", status: .online, viaBonjour: true, hostID: hostID),
                             DiscoveredHost(name: "mini-ts", tailscaleIP: "100.1.2.3", status: .online, viaTailscale: true, hostID: hostID)])
    expect("merge: a shared device id alone does not merge two sightings", merged.count, 2)
    let split = mergeHosts([DiscoveredHost(name: "Mac", tailscaleIP: "100.1.2.3", status: .online, hostID: hostID),
                            DiscoveredHost(name: "Mac", tailscaleIP: "100.1.2.3", status: .online, hostID: "1111222233334444")])
    expect("merge: different device ids stay apart", split.count, 2)
}

private func commandTests() {
    let host: [([String], HostPairCommand)] = [
        ([], .app), (["-psn_0_12345"], .app), (["-NSDocumentRevisionsDebugMode", "YES"], .app),
        (["paircode"], .paircode), (["devices"], .devices), (["unpair", "Renée's", "Air"], .unpair("Renée's Air")),
        (["unpair", viewerA], .unpair(viewerA)), (["unpair"], .usage(error: "unpair needs a name or device ID")),
        (["unpair", "  "], .usage(error: "unpair needs a name or device ID")),
        (["paircode", "x"], .usage(error: "paircode takes no arguments")), (["devices", "x"], .usage(error: "devices takes no arguments")),
        (["--help"], .usage(error: nil)), (["help"], .usage(error: nil)),
    ]
    for (args, want) in host { expect("host command: \(args)", hostPairCommand(args), want) }
    check("host usage: names every command", ["paircode", "devices", "unpair"].allSatisfy { hostUsage.contains($0) })

    let viewer: [([String], ViewerCommand)] = [
        ([], .app), (["mini"], .app), (["mini", "secret-pw"], .app), (["-psn_0_1"], .app),
        (["request", "mini"], .request(host: "mini")), (["request"], .usage(error: "request needs a host")),
        (["pair", "mini", "123 456"], .pair(host: "mini", code: "123456")), (["pair", "mini", "123-456"], .pair(host: "mini", code: "123456")),
        (["pair", "mini"], .usage(error: "pair needs a host and a code")),
        (["pair", "mini", "hunter2"], .usage(error: "\"hunter2\" isn't a 6-digit pairing code")),
        (["--help"], .usage(error: nil)),
    ]
    for (args, want) in viewer { expect("viewer command: \(args)", viewerCommand(args), want) }
    expect("viewer command: pair with extra words is left to the app", viewerCommand(["pair", "a", "123456", "x"]), .app)
}

private func budgetTests() {
    let t0 = Date(timeIntervalSince1970: 200_000)
    var b = GuessBudget()
    for _ in 0..<9 { b.wrongGuess(now: t0) }
    expect("budget: nine wrong guesses do not pause", b.secondsPaused(now: t0), nil)
    b.wrongGuess(now: t0)
    expect("budget: the tenth pauses pairing for a minute", b.secondsPaused(now: t0), 60)
    expect("budget: the pause ends", b.secondsPaused(now: t0.addingTimeInterval(60)), nil)
    var pauses: [Int] = []
    for i in 0..<14 {
        let at = t0.addingTimeInterval(Double(i) * 200_000)
        for _ in 0..<GuessBudget.wrongPerPause { b.wrongGuess(now: at) }
        pauses.append(b.secondsPaused(now: at) ?? 0)
    }
    expect("budget: each pause doubles, up to a day", pauses,
           [120, 240, 480, 960, 1920, 3840, 7680, 15360, 30720, 61440, 86400, 86400, 86400, 86400])
    b.paired()
    expect("budget: a real pairing resets it", b, GuessBudget())
    var worst = GuessBudget()
    var guesses = 0
    var now = t0
    let month = t0.addingTimeInterval(30 * 86_400)
    while now < month {
        if let p = worst.secondsPaused(now: now) { now = now.addingTimeInterval(Double(p)); continue }
        worst.wrongGuess(now: now); guesses += 1
    }
    check("budget: a month of nonstop guessing gets at most 400 tries (\(guesses), at most 0.04% of the codes)", guesses <= 400)

    let c = "cccccccccccccccc"
    var codes = PairingCodes()
    _ = codes.request(from: PairRequester(id: viewerA, name: "A"), now: t0, random: { 123_456 })
    for _ in 0..<4 { _ = codes.redeem("000000", device: viewerA, now: t0) }
    codes.cancel()
    _ = codes.request(from: PairRequester(id: viewerB, name: "B"), now: t0, random: { 123_456 })
    for _ in 0..<4 { _ = codes.redeem("000000", device: viewerB, now: t0) }
    codes.cancel()
    _ = codes.request(from: PairRequester(id: c, name: "C"), now: t0, random: { 123_456 })
    _ = codes.redeem("000000", device: c, now: t0)
    expect("budget: wrong guesses add up across requested codes", codes.redeem("000000", device: c, now: t0), .wrong(left: 3))
    expect("budget: when paused even the right requested code is refused", codes.redeem("123456", device: c, now: t0), .paused(seconds: 60))
    expect("budget: a paused try does not burn the code", codes.state(now: t0), .active(code: "123456", secondsLeft: 120))
    expect("budget: after the pause the right code works", codes.redeem("123456", device: c, now: t0.addingTimeInterval(60)), .accepted)
    expect("pair message: paused", pairMessage(.paused(seconds: 61)), "Too many wrong codes on this host. Pairing is paused for 2 minutes.")

    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("pairing-budget.json")
    let desk = PairingDesk(clock: { t0 }, random: { 5 }, budgetFile: file)
    for who in [viewerA, viewerB] {
        _ = desk.request(from: PairRequester(id: who, name: "x"))
        for _ in 0..<PairingCodes.maxWrongTries { _ = desk.redeem("999999", device: who) }
    }
    expect("budget file: written 0600", mode(file), 0o600)
    let restarted = PairingDesk(clock: { t0.addingTimeInterval(10) }, random: { 5 }, budgetFile: file)
    expect("budget file: a restarted host still refuses remote requests",
           restarted.request(from: PairRequester(id: c, name: "C")), .paused(seconds: 50))
    expect("budget: garbage file starts fresh", GuessBudget.decode(Data("x".utf8)), GuessBudget())
    expect("budget: encode round trip", GuessBudget.decode(restarted.budget.encoded), restarted.budget)
    _ = restarted.issue()
    expect("budget file: the owner's new code clears the pause on disk",
           GuessBudget.decode(try? Data(contentsOf: file)).secondsPaused(now: t0.addingTimeInterval(10)), nil)
    expect("budget file: and that code pairs at once", restarted.redeem("000005", device: c), .accepted)

    var revoked = RevokedDevices()
    let ident = pairedIdentity(name: "air", suffix: "s", device: viewerA)
    check("revoked: a paired viewer's messages count", revoked.accepts(ident, isPaired: { _ in false }))
    revoked.revoke(viewerA)
    check("revoked: after unpairing its messages are ignored", !revoked.accepts(ident, isPaired: { _ in false }))
    check("revoked: password viewers are unaffected", revoked.accepts("view-browser-abcd", isPaired: { _ in false }))
    check("revoked: other devices are unaffected", revoked.accepts(pairedIdentity(name: "b", suffix: "s", device: viewerB), isPaired: { _ in false }))
    check("revoked: pairing again lifts it", revoked.accepts(ident, isPaired: { $0 == viewerA }) && revoked.ids.isEmpty)

    let sdir = tempDir()
    defer { try? FileManager.default.removeItem(at: sdir) }
    expect("local secret: none before the host runs", LocalSecret.read(in: sdir), nil)
    let made = LocalSecret.create(in: sdir)
    check("local secret: long and random", (made?.count ?? 0) >= 40 && made != LocalSecret.create(in: tempDir()))
    expect("local secret: the CLI reads what the host wrote", LocalSecret.read(in: sdir), made)
    expect("local secret: file is 0600", mode(sdir.appendingPathComponent(LocalSecret.fileName)), 0o600)
    _ = LocalSecret.create(in: sdir, secret: "short")
    expect("local secret: a short value is not trusted", LocalSecret.read(in: sdir), nil)
}

private func pausedCodes(_ t0: Date) -> PairingCodes {
    var codes = PairingCodes()
    let ids = ["1111111111111111", "2222222222222222", "3333333333333333"]
    for id in ids.prefix(2) {
        _ = codes.request(from: PairRequester(id: id, name: "x"), now: t0, random: { 424_242 })
        for _ in 0..<PairingCodes.maxWrongTries { _ = codes.redeem("000000", device: id, now: t0) }
    }
    return codes
}

private func lockoutTests() {
    let t0 = Date(timeIntervalSince1970: 300_000)
    let a = PairRequester(id: viewerA, name: "Air")
    let b = PairRequester(id: viewerB, name: "Studio")

    var attacked = pausedCodes(t0)
    expect("lockout: ten wrong guesses pause remote requests", attacked.request(from: a, now: t0, random: { 1 }), .paused(seconds: 60))
    expect("lockout: a paused request issues no code", attacked.state(now: t0), .locked)
    expect("lockout: the owner's menu code is issued while paused", attacked.issue(now: t0, random: { 777_000 }), "777000")
    expect("lockout: the owner's code clears the pause", attacked.budget.secondsPaused(now: t0), nil)
    expect("lockout: the owner's code clears the strikes", attacked.budget.strikes, 0)
    check("lockout: the escalation count is kept for the next attacker", attacked.budget.pauses == 1)
    expect("lockout: the owner's code pairs at once", attacked.redeem("777000", device: viewerA, now: t0), .accepted)

    var hammered = pausedCodes(t0)
    _ = hammered.issue(now: t0, random: { 555_000 })
    for _ in 0..<4 { _ = hammered.redeem("000000", device: viewerB, now: t0) }
    hammered.budget.pausedUntil = t0.addingTimeInterval(86_400)
    expect("lockout: an owner code is never refused by the pause", hammered.redeem("555000", device: viewerA, now: t0), .accepted)

    var cli = pausedCodes(t0)
    expect("lockout: porthole-host paircode issues a code while paused", cli.currentOrIssue(now: t0, random: { 808_080 }), "808080")
    expect("lockout: porthole-host paircode clears the pause", cli.budget.secondsPaused(now: t0), nil)
    expect("lockout: the paircode code pairs", cli.redeem("808080", device: viewerB, now: t0), .accepted)

    var requested = PairingCodes()
    _ = requested.request(from: a, now: t0, random: { 919_191 })
    requested.budget.pausedUntil = t0.addingTimeInterval(600)
    expect("lockout: a requested code is subject to the pause", requested.redeem("919191", device: viewerA, now: t0), .paused(seconds: 600))
    expect("lockout: paircode shows that pending code and lifts the pause for it",
           requested.currentOrIssue(now: t0, random: { 1 }), "919191")
    expect("lockout: then the requester pairs", requested.redeem("919191", device: viewerA, now: t0), .accepted)

    var stranger = PairingCodes()
    _ = stranger.request(from: a, now: t0, random: { 343_434 })
    for _ in 0..<50 { _ = stranger.redeem("000000", device: viewerB, now: t0) }
    expect("lockout: fifty guesses from another Mac leave the budget alone", stranger.budget, GuessBudget())
    expect("lockout: and do not lock the requester's code", stranger.state(now: t0), .active(code: "343434", secondsLeft: 120))
    expect("lockout: the requester still pairs", stranger.redeem("343434", device: viewerA, now: t0), .accepted)

    var flood = PairingCodes()
    var mine: [PairingCodes.RequestOutcome] = []
    for i in 0..<4 {
        mine.append(flood.request(from: a, now: t0.addingTimeInterval(Double(i)), random: { UInt32(i) }))
        flood.cancel()
    }
    expect("per-device limit: one Mac gets at most 3 codes per 10 minutes", mine.last, .throttled)
    check("per-device limit: its first 3 were issued", mine.prefix(3).allSatisfy { if case .issued = $0 { return true }; return false })
    expect("per-device limit: another Mac can still ask", flood.request(from: b, now: t0.addingTimeInterval(5), random: { 9 }), .issued("000009"))
    flood.cancel()
    expect("per-device limit: the Mac may ask again after 10 minutes",
           flood.request(from: a, now: t0.addingTimeInterval(PairingCodes.requestWindow), random: { 8 }), .issued("000008"))

    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var clock = t0
    let desk = PairingDesk(clock: { clock }, random: { 246_246 })
    let routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, pairing: desk, hostName: "Mini",
                           trust: TrustStore(directory: dir))
    _ = routes.respond(to: get("/pair/request?device=\(viewerA)&name=A"))
    let busy = routes.respond(to: get("/pair/request?device=\(viewerB)&name=B"))
    expect("busy reply: tells the owner how to get past it", body(busy)?["error"] as? String,
           "Another Mac is pairing with Mini right now. Try again in 120 s, or choose Pair a New Viewer… on the host and enter that code.")
    let before = desk.budget
    let foreign = routes.respond(to: get("/pair?code=246246&device=\(viewerB)&name=B"))
    check("pair route: another Mac's guess is refused", foreign.status == "403 Forbidden" && body(foreign)?["secret"] == nil)
    expect("pair route: another Mac's guess leaves the budget alone", desk.budget, before)
    desk.cancel()
    for who in ["1111111111111111", "2222222222222222"] {
        _ = desk.request(from: PairRequester(id: who, name: "x"))
        for _ in 0..<PairingCodes.maxWrongTries { _ = desk.redeem("000000", device: who) }
    }
    clock = t0.addingTimeInterval(1)
    let paused = routes.respond(to: get("/pair/request?device=\(viewerA)&name=A"))
    check("paused request route: 429 that names the way out", paused.status == "429 Too Many Requests"
          && body(paused)?["error"] as? String == "Too many wrong codes on Mini. Pairing requests are paused for 1 minute, or choose Pair a New Viewer… on the host and enter that code.")
    _ = desk.issue()
    let owner = routes.respond(to: get("/pair?code=246246&device=\(viewerB)&name=B"))
    check("pair route: the owner's menu code works while remote requests are paused", owner.status == "200 OK" && body(owner)?["secret"] != nil)

    expect("token auth: right password", authorizeToken(query: ["pw": "pw-123"], password: "pw-123", verify: { _, _ in nil }), .password)
    expect("token auth: a longer password is refused", authorizeToken(query: ["pw": "pw-1234"], password: "pw-123", verify: { _, _ in nil }), .refused)
    expect("token auth: same length, wrong password", authorizeToken(query: ["pw": "pw-124"], password: "pw-123", verify: { _, _ in nil }), .refused)
    expect("token auth: device with the password fallback",
           authorizeToken(query: ["device": viewerA, "pw": "pw-123"], password: "pw-123", verify: { _, _ in nil }), .password)
    expect("token auth: device with a wrong password fallback",
           authorizeToken(query: ["device": viewerA, "pw": "pw-12"], password: "pw-123", verify: { _, _ in nil }), .unpaired)

    expect("remove retry: success stops", removeRetryDelay(status: 200, attempt: 1), nil)
    expect("remove retry: already gone stops", removeRetryDelay(status: 404, attempt: 1), nil)
    expect("remove retry: no answer retries soon", removeRetryDelay(status: nil, attempt: 1), 0.5)
    expect("remove retry: server error backs off", removeRetryDelay(status: 500, attempt: 3), 2)
    expect("remove retry: gives up after 5 tries", removeRetryDelay(status: 500, attempt: 5), nil)

    expect("reconnect: a lost connection retries after 1 s", reconnectDelay(after: .lost, attempt: 1), 1)
    expect("reconnect: backs off to 30 s", reconnectDelay(after: .lost, attempt: 6), 30)
    expect("reconnect: gives up after the last delay", reconnectDelay(after: .lost, attempt: reconnectDelays.count + 1), nil)
    check("reconnect: keeps trying for over 2 minutes after a wake", reconnectDelays.reduce(0, +) >= 120)
    for kind in [DisconnectKind.byViewer, .removed, .replaced, .roomGone] {
        expect("reconnect: never after \(kind)", reconnectDelay(after: kind, attempt: 1), nil)
    }
    expect("viewer tokens: still 10 minutes", WebRoutes.viewerTokenTTL, 600)
    expect("reconnect attempts: the first drop is attempt 1", nextReconnectAttempt(previous: 0, upFor: nil), 1)
    expect("reconnect attempts: a drop within 30 s of reconnecting keeps counting", nextReconnectAttempt(previous: 3, upFor: 5), 4)
    expect("reconnect attempts: just under 30 s still counts", nextReconnectAttempt(previous: 3, upFor: 29.9), 4)
    expect("reconnect attempts: a connection that stayed up 30 s starts over", nextReconnectAttempt(previous: 7, upFor: 30), 1)
    var flaps = 0
    var n = 0
    while true {
        n = nextReconnectAttempt(previous: n, upFor: 2)
        guard reconnectDelay(after: .lost, attempt: n) != nil else { break }
        flaps += 1
    }
    expect("reconnect attempts: a connection that drops right after every reconnect gives up", flaps, reconnectDelays.count)
}

private func privateFileTests() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent(LocalSecret.fileName)
    FileManager.default.createFile(atPath: url.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])
    let made = LocalSecret.create(in: dir)
    expect("private file: replacing a 0644 file leaves it 0600", mode(url), 0o600)
    expect("private file: the new secret is what is read back", LocalSecret.read(in: dir), made)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    expect("private file: no temporary files are left behind", left, [LocalSecret.fileName])
    let blocked = dir.appendingPathComponent("not-a-dir")
    FileManager.default.createFile(atPath: blocked.path, contents: Data())
    expect("private file: a failed write reports failure", LocalSecret.create(in: blocked), nil)

    let store = TrustStore(directory: dir)
    _ = store.pair(id: viewerA, name: "Air", secret: "s1")
    let reads = store.fileReads
    for _ in 0..<100 { _ = store.isPaired(viewerA) }
    expect("trust cache: a hundred checks read the file at most once", store.fileReads - reads <= 1, true)
    let other = TrustStore(directory: dir)
    _ = other.unpair(viewerA)
    check("trust cache: a change written by another store is seen", !store.isPaired(viewerA))
    _ = store.pair(id: viewerB, name: "Studio", secret: "s2")
    check("trust cache: its own writes are seen at once", store.isPaired(viewerB) && store.verify(id: viewerB, secret: "s2") != nil)
    var revoked = RevokedDevices()
    revoked.revoke(viewerA)
    let ident = pairedIdentity(name: "air", suffix: "s", device: viewerA)
    let before = store.fileReads
    for _ in 0..<200 { _ = revoked.accepts(ident, isPaired: store.isPaired) }
    expect("revoked: messages from a revoked Mac do not re-read the trust file", store.fileReads - before <= 1, true)
}
