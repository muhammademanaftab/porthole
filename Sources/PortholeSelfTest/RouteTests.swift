import Foundation
import PortholeCore

func routeTests() {
    routeModeTests()
    addressScopeTests()
    routeSightingTests()
    routeCandidateTests()
    routeClassifyTests()
    routeTrustTests()
    let yaml = liveKitConfigYAML(port: 7880, apiKey: "k", apiSecret: "s")
    check("livekit config: binds every interface so ICE offers LAN and Tailscale host candidates", yaml.contains("bind_addresses:\n  - \"\""))
    check("livekit config: no STUN lookup of a public IP", yaml.contains("use_external_ip: false"))
    expect("signaling route: a LAN address", signalingRoute(address: "10.0.1.52:7878"), RouteInfo(kind: .sameNetwork, address: "10.0.1.52"))
    expect("signaling route: the Tailscale address", signalingRoute(address: "100.101.102.103")?.text, "Tailscale (100.101.102.103)")
    expect("signaling route: a .local name", signalingRoute(address: "Mini.local")?.kind, .sameNetwork)
    expect("signaling route: nothing for a bad address", signalingRoute(address: ""), nil)
    expect("hello URL: plain", helloURL(hostAddress: "10.0.1.52")?.absoluteString, "http://10.0.1.52:7878/hello")
    expect("hello URL: custom port", helloURL(hostAddress: "mini.local:9000")?.absoluteString, "http://mini.local:9000/hello")
}

func routeTrustTests() {
    var t = ViewerTrust()
    t.remember(id: routeHostID, name: "Mac mini", address: "100.101.102.103")
    t.remember(id: "fedcba9876543210", name: "Other", address: "10.0.1.52")
    expect("viewer trust: addresses of a paired host", t.addresses(of: routeHostID), ["100.101.102.103"])
    expect("viewer trust: addresses of nobody", t.addresses(of: nil), [])
    expect("viewer trust: another host's LAN pairing is untouched by routing", t.host(forAddress: "10.0.1.52")?.id, "fedcba9876543210")
}

func routeModeTests() {
    expect("route mode: nothing stored means automatic", RouteMode.setting(nil), .auto)
    expect("route mode: stored local", RouteMode.setting("local"), .local)
    expect("route mode: stored tailscale", RouteMode.setting("tailscale"), .tailscale)
    expect("route mode: junk means automatic", RouteMode.setting("sideways"), .auto)
    expect("route mode: a stored non-string means automatic", RouteMode.setting(3), .auto)
    expect("route mode: parse accepts friendly words", ["Automatic", "LAN", "same-network", "TS", " tailscale "].map(RouteMode.parse),
           [.auto, .local, .local, .tailscale, .tailscale])
    expect("route mode: PORTHOLE_ROUTE wins over the setting", RouteMode.effective(setting: .auto, environment: ["PORTHOLE_ROUTE": "tailscale"]), .tailscale)
    expect("route mode: PORTHOLE_ROUTE=local", RouteMode.effective(setting: .tailscale, environment: ["PORTHOLE_ROUTE": "local"]), .local)
    expect("route mode: an unknown PORTHOLE_ROUTE keeps the setting", RouteMode.effective(setting: .local, environment: ["PORTHOLE_ROUTE": "x"]), .local)
    expect("route mode: no env keeps the setting", RouteMode.effective(setting: .local, environment: [:]), .local)
    expect("route mode: labels", RouteMode.allCases.map(\.label), ["Automatic", "Same network only", "Tailscale only"])
    let none = ViewerSettings(lookup: { _ in nil })
    expect("viewer settings: route is automatic by default", none.route, .auto)
    let ts = ViewerSettings(lookup: { $0 == "connection.route" ? "tailscale" : nil })
    expect("viewer settings: route read from connection.route", ts.route, .tailscale)
    expect("viewer settings: route stored under connection.route", (ts.stored["connection.route"] ?? nil) as? String, "tailscale")
    check("env flags: PORTHOLE_ROUTE is documented for the viewer", EnvFlags.all.contains { $0.name == "PORTHOLE_ROUTE" && $0.scope == "viewer" })
    check("env flags: porthole env lists PORTHOLE_ROUTE with its value",
          EnvFlags.render(EnvFlags.rows(environment: ["PORTHOLE_ROUTE": "local"], setOnly: true)).contains("PORTHOLE_ROUTE  local"))
}

