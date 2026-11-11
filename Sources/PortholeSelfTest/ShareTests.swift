import Foundation
import PortholeCore

private func shareDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-share-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func req(_ target: String, host: String = "mini:7878", extra: [String] = []) -> String {
    "GET \(target) HTTP/1.1\r\nHost: \(host)\r\n" + extra.map { $0 + "\r\n" }.joined() + "\r\n"
}

private func claims(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3, let d = decodeBase64URL(String(parts[1])) else { return nil }
    return json(d)
}

private let safari = WindowInfo(id: 77, app: "Safari", title: "Apple", bundle: "com.apple.Safari", w: 800, h: 600)
private let notes = WindowInfo(id: 88, app: "Notes", title: "Secret plans", bundle: "com.apple.Notes", w: 600, h: 400)

func shareTests() {
    shareStoreTests()
    guestIdentityTests()
    guestAccessTests()
    controlSwitchTests()
    trackPlanTests()
    shareURLTests()
    shareRouteTests()
    shareCLITests()
}

private func shareStoreTests() {
    let dir = shareDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let store = ShareLinkStore(directory: dir, clock: { now })
    guard let made = store.mint(window: 77, label: "Safari — Apple", control: false) else { check("share store: mint works", false); return }
    check("share store: a minted link is view only by default here and lasts 24 h",
          !made.link.control && made.link.expires.timeIntervalSince(made.link.created) == 24 * 3600 && made.link.window == 77)
    check("share store: the token is long and random", made.token.count >= 32)
    check("share store: only a hash of the token is saved", {
        let file = String(decoding: (try? Data(contentsOf: dir.appendingPathComponent(ShareLinks.fileName))) ?? Data(), as: UTF8.self)
        return !file.contains(made.token) && file.contains(secretDigest(made.token))
    }())
    let mode = ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(ShareLinks.fileName).path))?[.posixPermissions] as? NSNumber)?.intValue
    expect("share store: share-links.json is 0600", mode, 0o600)
    expect("share store: the token verifies", store.verify(made.token)?.id, made.link.id)
    expect("share store: a wrong token doesn't", store.verify(made.token + "x"), nil)
    expect("share store: an empty token doesn't", store.verify(""), nil)
    expect("share store: the host password is not a token", store.verify("pw-123"), nil)
    let reread = ShareLinkStore(directory: dir, clock: { now })
    expect("share store: links survive a restart", reread.verify(made.token)?.id, made.link.id)
    now = now.addingTimeInterval(24 * 3600 - 1)
    check("share store: still live a second before 24 h", store.verify(made.token) != nil)
    now = now.addingTimeInterval(1)
    expect("share store: expired at 24 h", store.verify(made.token), nil)
    expect("share store: an expired link is gone by id", store.link(id: made.link.id), nil)
    expect("share store: the list drops expired links", store.links().count, 0)
    let short = store.mint(window: nil, label: "", control: true, ttl: 5)
    check("share store: a TTL under a minute is raised to a minute", short.map { $0.link.expires.timeIntervalSince($0.link.created) } == 60)
    check("share store: a picker link gets the picker label", short?.link.label == ShareLinks.pickerLabel && short?.link.isPicker == true)
    let nan = store.mint(window: nil, label: "x", control: false, ttl: Double.nan)
    check("share store: a NaN TTL falls back to the default", nan.map { $0.link.expires.timeIntervalSince($0.link.created) } == ShareLinks.defaultTTL)
    let long = store.mint(window: nil, label: "x", control: false, ttl: 365 * 86400)
    check("share store: a TTL is capped at 30 days", long.map { $0.link.expires.timeIntervalSince($0.link.created) } == 30 * 86400)
    guard let a = store.mint(window: 1, label: "A", control: false), let b = store.mint(window: 2, label: "B", control: false) else { return }
    check("share store: two links have different ids and tokens", a.link.id != b.link.id && a.token != b.token)
    expect("share store: revoke returns the link", store.revoke(id: a.link.id)?.id, a.link.id)
    expect("share store: a revoked token stops working at once", store.verify(a.token), nil)
    check("share store: the other link keeps working", store.verify(b.token) != nil)
    expect("share store: revoking an unknown id is nil", store.revoke(id: "deadbeef"), nil)
    check("share store: revoke all empties the list", store.revokeAll() >= 1 && store.links().isEmpty && store.verify(b.token) == nil)
    for i in 0..<(ShareLinks.maxLinks + 5) { _ = store.mint(window: UInt32(i), label: "w", control: false) }
    expect("share store: at most 50 live links are kept", store.links().count, ShareLinks.maxLinks)
    check("share store: link ids are 8 hex characters", store.links().allSatisfy { ShareLinks.isValidID($0.id) })
    expect("share store: a garbled file reads as no links", ShareLinks.decode(Data("{".utf8)), nil)
    expect("share labels: ttl choices read well", ShareLinks.ttlChoices.map(ShareLinks.ttlLabel), ["1 hour", "8 hours", "24 hours", "7 days"])
}

