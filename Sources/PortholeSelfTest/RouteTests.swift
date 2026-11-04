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
    t.learn(id: routeHostID, address: "10.0.1.52")
    expect("viewer trust: a confirmed LAN address is added after the saved one", t.addresses(of: routeHostID), ["100.101.102.103", "10.0.1.52"])
    expect("viewer trust: the LAN address finds the same pairing", t.host(forAddress: "10.0.1.52")?.id, routeHostID)
    expect("viewer trust: the Tailscale address still finds it", t.host(forAddress: "100.101.102.103:7878")?.id, routeHostID)
    expect("viewer trust: a host left with no address is dropped", t.hosts.map(\.id), [routeHostID])
    t.learn(id: routeHostID, address: "10.0.1.52:7878")
    expect("viewer trust: learning an address twice keeps one", t.addresses(of: routeHostID), ["100.101.102.103", "10.0.1.52"])
    t.learn(id: "aaaaaaaaaaaaaaaa", address: "10.0.0.9")
    expect("viewer trust: an unknown host learns nothing", t.hosts.count, 1)
    expect("viewer trust: addresses of nobody", t.addresses(of: nil), [])
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

    let seen = RoutePlan.sightings(of: routeHostID, saved: "100.101.102.103", in: [other, mini])
    expect("route sightings: the paired host by ID, LAN IP first, then its .local name", seen.map(\.address), ["10.0.1.52", "Leos-Mac-mini.local"])
    check("route sightings: carry the host ID and its Tailscale IP", seen.allSatisfy { $0.id == routeHostID && $0.tailscaleIP == "100.101.102.103" })
    expect("route sightings: another host's ID is never used", RoutePlan.sightings(of: "aaaaaaaaaaaaaaaa", saved: "100.101.102.103", in: [other, mini]), [])
    expect("route sightings: without an ID, the Tailscale IP in TXT matches",
           RoutePlan.sightings(of: nil, saved: "100.101.102.103", in: [other, mini]).map(\.address), ["10.0.1.52", "Leos-Mac-mini.local"])
    expect("route sightings: an addr: trust key counts as no ID",
           RoutePlan.sightings(of: "addr:100.101.102.103:7878", saved: "100.101.102.103", in: [mini]).map(\.id), [routeHostID, routeHostID])
    mini.port = 9000
    expect("route sightings: a custom port is kept", RoutePlan.sightings(of: routeHostID, saved: "100.101.102.103", in: [mini]).first?.address, "10.0.1.52:9000")
    var saved = mini
    saved.viaBonjour = false
    expect("route sightings: only live Bonjour results count", RoutePlan.sightings(of: routeHostID, saved: "x", in: [saved]), [])
}