func addressScopeTests() {
    let cases: [(String, AddressScope)] = [
        ("10.0.1.52", .local), ("192.168.1.20", .local), ("172.16.0.1", .local), ("172.31.255.255", .local),
        ("172.32.0.1", .other), ("172.15.0.1", .other), ("169.254.3.4", .local), ("Leos-Mac-mini.local", .local),
        ("mini.local.", .local), ("100.101.102.103", .tailscale), ("100.64.0.1", .tailscale), ("100.127.255.255", .tailscale),
        ("100.128.0.1", .other), ("100.63.255.255", .other), ("mini.tail1234.ts.net", .tailscale),
        ("fd7a:115c:a1e0::1234", .tailscale), ("[fd7a:115c:a1e0:ab12::1]", .tailscale), ("fd7a:115c:a1e1::1", .local),
        ("fe80::1%en0", .local), ("fd00::5", .local), ("2001:4860:4860::8888", .other), ("8.8.8.8", .other),
        ("127.0.0.1", .loopback), ("::1", .loopback), ("localhost", .loopback), ("::ffff:10.0.0.2", .local),
        ("example.com", .other), ("", .other),
    ]
    for (host, scope) in cases { expect("address scope: \(host)", addressScope(host), scope) }
}

let routeHostID = "0123456789abcdef"

func routeSightingTests() {
    var mini = BonjourTXT.host(serviceName: "mini", txt: BonjourTXT.make(name: "Mac mini", tailscaleIP: "100.101.102.103",
                                                                       localHost: "Leos-Mac-mini.local", id: routeHostID, lanIP: "10.0.1.52"))!
    expect("bonjour TXT: the LAN IP is advertised", BonjourTXT.make(name: "m", tailscaleIP: nil, localHost: nil, lanIP: "10.0.1.52")["ip"], "10.0.1.52")
    expect("bonjour TXT: a public IP is not advertised as LAN", BonjourTXT.make(name: "m", tailscaleIP: nil, localHost: nil, lanIP: "8.8.8.8")["ip"], nil)
    expect("bonjour host: the LAN IP is read back", mini.lanIP, "10.0.1.52")
    expect("bonjour host: a non-LAN ip in TXT is ignored", BonjourTXT.host(serviceName: "s", txt: ["v": "1", "host": "a.local", "ip": "100.101.102.103"])?.lanIP, nil)
    check("bonjour host: an ip alone is enough", BonjourTXT.host(serviceName: "s", txt: ["v": "1", "ip": "10.0.0.3"]) != nil)
    let other = BonjourTXT.host(serviceName: "other", txt: BonjourTXT.make(name: "Other", tailscaleIP: "100.70.0.9", localHost: "other.local",
                                                                         id: "fedcba9876543210", lanIP: "10.0.1.60"))!

    let seen = RoutePlan.sightings(of: routeHostID, in: [other, mini])
    expect("route sightings: the paired host by ID, only its LAN IP literal", seen.map(\.address), ["10.0.1.52"])
    check("route sightings: carry the host ID and its Tailscale IP", seen.allSatisfy { $0.id == routeHostID && $0.tailscaleIP == "100.101.102.103" })
    expect("route sightings: another host's ID is never used", RoutePlan.sightings(of: "aaaaaaaaaaaaaaaa", in: [other, mini]), [])
    expect("route sightings: without a paired ID nothing is used", RoutePlan.sightings(of: nil, in: [other, mini]), [])
    expect("route sightings: an addr: trust key counts as no ID", RoutePlan.sightings(of: "addr:100.101.102.103:7878", in: [mini]), [])
    expect("route sightings: a host with an IP needs no name lookup", RoutePlan.namesToResolve(of: routeHostID, in: [mini]), [])
    var nameOnly = BonjourTXT.host(serviceName: "mini", txt: BonjourTXT.make(name: "Mac mini", tailscaleIP: nil, localHost: "Leos-Mac-mini.local", id: routeHostID))!
    expect("route sightings: only a .local name is looked up once", RoutePlan.namesToResolve(of: routeHostID, in: [nameOnly]), ["leos-mac-mini.local"])
    expect("route sightings: an unresolved .local name is never used as an address", RoutePlan.sightings(of: routeHostID, in: [nameOnly]), [])
    expect("route sightings: the resolved IP literal is used instead of the name",
           RoutePlan.sightings(of: routeHostID, in: [nameOnly], resolved: ["leos-mac-mini.local": "10.0.1.52"]).map(\.address), ["10.0.1.52"])
    expect("route sightings: a resolved address that isn't on this network is dropped",
           RoutePlan.sightings(of: routeHostID, in: [nameOnly], resolved: ["leos-mac-mini.local": "8.8.8.8"]), [])
    nameOnly.port = 9000
    expect("route sightings: a resolved IPv6 keeps brackets and port",
           RoutePlan.sightings(of: routeHostID, in: [nameOnly], resolved: ["leos-mac-mini.local": "fe80::1"]).map(\.address), ["[fe80::1]:9000"])
    mini.port = 9000
    expect("route sightings: a custom port is kept", RoutePlan.sightings(of: routeHostID, in: [mini]).first?.address, "10.0.1.52:9000")
    var saved = mini
    saved.viaBonjour = false
    expect("route sightings: only live Bonjour results count", RoutePlan.sightings(of: routeHostID, in: [saved]), [])
    check("ip literal: IPv4, IPv6 and bracketed", isIPLiteral("10.0.0.1") && isIPLiteral("fe80::1") && isIPLiteral("[fd00::1]"))
    check("ip literal: names are not", !isIPLiteral("mini.local") && !isIPLiteral("localhost") && !isIPLiteral(""))
}