private func guestIdentityTests() {
    let id = GuestIdentity.make(link: "0a1b2c3d", client: "abc123def456")
    expect("guest identity: link and client", id, "guest-0a1b2c3d-abc123def456")
    expect("guest identity: the link id parses back", GuestIdentity.linkID(id), "0a1b2c3d")
    check("guest identity: is a guest", GuestIdentity.isGuest(id))
    check("guest identity: a bad client id is replaced", GuestIdentity.make(link: "0a1b2c3d", client: "../../x", random: { "zzzzzz" }) == "guest-0a1b2c3d-zzzzzz")
    check("guest identity: an uppercase client id is replaced", GuestIdentity.make(link: "0a1b2c3d", client: "ABCDEFGH", random: { "q1q1q1" }) == "guest-0a1b2c3d-q1q1q1")
    expect("guest identity: no device id can be read from it", deviceID(fromIdentity: id), nil)
    check("guest identity: viewer identities are never guests", !GuestIdentity.isGuest(WebRoutes.viewerIdentity(name: "guest-0a1b2c3d", suffix: "s"))
          && !GuestIdentity.isGuest(pairedIdentity(name: "guest", suffix: "s", device: "0123456789abcdef")) && !GuestIdentity.isGuest("host"))
    expect("guest identity: junk has no link id", GuestIdentity.linkID("guest-xyz"), nil)
    expect("guest identity: a viewer has no link id", GuestIdentity.linkID("view-browser-abc"), nil)
}