func routeCandidateTests() {
    let lan = [LocalSighting(address: "10.0.1.52", id: routeHostID, tailscaleIP: "100.101.102.103"),
               LocalSighting(address: "Leos-Mac-mini.local", id: routeHostID, tailscaleIP: "100.101.102.103")]
    let auto = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: routeHostID, local: lan, known: ["100.101.102.103"])
    expect("route plan auto: LAN first, then .local, then the saved Tailscale address", auto.map(\.address),
           ["10.0.1.52", "Leos-Mac-mini.local", "100.101.102.103"])
    expect("route plan auto: short budgets for the LAN tries, none for the last", auto.map(\.budget), [1.5, 1.5, nil])
    expect("route plan auto: LAN tries confirm the host ID by /hello, the saved address doesn't", auto.map(\.expectedID), [routeHostID, routeHostID, nil])
    expect("route plan auto: scopes", auto.map(\.scope), [.local, .local, .tailscale])

    let away = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: routeHostID, local: [], known: ["100.101.102.103"])
    expect("route plan auto away from home: only the saved address", away, [RouteCandidate(address: "100.101.102.103", scope: .tailscale)])

    let savedLAN = RoutePlan.candidates(mode: .auto, saved: "10.0.1.52", hostID: routeHostID, local: [], known: ["10.0.1.52", "100.101.102.103"])
    expect("route plan auto: a saved LAN address falls back to the known Tailscale address", savedLAN.map(\.address), ["10.0.1.52", "100.101.102.103"])
    expect("route plan auto: the saved LAN address gets the short budget", savedLAN.map(\.budget), [1.5, nil])
    expect("route plan auto: the known Tailscale address is confirmed", savedLAN.last?.expectedID, routeHostID)

    let dup = RoutePlan.candidates(mode: .auto, saved: "10.0.1.52", hostID: routeHostID, local: lan, known: [])
    expect("route plan: the saved address is not tried twice, and needs no /hello", dup.map { "\($0.address) \($0.expectedID ?? "-")" },
           ["10.0.1.52 -", "Leos-Mac-mini.local \(routeHostID)", "100.101.102.103 \(routeHostID)"])
    expect("route plan: the Tailscale IP seen in Bonjour is used after the LAN tries", dup.map(\.budget), [1.5, 1.5, nil])

    let pwOnly = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: nil, local: [LocalSighting(address: "10.0.1.52", id: nil)], known: [])
    expect("route plan: a LAN address that can't be confirmed is skipped", pwOnly.map(\.address), ["100.101.102.103"])
    let pwID = RoutePlan.candidates(mode: .auto, saved: "100.101.102.103", hostID: nil, local: [LocalSighting(address: "10.0.1.52", id: routeHostID)], known: [])
    expect("route plan: without a paired ID the Bonjour ID is confirmed", pwID.map(\.expectedID), [routeHostID, nil])

    let local = RoutePlan.candidates(mode: .local, saved: "100.101.102.103", hostID: routeHostID, local: lan, known: ["100.101.102.103"])
    expect("route plan same network only: LAN addresses, never Tailscale", local.map(\.address), ["10.0.1.52", "Leos-Mac-mini.local"])
    expect("route plan same network only: the last try waits as long as it needs", local.map(\.budget), [1.5, nil])
    expect("route plan same network only, away: nothing to try",
           RoutePlan.candidates(mode: .local, saved: "100.101.102.103", hostID: routeHostID, local: [], known: []), [])
    expect("route plan same network only: a saved LAN address is kept",
           RoutePlan.candidates(mode: .local, saved: "mini.local", hostID: nil, local: [], known: []).map(\.address), ["mini.local"])

    let ts = RoutePlan.candidates(mode: .tailscale, saved: "100.101.102.103", hostID: routeHostID, local: lan, known: [])
    expect("route plan Tailscale only: the saved Tailscale address, no LAN", ts.map(\.address), ["100.101.102.103"])
    let tsFromLAN = RoutePlan.candidates(mode: .tailscale, saved: "10.0.1.52", hostID: routeHostID, local: [], known: ["10.0.1.52", "100.101.102.103"])
    expect("route plan Tailscale only: a saved LAN address is swapped for the known Tailscale one", tsFromLAN.map(\.address), ["100.101.102.103"])
    expect("route plan Tailscale only: MagicDNS names count",
           RoutePlan.candidates(mode: .tailscale, saved: "mini.tail1.ts.net", hostID: nil, local: [], known: []).map(\.address), ["mini.tail1.ts.net"])
    expect("route plan Tailscale only: nothing known means nothing to try",
           RoutePlan.candidates(mode: .tailscale, saved: "10.0.1.52", hostID: nil, local: [], known: []), [])
    expect("route plan: a bad saved address gives nothing", RoutePlan.candidates(mode: .auto, saved: "", hostID: nil, local: lan, known: []), [])
    let custom = RoutePlan.candidates(mode: .auto, saved: "10.0.1.52:9000", hostID: routeHostID,
                                      local: [LocalSighting(address: "mini.local:9000", id: routeHostID, tailscaleIP: "100.101.102.103")], known: [])
    expect("route plan: the Bonjour Tailscale IP keeps the saved port", custom.map(\.address), ["mini.local:9000", "10.0.1.52:9000", "100.101.102.103:9000"])

    check("route plan: /hello must name the expected host", RoutePlan.helloConfirms(HostHello(name: "m", version: 1, id: routeHostID), expectedID: routeHostID))
    check("route plan: a different host's /hello is refused", !RoutePlan.helloConfirms(HostHello(name: "m", version: 1, id: "fedcba9876543210"), expectedID: routeHostID))
    check("route plan: a /hello without an ID is refused", !RoutePlan.helloConfirms(HostHello(name: "m", version: 1), expectedID: routeHostID))
    check("route plan: no /hello is refused", !RoutePlan.helloConfirms(nil, expectedID: routeHostID))
    check("route plan: nothing expected needs no /hello", RoutePlan.helloConfirms(nil, expectedID: nil))
    check("route plan: the no-route message names the setting", RoutePlan.noRouteMessage(mode: .local, hostName: "Mac mini").contains("Same network only"))
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
    expect("route: a peer missing from the status stays Tailscale",
           classifyRoute(remoteAddress: "100.64.9.9", remoteType: "host", localType: "host", tailscale: status), .tailscale)
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