func routeCandidateTests() {
    let lan = [LocalSighting(address: "10.0.1.52", id: routeHostID, tailscaleIP: "100.101.102.103"),
               LocalSighting(address: "[fe80::1]", id: routeHostID, tailscaleIP: "100.101.102.103")]
    let auto = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: routeHostID, local: lan, known: ["100.101.102.103"])
    expect("route plan auto: LAN IPv4, then LAN IPv6, then the saved Tailscale address", auto.map(\.address),
           ["10.0.1.52", "[fe80::1]", "100.101.102.103"])
    expect("route plan auto: short budgets for the LAN tries, 10 s for the last", auto.map(\.budget), [1.5, 1.5, 10])
    expect("route plan auto: the paired host ID is expected everywhere", auto.map(\.expectedID), [routeHostID, routeHostID, routeHostID])
    expect("route plan auto: LAN tries must prove themselves, the saved Tailscale address needn't", auto.map(\.mustProve), [true, true, false])
    expect("route plan auto: LAN tries are challenged, the saved Tailscale address isn't", auto.map(\.shouldChallenge), [true, true, false])
    expect("route plan auto: only the saved Tailscale address is trusted without a proof", auto.map(\.trustedWithoutProof), [false, false, true])
    expect("route plan auto: scopes", auto.map(\.scope), [.local, .local, .tailscale])

    let away = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: routeHostID, local: [], known: ["100.101.102.103"])
    expect("route plan auto away from home: only the saved address", away,
           [RouteCandidate(address: "100.101.102.103", scope: .tailscale, budget: 10, expectedID: routeHostID, saved: true)])

    let savedLAN = RoutePlan.candidates(mode: .auto, saved: "10.0.1.52", hostID: routeHostID, local: [], known: ["10.0.1.52", "100.101.102.103"])
    expect("route plan auto: a saved LAN address falls back to the known Tailscale address", savedLAN.map(\.address), ["10.0.1.52", "100.101.102.103"])
    expect("route plan auto: the saved LAN address gets the short budget", savedLAN.map(\.budget), [1.5, 10])
    check("route plan auto: a saved LAN address is challenged but may still be tried", savedLAN[0].shouldChallenge && !savedLAN[0].mustProve && !savedLAN[0].trustedWithoutProof)
    check("route plan auto: the known Tailscale address must prove itself", savedLAN[1].mustProve)

    let dup = RoutePlan.candidates(mode: .auto, saved: "10.0.1.52", hostID: routeHostID, local: lan, known: [])
    expect("route plan: the saved address is not tried twice", dup.map { "\($0.address) \($0.saved)" },
           ["10.0.1.52 true", "[fe80::1] false", "100.101.102.103 false"])
    expect("route plan: the Tailscale IP seen in Bonjour is used after the LAN tries", dup.map(\.budget), [1.5, 1.5, 10])

    let pwOnly = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: nil, local: [LocalSighting(address: "10.0.1.52", id: "fedcba9876543210")], known: [])
    expect("route plan: without a paired ID only the saved address is tried", pwOnly.map(\.address), ["100.101.102.103"])
    let pwSaved = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: routeHostID, local: lan, known: ["100.101.102.103"], savedOnly: true)
    expect("route plan: a password viewer only ever uses the saved address", pwSaved.map(\.address), ["100.101.102.103"])
    expect("route plan: a password viewer in Same network only mode with a Tailscale address has nothing to try",
           RoutePlan.candidates(mode: .local, saved: "100.101.102.103", hostID: nil, local: lan, known: [], savedOnly: true), [])
    expect("route plan: known MagicDNS names are not tried as fallbacks (no IP to prove)",
           RoutePlan.candidates(mode: .auto, saved: "10.0.1.52", hostID: routeHostID, local: [], known: ["mini.tail1.ts.net"]).map(\.address), ["10.0.1.52"])

    let local = RoutePlan.candidates(mode: .local, saved: "100.101.102.103", hostID: routeHostID, local: lan, known: ["100.101.102.103"])
    expect("route plan same network only: LAN addresses, never Tailscale", local.map(\.address), ["10.0.1.52", "[fe80::1]"])
    expect("route plan same network only: the last try has 10 s", local.map(\.budget), [1.5, 10])
    expect("route plan same network only, away: nothing to try",
           RoutePlan.candidates(mode: .local, saved: "100.101.102.103", hostID: routeHostID, local: [], known: []), [])
    expect("route plan same network only: a saved LAN address is kept",
           RoutePlan.candidates(mode: .local, saved: "mini.local", hostID: nil, local: [], known: []).map(\.address), ["mini.local"])
    let loop = RoutePlan.candidates(mode: .local, saved: "127.0.0.1", hostID: nil, local: [], known: [])
    check("route plan: a saved loopback address is trusted without a challenge", loop[0].trustedWithoutProof && !loop[0].shouldChallenge)

    let ts = RoutePlan.candidates(mode: .tailscale, saved: "100.101.102.103", hostID: routeHostID, local: lan, known: [])
    expect("route plan Tailscale only: the saved Tailscale address, no LAN", ts.map(\.address), ["100.101.102.103"])
    let tsFromLAN = RoutePlan.candidates(mode: .tailscale, saved: "10.0.1.52", hostID: routeHostID, local: [], known: ["10.0.1.52", "100.101.102.103"])
    expect("route plan Tailscale only: a saved LAN address is swapped for the known Tailscale one", tsFromLAN.map(\.address), ["100.101.102.103"])
    check("route plan Tailscale only: that address must prove itself", tsFromLAN[0].mustProve)
    expect("route plan Tailscale only: MagicDNS names count",
           RoutePlan.candidates(mode: .tailscale, saved: "mini.tail1.ts.net", hostID: nil, local: [], known: []).map(\.address), ["mini.tail1.ts.net"])
    expect("route plan Tailscale only: nothing known means nothing to try",
           RoutePlan.candidates(mode: .tailscale, saved: "10.0.1.52", hostID: nil, local: [], known: []), [])
    expect("route plan: a bad saved address gives nothing", RoutePlan.candidates(mode: .auto, saved: "", hostID: nil, local: lan, known: []), [])
    let custom = RoutePlan.candidates(mode: .auto, saved: "10.0.1.52:9000", hostID: routeHostID,
                                      local: [LocalSighting(address: "10.0.1.53:9000", id: routeHostID, tailscaleIP: "100.101.102.103")], known: [])
    expect("route plan: the Bonjour Tailscale IP keeps the saved port", custom.map(\.address), ["10.0.1.53:9000", "10.0.1.52:9000", "100.101.102.103:9000"])

    check("route plan: a refusal from a proven host stops the plan", RoutePlan.stops(status: 403, confirmed: true) && RoutePlan.stops(status: 401, confirmed: true))
    check("route plan: a refusal from an unproven host doesn't", !RoutePlan.stops(status: 403, confirmed: false))
    check("route plan: 404 and 5xx never stop it", !RoutePlan.stops(status: 404, confirmed: true) && !RoutePlan.stops(status: 503, confirmed: true))
    check("route plan: the no-route message names the setting", RoutePlan.noRouteMessage(mode: .local, hostName: "Mac mini").contains("Same network only"))
    helloProofTests()
}