private func guestAccessTests() {
    let now = Date()
    let window = ShareLink(id: "0a1b2c3d", tokenHash: "h", window: 77, label: "Safari", control: false, created: now, expires: now + 60)
    let picker = ShareLink(id: "0a1b2c3e", tokenHash: "h", window: nil, label: "All", control: false, created: now, expires: now + 60)
    check("guest access: a view-only guest's typing is dropped", !GuestAccess.allows(.input(win: 77), link: window, controlling: false))
    check("guest access: a controlling guest's typing goes through", GuestAccess.allows(.input(win: 77), link: window, controlling: true))
    check("guest access: a window link opens its window", GuestAccess.allows(.open(win: 77, parent: nil), link: window, controlling: false))
    check("guest access: a window link can't open another window", !GuestAccess.allows(.open(win: 88, parent: nil), link: window, controlling: true))
    check("guest access: a window link opens that window's dialogs", GuestAccess.allows(.open(win: 99, parent: 77), link: window, controlling: false))
    check("guest access: but not another window's dialogs", !GuestAccess.allows(.open(win: 99, parent: 88), link: window, controlling: false))
    check("guest access: a picker link opens any window", GuestAccess.allows(.open(win: 88, parent: nil), link: picker, controlling: false))
    check("guest access: a window link gets no thumbnails", !GuestAccess.allows(.thumbnails, link: window, controlling: true))
    check("guest access: a picker link gets thumbnails", GuestAccess.allows(.thumbnails, link: picker, controlling: false))
    check("guest access: icons only for the granted window", GuestAccess.allows(.icon(win: 77), link: window, controlling: false)
          && !GuestAccess.allows(.icon(win: 88), link: window, controlling: false))
    check("guest access: no guest may restart the host", !GuestAccess.allows(.restart, link: picker, controlling: true))
    check("guest access: no guest may pair", !GuestAccess.allows(.pair, link: picker, controlling: true))
    check("guest access: no guest receives the host clipboard", !GuestAccess.allows(.clipboardToGuest, link: picker, controlling: true))
    check("guest access: a view-only guest can't set the host clipboard", !GuestAccess.allows(.clipboardFromGuest, link: picker, controlling: false))
    check("guest access: a controlling guest may paste", GuestAccess.allows(.clipboardFromGuest, link: picker, controlling: true))
    check("guest access: anyone may list, close and ask", [GuestRequest.list, .close, .ask].allSatisfy { GuestAccess.allows($0, link: window, controlling: false) })
    expect("guest access: a window link lists only its window", GuestAccess.visible([safari, notes], link: window).map(\.id), [77])
    expect("guest access: a picker link lists every window", GuestAccess.visible([safari, notes], link: picker).map(\.id), [77, 88])
    expect("guest access: a closed shared window lists nothing", GuestAccess.visible([notes], link: window).map(\.id), [])
    let screen = WholeMac.windowID(screen: 0) ?? 0
    check("guest access: Whole Mac is never a guest's, even on a picker link", !GuestAccess.allows(.open(win: screen, parent: nil), link: picker, controlling: true)
          && !GuestAccess.allows(.input(win: screen), link: picker, controlling: true) && !GuestAccess.allows(.icon(win: screen), link: picker, controlling: true))
    expect("guest access: a guest's list never carries Whole Mac entries", GuestAccess.visible([WindowInfo(id: screen, app: "Whole Mac", title: "Main", bundle: nil, w: 1, h: 1), safari],
                                                                                         link: picker).map(\.id), [77])
    expect("guest access: whole-mac sees a guest as neither paired nor password", WholeMac.viewer(GuestIdentity.make(link: "0a1b2c3d", client: "abcdef123456")), .other)
    check("guest access: so Whole Mac is never offered to a guest", WholeMacMode.allCases.allSatisfy { !WholeMac.offered(mode: $0, viewer: WholeMac.viewer("guest-0a1b2c3d-abcdef123456")) })
    var key = Message(.key); key.win = 77
    expect("guest access: key, text, mouse, scroll and resize are input", [Message.Kind.key, .text, .mouse, .scroll, .resize].map { k -> GuestRequest? in
        var m = Message(k); m.win = 77; return GuestAccess.request(for: m, parent: { _ in nil })
    }, Array(repeating: GuestRequest.input(win: 77), count: 5))
    var open = Message(.open); open.win = 99
    expect("guest access: an open carries the dialog's parent", GuestAccess.request(for: open, parent: { $0 == 99 ? 77 : nil }), .open(win: 99, parent: 77))
    expect("guest access: restart maps to restart", GuestAccess.request(for: Message(.restart), parent: { _ in nil }), .restart)
    expect("guest access: host-only kinds from a guest are refused", GuestAccess.request(for: Message(.windows), parent: { _ in nil }), nil)
    expect("guest access: input without a window is refused", GuestAccess.request(for: Message(.mouse), parent: { _ in nil }), nil)
    _ = key
}

private func controlSwitchTests() {
    let now = Date()
    let view = ShareLink(id: "0a1b2c3d", tokenHash: "h", window: 7, label: "w", control: false, created: now, expires: now + 60)
    let ctl = ShareLink(id: "0a1b2c3e", tokenHash: "h", window: 7, label: "w", control: true, created: now, expires: now + 60)
    check("allow remote control: off by default", !RemoteControlSwitch.enabled(stored: nil, environment: [:]))
    check("allow remote control: the saved switch", RemoteControlSwitch.enabled(stored: true, environment: [:]))
    check("allow remote control: env 0 wins over the switch", !RemoteControlSwitch.enabled(stored: true, environment: ["PORTHOLE_SHARE_ALLOW_CONTROL": "0"]))
    check("allow remote control: env 1 wins over the switch", RemoteControlSwitch.enabled(stored: false, environment: ["PORTHOLE_SHARE_ALLOW_CONTROL": "1"]))
    check("allow remote control: other env values change nothing", !RemoteControlSwitch.enabled(stored: nil, environment: ["PORTHOLE_SHARE_ALLOW_CONTROL": "yes"]))
    check("allow remote control: overridden only by 0 or 1", RemoteControlSwitch.overridden(environment: ["PORTHOLE_SHARE_ALLOW_CONTROL": "0"])
          && !RemoteControlSwitch.overridden(environment: [:]))
    check("allow remote control: a control link controls at once when on", RemoteControlSwitch.controlsAtOnce(ctl, switchOn: true))
    check("allow remote control: a control link watches when off", !RemoteControlSwitch.controlsAtOnce(ctl, switchOn: false))
    check("allow remote control: a view-only link never controls at once", !RemoteControlSwitch.controlsAtOnce(view, switchOn: true))
    expect("ask: switch on answers yes at once", RemoteControlSwitch.answer(ask: view, switchOn: true, controlling: false), .granted)
    expect("ask: switch off waits for the host", RemoteControlSwitch.answer(ask: view, switchOn: false, controlling: false), .prompt)
    expect("ask: a control link with the switch off also waits", RemoteControlSwitch.answer(ask: ctl, switchOn: false, controlling: false), .prompt)
    expect("ask: already controlling is no new prompt", RemoteControlSwitch.answer(ask: view, switchOn: false, controlling: true), .alreadyControlling)
    check("env flags: PORTHOLE_SHARE_ALLOW_CONTROL is documented", EnvFlags.all.contains { $0.name == "PORTHOLE_SHARE_ALLOW_CONTROL" })
}

private func trackPlanTests() {
    let now = Date()
    let window = ShareLink(id: "0a1b2c3d", tokenHash: "h", window: 77, label: "w", control: false, created: now, expires: now + 60)
    let picker = ShareLink(id: "0a1b2c3e", tokenHash: "h", window: nil, label: "p", control: false, created: now, expires: now + 60)
    let tracks = [TrackGrantPlan.Track(sid: "TR_77", name: "win-77"), .init(sid: "TR_88", name: "win-88"), .init(sid: "TR_MAC", name: Message.trackName(for: WholeMac.windowID(screen: 0) ?? 0)),
                  .init(sid: "TR_99", name: "win-99"), .init(sid: "TR_AUD", name: "aud-mix")]
    let parent: (UInt32) -> UInt32? = { $0 == 99 ? 77 : nil }
    let mac = TrackGrantPlan.Participant(sid: "PA_mac", identity: "view-Air-abc.0123456789abcdef")
    let none = TrackGrantPlan.make(participants: [mac], tracks: tracks, link: { _ in nil }, parent: parent, sharedParents: [77, 88])
    expect("track plan: with no guests every viewer may subscribe", none, TrackGrantPlan(allParticipantsAllowed: true, grants: []))
    let armed = TrackGrantPlan.make(participants: [mac], tracks: tracks, link: { _ in nil }, parent: parent, sharedParents: [77], linksExist: true)
    check("track plan: while any share link is live the default is closed before a guest joins",
          !armed.allParticipantsAllowed && armed.grants == [TrackGrant(participantSid: "PA_mac", allTracks: true, trackSids: [])])
    let fresh = TrackGrantPlan.make(participants: [], tracks: tracks, link: { _ in nil }, parent: parent, sharedParents: [], linksExist: true)
    check("track plan: a guest who joins before the next update sees nothing", !fresh.allParticipantsAllowed && fresh.grants.isEmpty)
    let g1 = TrackGrantPlan.Participant(sid: "PA_g1", identity: "guest-0a1b2c3d-aaaaaa")
    let g2 = TrackGrantPlan.Participant(sid: "PA_g2", identity: "guest-0a1b2c3e-bbbbbb")
    let gone = TrackGrantPlan.Participant(sid: "PA_g3", identity: "guest-deadbeef-cccccc")
    let links = ["guest-0a1b2c3d-aaaaaa": window, "guest-0a1b2c3e-bbbbbb": picker]
    let plan = TrackGrantPlan.make(participants: [g2, mac, g1, gone], tracks: tracks, link: { links[$0] }, parent: parent, sharedParents: [77, 88])
    check("track plan: with a guest the default is closed", !plan.allParticipantsAllowed)
    func grant(_ sid: String) -> TrackGrant? { plan.grants.first { $0.participantSid == sid } }
    check("track plan: a paired Mac still sees every track", grant("PA_mac")?.allTracks == true)
    expect("track plan: a window guest sees its window and its dialog, not another window or the mixed sound",
           grant("PA_g1")?.trackSids, ["TR_77", "TR_99"])
    expect("track plan: a picker guest sees every window and the sound", grant("PA_g2")?.trackSids, ["TR_77", "TR_88", "TR_99", "TR_AUD"])
    check("track plan: a guest whose link is gone sees nothing", grant("PA_g3")?.allTracks == false && grant("PA_g3")?.trackSids == [])
    let alone = TrackGrantPlan.make(participants: [g1], tracks: tracks, link: { links[$0] }, parent: parent, sharedParents: [77])
    expect("track plan: a window guest hears the sound while only its window is shared", alone.grants.first?.trackSids, ["TR_77", "TR_88", "TR_99", "TR_AUD"].filter { $0 != "TR_88" })
    check("track plan: the same input gives the same plan", plan == TrackGrantPlan.make(participants: [g2, mac, g1, gone], tracks: tracks, link: { links[$0] }, parent: parent, sharedParents: [77, 88]))
}