func helloProofTests() {
    let secret = "s3cret-pairing"
    let device = ViewerCredential.device(id: "1111222233334444", secret: secret)
    let pw = ViewerCredential.password("hunter2")
    let nonce = HelloProof.makeNonce()
    check("hello proof: nonce is 32 lowercase hex", HelloProof.isValidNonce(nonce))
    check("hello proof: nonces differ", nonce != HelloProof.makeNonce())
    check("hello proof: bad nonces are refused", !HelloProof.isValidNonce("abc") && !HelloProof.isValidNonce(String(repeating: "G", count: 32)))
    expect("hello proof: device key is the secret's digest, as the host stores it", HelloProof.viewerKey(device), HelloProof.deviceKey(secretHash: secretDigest(secret)))
    expect("hello proof: a password is never a proof key", HelloProof.viewerKey(pw), nil)
    let known = HelloProof.proof(key: Data("k".utf8), nonce: String(repeating: "a", count: 32), hostID: routeHostID, address: "10.0.1.52")
    expect("hello proof: HMAC-SHA256 hex", known.count, 64)
    expect("hello proof: same inputs give the same proof", known,
           HelloProof.proof(key: Data("k".utf8), nonce: String(repeating: "a", count: 32), hostID: routeHostID, address: "[10.0.1.52]"))
    check("hello proof: the address is part of the proof", known != HelloProof.proof(key: Data("k".utf8), nonce: String(repeating: "a", count: 32), hostID: routeHostID, address: "10.0.1.53"))
    expect("hello proof: device query", HelloProof.url(hostAddress: "10.0.1.52", credential: device, nonce: nonce)?.absoluteString,
           "http://10.0.1.52:7878/hello?device=1111222233334444&nonce=\(nonce)")
    expect("hello proof: a password viewer never sends a challenge", HelloProof.url(hostAddress: "10.0.1.52", credential: pw, nonce: nonce), nil)

    let devices = ["1111222233334444": secretDigest(secret)]
    let mine: (String) -> Bool = { ["10.0.1.52", "leos-mac-mini.local", "localhost"].contains($0) }
    func ask(_ q: [String: String], header: String = "10.0.1.52:7878") -> String? {
        HelloProof.answer(query: q, hostHeader: header, hostID: routeHostID, secretHash: { devices[$0] }, ownsAddress: mine)
    }
    let deviceProof = ask(["device": "1111222233334444", "nonce": nonce])
    check("hello proof: a paired device's proof verifies", HelloProof.verify(deviceProof, key: HelloProof.viewerKey(device), nonce: nonce, hostID: routeHostID, address: "10.0.1.52"))
    check("hello proof: it doesn't verify for another nonce",
          !HelloProof.verify(deviceProof, key: HelloProof.viewerKey(device), nonce: HelloProof.makeNonce(), hostID: routeHostID, address: "10.0.1.52"))
    check("hello proof: it doesn't verify for another host ID",
          !HelloProof.verify(deviceProof, key: HelloProof.viewerKey(device), nonce: nonce, hostID: "fedcba9876543210", address: "10.0.1.52"))
    check("hello proof: it doesn't verify with another secret",
          !HelloProof.verify(deviceProof, key: HelloProof.viewerKey(.device(id: "1111222233334444", secret: "x")), nonce: nonce, hostID: routeHostID, address: "10.0.1.52"))
    let viaName = ask(["device": "1111222233334444", "nonce": nonce], header: "Leos-Mac-mini.local:7878")
    check("hello proof: asked on the .local name, even an address the host claims, the proof is refused",
          !HelloProof.verify(viaName, key: HelloProof.viewerKey(device), nonce: nonce, hostID: routeHostID, address: "Leos-Mac-mini.local"))
    let viaLocalhost = ask(["device": "1111222233334444", "nonce": nonce], header: "localhost:7878")
    check("hello proof: asked on localhost, the proof is refused",
          !HelloProof.verify(viaLocalhost, key: HelloProof.viewerKey(device), nonce: nonce, hostID: routeHostID, address: "localhost"))
    check("hello proof: a real proof for a name never verifies on the viewer",
          !HelloProof.verify(HelloProof.proof(key: HelloProof.viewerKey(device)!, nonce: nonce, hostID: routeHostID, address: "mini.local"),
                             key: HelloProof.viewerKey(device), nonce: nonce, hostID: routeHostID, address: "mini.local"))
    let unknownDevice = ask(["device": "9999888877776666", "nonce": nonce])
    check("hello proof: an unpaired device gets a proof that never verifies", unknownDevice?.count == 64
          && !HelloProof.verify(unknownDevice, key: HelloProof.viewerKey(device), nonce: nonce, hostID: routeHostID, address: "10.0.1.52"))
    let relayed = ask(["device": "1111222233334444", "nonce": nonce], header: "10.0.1.99:7878")
    check("hello proof: a request relayed through another address gets no usable proof",
          !HelloProof.verify(relayed, key: HelloProof.viewerKey(device), nonce: nonce, hostID: routeHostID, address: "10.0.1.99"))
    expect("hello proof: a password challenge gets no proof at all", ask(["pw": "0", "nonce": nonce]), nil)
    expect("hello proof: plain /hello gets no proof", ask([:]), nil)
    expect("hello proof: a bad nonce gets no proof", ask(["device": "1111222233334444", "nonce": "zz"]), nil)

    let body = { (proof: String?, id: String?) -> Data in
        var o: [String: Any] = ["app": "porthole", "name": "Mac mini", "version": 1]
        if let id { o["id"] = id }
        if let proof { o["proof"] = proof }
        return try! JSONSerialization.data(withJSONObject: o)
    }
    let mini = HostHello(name: "Mac mini", version: 1, id: routeHostID)
    let other = HostHello(name: "Mac mini", version: 1, id: "fedcba9876543210")
    expect("hello check: a good proof confirms",
           HelloProof.check(status: 200, body: body(deviceProof, routeHostID), credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.52"), .confirmed(mini))
    expect("hello check: a password viewer is never confirmed",
           HelloProof.check(status: 200, body: body(deviceProof, routeHostID), credential: pw, nonce: nonce, expectedID: nil, address: "10.0.1.52"), .unconfirmed(mini))
    expect("hello check: the right ID without a proof is not enough",
           HelloProof.check(status: 200, body: body(nil, routeHostID), credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.52"), .unconfirmed(mini))
    let wrongHost = HelloProof.check(status: 200, body: body(deviceProof, "fedcba9876543210"), credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.52")
    expect("hello check: another host ID is refused before the proof", wrongHost, .unconfirmed(other))
    check("hello check: a valid /hello naming another host is flagged", HelloProof.namesOtherHost(wrongHost, expectedID: routeHostID))
    check("hello check: no answer is not another host", !HelloProof.namesOtherHost(.unconfirmed(nil), expectedID: routeHostID))
    check("hello check: an old host without an ID is not another host", !HelloProof.namesOtherHost(.unconfirmed(HostHello(name: "m", version: 1)), expectedID: routeHostID))
    check("hello check: nothing expected, nothing flagged", !HelloProof.namesOtherHost(.unconfirmed(other), expectedID: nil))
    check("hello check: a confirmed answer is not another host", !HelloProof.namesOtherHost(.confirmed(mini), expectedID: routeHostID))
    expect("hello check: a proof made for another address is refused",
           HelloProof.check(status: 200, body: body(deviceProof, routeHostID), credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.60"), .unconfirmed(mini))
    expect("hello check: no answer", HelloProof.check(status: nil, body: nil, credential: device, nonce: nonce, expectedID: routeHostID, address: "x"), .unconfirmed(nil))
    expect("hello check: a 302 is no answer", HelloProof.check(status: 302, body: body(deviceProof, routeHostID), credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.52"), .unconfirmed(nil))
    passwordThrottleTests()
    helloRouteTests()
}

func passwordThrottleTests() {
    var now = Date(timeIntervalSince1970: 1_000)
    let t = PasswordThrottle(clock: { now })
    for _ in 0..<(GuessBudget.wrongPerPause - 1) { t.failed("10.0.0.9") }
    expect("password throttle: nine wrong passwords don't pause", t.secondsPaused("10.0.0.9"), nil)
    t.failed("10.0.0.9")
    expect("password throttle: the tenth pauses that source for a minute", t.secondsPaused("10.0.0.9"), 60)
    expect("password throttle: another source isn't paused", t.secondsPaused("10.0.0.10"), nil)
    now = now.addingTimeInterval(61)
    expect("password throttle: the pause runs out", t.secondsPaused("10.0.0.9"), nil)
    for _ in 0..<GuessBudget.wrongPerPause { t.failed("10.0.0.9") }
    expect("password throttle: the next pause is twice as long", t.secondsPaused("10.0.0.9"), 120)
    t.failed("10.0.0.11")
    t.succeeded("10.0.0.11")
    for _ in 0..<(GuessBudget.wrongPerPause - 1) { t.failed("10.0.0.11") }
    expect("password throttle: the right password clears the strikes", t.secondsPaused("10.0.0.11"), nil)

    var routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: AccessToken(apiKey: "k", apiSecret: "s"), webRoot: nil, hostName: "Mini")
    routes.passwordThrottle = PasswordThrottle()
    func token(_ pw: String, from source: String) -> HTTPResponse {
        routes.respond(to: "GET /token?pw=\(pw) HTTP/1.1\r\nHost: 10.0.1.52:7878\r\n\r\n", source: source)
    }
    for _ in 0..<GuessBudget.wrongPerPause { _ = token("nope", from: "10.0.0.9") }
    let paused = token("pw-123", from: "10.0.0.9")
    check("token route: after ten wrong passwords that source gets 429, even with the right one",
          paused.status == "429 Too Many Requests" && (json(paused.body)?["error"] as? String)?.contains("Too many wrong passwords") == true)
    expect("token route: another source still gets a token", token("pw-123", from: "10.0.0.10").status, "200 OK")
    expect("token route: a share link isn't throttled by passwords",
           routes.respond(to: "GET /token?share=x HTTP/1.1\r\nHost: m\r\n\r\n", source: "10.0.0.9").status != "429 Too Many Requests", true)
}

func helloRouteTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-hello-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let trust = TrustStore(directory: dir)
    guard let secret = trust.pair(id: "1111222233334444", name: "Air") else { check("hello route: pairing for the test", false); return }
    var routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: AccessToken(apiKey: "k", apiSecret: "s"), webRoot: nil,
                           hostName: "Mini", trust: trust, hostID: routeHostID)
    routes.ownsAddress = { $0 == "10.0.1.52" }
    let mini = HostHello(name: "Mini", version: portholeProtocolVersion, id: routeHostID)
    func get(_ path: String, host: String = "10.0.1.52:7878") -> HTTPResponse {
        routes.respond(to: "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n")
    }
    let plain = get("/hello")
    check("hello route: plain /hello still answers old viewers, without a proof",
          plain.status == "200 OK" && HostHello.parse(plain.body)?.id == routeHostID && json(plain.body)?["proof"] == nil)
    let nonce = HelloProof.makeNonce()
    let device = ViewerCredential.device(id: "1111222233334444", secret: secret)
    let answer = get("/hello?device=1111222233334444&nonce=\(nonce)")
    expect("hello route: a paired device gets a proof it can check",
           HelloProof.check(status: 200, body: answer.body, credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.52"), .confirmed(mini))
    let pwAnswer = get("/hello?pw=0&nonce=\(nonce)")
    check("hello route: a password challenge gets a plain /hello with no proof",
          pwAnswer.status == "200 OK" && HostHello.parse(pwAnswer.body)?.id == routeHostID && json(pwAnswer.body)?["proof"] == nil)
    let foreign = get("/hello?device=1111222233334444&nonce=\(nonce)", host: "10.0.1.99:7878")
    check("hello route: asked through an address that isn't the host's, the proof is useless",
          HelloProof.check(status: 200, body: foreign.body, credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.99") != .confirmed(mini))
    routes.ownsAddress = nil
    let noOwner = get("/hello?device=1111222233334444&nonce=\(nonce)")
    check("hello route: without an address list nothing is proven",
          HelloProof.check(status: 200, body: noOwner.body, credential: device, nonce: nonce, expectedID: routeHostID, address: "10.0.1.52") != .confirmed(mini))
}

func routeClassifyTests() {
    expect("route: a LAN host candidate is the same network", classifyRoute(remoteAddress: "10.0.1.52", remoteType: "host", localType: "host"), .sameNetwork)
    expect("route: link-local is the same network", classifyRoute(remoteAddress: "fe80::1", remoteType: "host", localType: "host"), .sameNetwork)
    expect("route: a .local name is the same network", classifyRoute(remoteAddress: "abc.local", remoteType: "host", localType: "host"), .sameNetwork)
    expect("route: a Tailscale IPv4 is Tailscale", classifyRoute(remoteAddress: "100.101.102.103", remoteType: "host", localType: "host"), .tailscale)
    expect("route: a Tailscale IPv6 is Tailscale", classifyRoute(remoteAddress: "fd7a:115c:a1e0::9", remoteType: "host", localType: "prflx"), .tailscale)
    expect("route: a relay candidate is relayed", classifyRoute(remoteAddress: "10.0.1.52", remoteType: "relay", localType: "host"), .relayed)
    expect("route: a local relay candidate is relayed", classifyRoute(remoteAddress: "100.101.102.103", remoteType: "host", localType: "relay"), .relayed)
    expect("route: a public address is the internet", classifyRoute(remoteAddress: "84.2.1.9", remoteType: "srflx", localType: "srflx"), .internet)
    expect("route: loopback is this Mac", classifyRoute(remoteAddress: "127.0.0.1", remoteType: "host", localType: "host"), .thisMac)

    let status = TailscaleStatus.parse(Data("""
    {"BackendState":"Running","TailscaleIPs":["100.70.0.2"],"Peer":{
      "a":{"HostName":"mini","DNSName":"mini.tail.ts.net.","OS":"macOS","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::aa"],"Online":true,"CurAddr":"","Relay":"fra"},
      "b":{"HostName":"air","DNSName":"air.tail.ts.net.","OS":"macOS","TailscaleIPs":["100.80.1.1"],"Online":true,"CurAddr":"84.2.1.9:41641","Relay":"fra"}}}
    """.utf8))
    check("tailscale status: CurAddr and Relay are read", status?.peer(withIP: "100.101.102.103")?.relay == "fra" && status?.peer(withIP: "100.80.1.1")?.curAddr == "84.2.1.9:41641")
    expect("tailscale status: a peer is found by its IPv6", status?.peer(withIP: "fd7a:115c:a1e0::aa")?.hostName, "mini")
    expect("tailscale status: an unknown IP has no peer", status?.peer(withIP: "100.1.1.1")?.hostName, nil)
    expect("route: Tailscale through DERP is a Tailscale relay",
           classifyRoute(remoteAddress: "100.101.102.103", remoteType: "host", localType: "host", tailscale: status), .tailscaleRelay)
    expect("route: Tailscale with a direct CurAddr stays Tailscale",
           classifyRoute(remoteAddress: "100.80.1.1", remoteType: "host", localType: "host", tailscale: status), .tailscale)
    expect("route: a 100.64/10 address that isn't a tailnet peer is not Tailscale",
           classifyRoute(remoteAddress: "100.64.9.9", remoteType: "host", localType: "host", tailscale: status), .internet)
    expect("route: without a Tailscale status a 100.64/10 address is called Tailscale",
           classifyRoute(remoteAddress: "100.64.9.9", remoteType: "host", localType: "host"), .tailscale)
    expect("route: a tailnet peer by IPv6", classifyRoute(remoteAddress: "fd7a:115c:a1e0::aa", remoteType: "host", localType: "host", tailscale: status), .tailscaleRelay)
    expect("route: global IPv6 host to host on the same /64 is the same network",
           classifyRoute(remoteAddress: "2a01:4f8:1:2::52", remoteType: "host", localType: "host", localAddress: "2a01:4f8:1:2:aaaa::9"), .sameNetwork)
    expect("route: global IPv6 on another /64 is the internet",
           classifyRoute(remoteAddress: "2a01:4f8:1:2::52", remoteType: "host", localType: "host", localAddress: "2a01:4f8:1:3::9"), .internet)
    expect("route: same /64 through a server-reflexive candidate is not called the same network",
           classifyRoute(remoteAddress: "2a01:4f8:1:2::52", remoteType: "srflx", localType: "host", localAddress: "2a01:4f8:1:2::9"), .internet)
    check("route: IPv4-mapped addresses are not compared as a /64", !sameIPv6Subnet("::ffff:8.8.8.8", "::ffff:8.8.4.4"))
    expect("route info: the local candidate's address is used for the /64 check",
           routeInfo(remote: IceCandidateFacts(address: "2a01:4f8:1:2::52", type: "host"), local: IceCandidateFacts(address: "2a01:4f8:1:2::9", type: "host"))?.kind, .sameNetwork)
    check("tailscale status: older JSON without CurAddr still parses", TailscaleStatus.parse(Data(#"{"BackendState":"Running","Peer":{"a":{"HostName":"m","TailscaleIPs":["100.64.0.5"]}}}"#.utf8))?.peers.first?.isRelayed == false)

    let info = routeInfo(remote: IceCandidateFacts(address: "10.0.1.52", type: "host"), local: IceCandidateFacts(address: "10.0.1.40", type: "host"))
    expect("route info: text names the kind and the host's address", info?.text, "Same network (10.0.1.52)")
    expect("route info: menu title", info?.menuTitle, "Connection: Same network (10.0.1.52)")
    expect("route info: brackets and zones are dropped", routeInfo(remote: IceCandidateFacts(address: "[fe80::1%en0]", type: "host"), local: nil)?.address, "fe80::1")
    expect("route info: no remote candidate yet", routeInfo(remote: nil, local: nil), nil)
    expect("route info: an empty address is not a route", routeInfo(remote: IceCandidateFacts(address: "", type: "host"), local: nil), nil)
    expect("route info: kind labels", [RouteKind.sameNetwork, .tailscale, .tailscaleRelay, .relayed, .internet].map(\.label),
           ["Same network", "Tailscale", "Tailscale relay", "Relayed", "Internet"])
    expect("route info: text without an address", RouteInfo(kind: .relayed, address: nil).text, "Relayed")
}