private func shareURLTests() {
    let both = ShareURLs.make(token: "t-_1", window: 77, lan: "192.168.1.20", tailnet: "100.70.1.2", port: 7878, wifiOnly: false)
    expect("share urls: one for this Wi-Fi, one for the tailnet", both.map(\.url),
           ["http://192.168.1.20:7878/?share=t-_1&win=77", "http://100.70.1.2:7878/?share=t-_1&win=77"])
    expect("share urls: --wifi prints the Wi-Fi link alone", ShareURLs.make(token: "t", window: nil, lan: "10.0.0.5", tailnet: "100.70.1.2", port: 7878, wifiOnly: true).map(\.url),
           ["http://10.0.0.5:7878/?share=t"])
    expect("share urls: no Wi-Fi means just the tailnet", ShareURLs.make(token: "t", window: nil, lan: nil, tailnet: "100.70.1.2", port: 7878, wifiOnly: false).map(\.kind), ["tailnet"])
    check("share urls: never carry the password", !both.contains { $0.url.contains("pw=") })
    func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
    expect("lan address: en0's private address", pickLANAddress([.init(name: "utun3", ip: ip(100, 70, 1, 2)), .init(name: "en1", ip: ip(10, 0, 0, 9)),
                                                                   .init(name: "en0", ip: ip(192, 168, 1, 20))]), "192.168.1.20")
    expect("lan address: another en interface when en0 is down", pickLANAddress([.init(name: "en7", ip: ip(172, 20, 0, 3))]), "172.20.0.3")
    expect("lan address: never the tailnet, a public or a bridge address",
           pickLANAddress([.init(name: "en0", ip: ip(100, 70, 1, 2)), .init(name: "en0", ip: ip(8, 8, 8, 8)), .init(name: "bridge100", ip: ip(192, 168, 64, 1))]), nil)
    check("lan address: 172.32 is not private", !isPrivateLANIPv4(ip(172, 32, 0, 1)) && isPrivateLANIPv4(ip(172, 31, 255, 1)))
}

private func shareRouteTests() {
    let dir = shareDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    var now = Date()
    let shares = ShareLinkStore(directory: dir, clock: { now })
    var routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, suffix: { "sfx" },
                           pairing: PairingDesk(random: { 1 }), hostName: "Mini", trust: TrustStore(directory: dir), hostID: nil)
    routes.shares = shares
    routes.now = { now }
    var switchOn = false
    routes.guestControl = { switchOn }
    routes.resolveWindow = { pickWindow($0, in: [safari, notes]) }
    routes.shareAddresses = { ("192.168.1.20", "100.70.1.2") }
    let secret = String(repeating: "s", count: 40)
    routes.localSecret = secret
    var changed = 0
    var unshared: [String] = []
    routes.onSharesChanged = { changed += 1 }
    routes.onUnshare = { unshared.append($0.id) }
    func local(_ target: String) -> HTTPResponse {
        routes.respond(to: req(target, host: "127.0.0.1:7878", extra: ["\(localRouteHeader): \(secret)"]), fromLoopback: true)
    }

    let minted = local("/local/share?window=safari&control=0")
    let body = json(minted.body) ?? [:]
    let links = body["links"] as? [[String: Any]] ?? []
    check("share route: minting a window link answers 200 with two links", minted.status == "200 OK" && links.count == 2)
    check("share route: it names the window", body["window"] as? Int == 77 && body["label"] as? String == "Safari — Apple")
    check("share route: the links never contain the host password", !String(decoding: minted.body, as: UTF8.self).contains("pw-123"))
    expect("share route: the host was told the list changed", changed, 1)
    let url = links.first?["url"] as? String ?? ""
    let token = URLComponents(string: url)?.queryItems?.first { $0.name == "share" }?.value ?? ""
    check("share route: the link carries a share token and the window", !token.isEmpty && url.contains("&win=77"))
    expect("share route: --wifi gives one link", (json(local("/local/share?wifi=1").body)?["links"] as? [Any])?.count, 1)
    expect("share route: a window nobody has is 404", local("/local/share?window=nothing-like-this").status, "404 Not Found")
    expect("share route: from the network the local routes don't exist",
           routes.respond(to: req("/local/share?window=safari"), fromLoopback: false).status, "404 Not Found")
    expect("share route: without the local secret either", routes.respond(to: req("/local/share", host: "127.0.0.1"), fromLoopback: true).status, "404 Not Found")
    expect("share route: HEAD can't mint", routes.respond(to: "HEAD /local/share HTTP/1.1\r\nHost: 127.0.0.1\r\n\(localRouteHeader): \(secret)\r\n\r\n", fromLoopback: true).status,
           "405 Method Not Allowed")

    let guest = routes.respond(to: req("/token?share=\(token)&cid=abcdef123456&name=browser"))
    let gb = json(guest.body) ?? [:]
    let jwt = gb["token"] as? String ?? ""
    let c = claims(jwt) ?? [:]
    check("guest token: a live share token gets a LiveKit token", guest.status == "200 OK" && !jwt.isEmpty)
    expect("guest token: the identity is the link's guest", c["sub"] as? String, "guest-\(body["id"] as? String ?? "")-abcdef123456")
    let video = c["video"] as? [String: Any] ?? [:]
    check("guest token: a guest can't publish media or administer the room", video["canPublish"] as? Bool == false && video["roomAdmin"] == nil)
    check("guest token: lasts at most 10 minutes", ((c["exp"] as? Int) ?? 0) - ((c["iat"] as? Int) ?? 0) <= 600)
    let g = gb["guest"] as? [String: Any] ?? [:]
    check("guest token: tells the page which window and that it watches", g["window"] as? Int == 77 && g["control"] as? Bool == false)
    expect("guest token: a wrong share token is refused", routes.respond(to: req("/token?share=\(token)x")).status, "403 Forbidden")
    check("guest token: the refusal says the link expired", json(routes.respond(to: req("/token?share=nope")).body)?["expired"] as? Bool == true)
    expect("guest token: the password still works for owners", routes.respond(to: req("/token?pw=pw-123")).status, "200 OK")
    expect("guest token: a share token is not a password", routes.respond(to: req("/token?pw=\(token)")).status, "403 Forbidden")

    let ctl = json(local("/local/share?window=77&control=1").body) ?? [:]
    let ctlToken = URLComponents(string: (ctl["links"] as? [[String: Any]])?.first?["url"] as? String ?? "")?.queryItems?.first { $0.name == "share" }?.value ?? ""
    check("guest token: a control link watches while Allow Remote Control is off",
          (json(routes.respond(to: req("/token?share=\(ctlToken)")).body)?["guest"] as? [String: Any])?["control"] as? Bool == false)
    switchOn = true
    check("guest token: a control link controls once it is on",
          (json(routes.respond(to: req("/token?share=\(ctlToken)")).body)?["guest"] as? [String: Any])?["control"] as? Bool == true)

    let listed = json(local("/local/shares").body)?["links"] as? [[String: Any]] ?? []
    expect("shares route: lists the live links", listed.count, 3)
    check("shares route: never lists tokens", !String(decoding: local("/local/shares").body, as: UTF8.self).contains(token))
    let id = body["id"] as? String ?? ""
    expect("unshare route: revokes by id", local("/local/unshare?id=\(id)").status, "200 OK")
    expect("unshare route: the host is told to disconnect its guests", unshared, [id])
    expect("unshare route: the revoked token is refused at once", routes.respond(to: req("/token?share=\(token)")).status, "403 Forbidden")
    expect("unshare route: an unknown id is 404", local("/local/unshare?id=00000000").status, "404 Not Found")
    expect("unshare route: all", json(local("/local/unshare?id=all").body)?["revoked"] as? Int, 2)
    expect("unshare route: nothing left", shares.links().count, 0)

    guard let soon = shares.mint(window: nil, label: "", control: false, ttl: 120) else { return }
    now = now.addingTimeInterval(119.5)
    check("guest token: near expiry the LiveKit token ends with the link", {
        let c = claims(json(routes.respond(to: req("/token?share=\(soon.token)")).body)?["token"] as? String ?? "") ?? [:]
        return ((c["exp"] as? Int) ?? 0) - ((c["iat"] as? Int) ?? 0) <= 1
    }())
    now = now.addingTimeInterval(1)
    expect("guest token: after expiry it is refused", routes.respond(to: req("/token?share=\(soon.token)")).status, "403 Forbidden")
}

private func shareCLITests() {
    func opts(_ args: [String]) -> ShareOptions? {
        if case .share(let o) = parseCLI(["share"] + args) { return o }
        return nil
    }
    check("cli share: no arguments shares the picker, view only", opts([]) == ShareOptions())
    var w = ShareOptions(); w.window = "Safari Apple"; w.control = true; w.wifiOnly = true
    expect("cli share: window words, --control and --wifi", opts(["Safari", "--control", "Apple", "--wifi"]), w)
    expect("cli share: --ttl 2h", opts(["--ttl", "2h"])?.ttl, 7200)
    check("cli share: --ttl under a minute is refused", opts(["--ttl", "10s"]) == nil)
    expect("cli share: --list", opts(["--list"])?.list, true)
    expect("cli share: --revoke id", opts(["--revoke", "0a1b2c3d"])?.revoke, "0a1b2c3d")
    check("cli share: --revoke needs an id", opts(["--revoke"]) == nil)
    check("cli share: --list with a window is refused", opts(["--list", "Safari"]) == nil)
    check("cli share: unknown options are refused", opts(["--everyone"]) == nil)
    check("cli usage: documents share", cliUsage.contains("share [window] [--control] [--wifi]"))
    let text = ShareText.minted(["id": "0a1b2c3d", "control": false, "window": 77, "label": "Safari — Apple", "allowRemoteControl": false,
                                 "expires": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 86400)),
                                 "links": [["kind": "wifi", "url": "http://192.168.1.20:7878/?share=t"], ["kind": "tailnet", "url": "http://100.70.1.2:7878/?share=t"]]],
                                now: Date(timeIntervalSince1970: 0))
    check("cli share: prints the Wi-Fi link first, then the tailnet", text.hasPrefix("This Wi-Fi  http://192.168.1.20:7878/?share=t\nTailnet     http://100.70.1.2:7878/?share=t"))
    check("cli share: says view only, the expiry and how to revoke", text.contains("view only") && text.contains("Expires in 1d 0h") && text.contains("porthole share --revoke 0a1b2c3d"))
    let ctl = ShareText.minted(["id": "x", "control": true, "allowRemoteControl": false, "links": []])
    check("cli share: a control link with the switch off says guests ask", ctl.contains("Allow Remote Control is off"))
    check("cli share list: shows the switch and each link", ShareText.list([["id": "0a1b2c3d", "control": true, "label": "Safari",
        "expires": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 3600))]], allowControl: true, now: Date(timeIntervalSince1970: 0))
        == "Allow Remote Control: on\n0a1b2c3d  control 1h 00m   Safari")
}
