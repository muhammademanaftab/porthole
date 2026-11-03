import Foundation
import PortholeCore

private let statusJSON = #"""
{
  "Version": "1.104.4-t938213198-gd38c96d6a",
  "TUN": true,
  "BackendState": "Running",
  "HaveNodeKey": true,
  "AuthURL": "",
  "TailscaleIPs": ["100.82.48.82", "fd7a:115c:a1e0::939:3053"],
  "Self": {
    "ID": "nSelf1CNTRL",
    "PublicKey": "nodekey:aa11",
    "HostName": "Me's Mac",
    "DNSName": "mes-mac.tail1a2b3c.ts.net.",
    "OS": "macOS",
    "TailscaleIPs": ["100.82.48.82", "fd7a:115c:a1e0::939:3053"],
    "Addrs": ["192.168.1.20:41641"],
    "Online": true
  },
  "Health": null,
  "MagicDNSSuffix": "tail1a2b3c.ts.net",
  "CurrentTailnet": {"Name": "me@example.com", "MagicDNSSuffix": "tail1a2b3c.ts.net", "MagicDNSEnabled": true},
  "Peer": {
    "nodekey:3cb4": {
      "ID": "nWin1CNTRL", "HostName": "mes-win", "DNSName": "mes-win.tail1a2b3c.ts.net.", "OS": "windows",
      "UserID": 2648168906960889, "TailscaleIPs": ["100.108.99.119", "fd7a:115c:a1e0::f139:6379"],
      "AllowedIPs": ["100.108.99.119/32"], "Addrs": null, "CurAddr": "", "Relay": "fra", "RxBytes": 0, "TxBytes": 0,
      "LastSeen": "0001-01-01T00:00:00Z", "Online": true, "ExitNode": false, "Active": false,
      "PeerAPIURL": ["http://100.108.99.119:47021"], "KeyExpiry": "2027-03-30T19:44:26Z"
    },
    "nodekey:77aa": {
      "ID": "nPi1CNTRL", "HostName": "mes-pi", "DNSName": "mes-pi.tail1a2b3c.ts.net.", "OS": "linux",
      "TailscaleIPs": ["100.112.90.61", "fd7a:115c:a1e0::3139:5a3f"], "Addrs": null, "Online": false
    },
    "nodekey:6566": {
      "ID": "nMini1CNTRL", "HostName": "Leo’s Mac mini", "DNSName": "leos-mac-mini.tail1a2b3c.ts.net.",
      "OS": "macOS", "TailscaleIPs": ["fd7a:115c:a1e0::6566:6767", "100.101.102.103"],
      "Addrs": ["192.168.1.31:41641"], "CurAddr": "192.168.1.31:41641", "Online": true, "Active": true
    },
    "nodekey:9839": {
      "ID": "nPhone1CNTRL", "HostName": "localhost", "DNSName": "mes-phone.tail1a2b3c.ts.net.", "OS": "iOS",
      "TailscaleIPs": ["100.106.83.101"], "Addrs": null, "Online": false
    },
    "nodekey:0ff1": {
      "ID": "nAir1CNTRL", "HostName": "Old Air", "DNSName": "old-air.tail1a2b3c.ts.net.", "OS": "macOS",
      "TailscaleIPs": ["100.70.1.2"], "Addrs": null, "Online": false
    }
  },
  "User": {"2648168906960889": {"ID": 2648168906960889, "LoginName": "me@example.com"}},
  "ClientVersion": null
}
"""#

func discoveryTests() {
    expect("dotted quad parse: round trips", parseDottedQuad("100.101.102.103").map(dottedQuad), "100.101.102.103")
    for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "a.b.c.d", "1.2.3.-4", "fd7a:115c::1", " 1.2.3.4", "1.2.3.0004"] {
        check("dotted quad parse: \"\(bad)\" is rejected", parseDottedQuad(bad) == nil)
    }
    check("tailscale address: 100.101.102.103", isTailscaleAddress("100.101.102.103"))
    check("tailscale address: LAN address is not", !isTailscaleAddress("192.168.1.31"))
    check("tailscale address: IPv6 ULA is not (IPv4 only)", !isTailscaleAddress("fd7a:115c:a1e0::6566:6767"))

    let status = TailscaleStatus.parse(Data(statusJSON.utf8))
    check("tailscale status: realistic JSON with null Addrs and Health parses", status != nil)
    expect("tailscale status: running", status?.running, true)
    expect("tailscale status: own IPv4", status?.selfIPv4, "100.82.48.82")
    expect("tailscale status: all five peers, sorted by host name", status?.peers.map(\.hostName),
           ["Leo\u{2019}s Mac mini", "Old Air", "localhost", "mes-pi", "mes-win"])
    let mini = status?.peers.first { $0.dnsName.hasPrefix("leos-mac-mini") }
    expect("tailscale status: IPv4 is picked even when IPv6 is listed first", mini?.ipv4, "100.101.102.103")
    check("tailscale status: mini is an online Mac", mini?.isMac == true && mini?.online == true)
    expect("tailscale status: only online macOS peers are probed", status?.probeTargets.map(\.ipv4), ["100.101.102.103"])

    let stopped = statusJSON.replacingOccurrences(of: #""BackendState": "Running""#, with: #""BackendState": "Stopped""#)
    expect("tailscale status: nothing is probed when Tailscale is stopped",
           TailscaleStatus.parse(Data(stopped.utf8))?.probeTargets.count, 0)
    let lonely = #"{"BackendState":"Running","TailscaleIPs":null,"Self":{"HostName":"a","TailscaleIPs":["100.64.0.9"]},"Peer":null}"#
    let alone = TailscaleStatus.parse(Data(lonely.utf8))
    check("tailscale status: null Peer map means no peers", alone?.peers == [] && alone?.running == true)
    expect("tailscale status: falls back to Self's IPs", alone?.selfIPv4, "100.64.0.9")
    expect("tailscale status: logged out", TailscaleStatus.parse(Data(#"{"BackendState":"NeedsLogin","Peer":{}}"#.utf8))?.running, false)
    check("tailscale status: CLI error text is not JSON", TailscaleStatus.parse(Data("failed to connect to local tailscaled".utf8)) == nil)
    check("tailscale status: a JSON array is not a status", TailscaleStatus.parse(Data("[]".utf8)) == nil)

    expect("peer name: HostName when it is real", peerDisplayName(TailscalePeer(hostName: "Old Air", dnsName: "x.ts.net.", ipv4: nil, online: true, os: "macOS")),
           "Old Air")
    expect("peer name: localhost falls back to the DNS label",
           peerDisplayName(TailscalePeer(hostName: "localhost", dnsName: "mes-phone.tail.ts.net.", ipv4: "100.1.1.1", online: true, os: "iOS")), "mes-phone")
    expect("peer name: nothing usable falls back to the IP",
           peerDisplayName(TailscalePeer(hostName: "", dnsName: "", ipv4: "100.64.1.1", online: true, os: "macOS")), "100.64.1.1")

    let hello = HostHello(name: "Leo\u{2019}s Mac mini", version: 1)
    expect("hello: JSON round trip", HostHello.parse(hello.json), hello)
    expect("hello: exact JSON shape", String(decoding: hello.json, as: UTF8.self), #"{"app":"porthole","name":"Leo’s Mac mini","version":1}"#)
    expect("hello: a newer version with extra fields still parses",
           HostHello.parse(Data(#"{"app":"porthole","name":"mini","version":2,"pairing":true}"#.utf8)), HostHello(name: "mini", version: 2))
    expect("hello: blank name becomes Mac", HostHello.parse(Data(#"{"app":"porthole","name":"  ","version":1}"#.utf8))?.name, "Mac")
    for (why, s) in [("another app", #"{"app":"plex","name":"x","version":1}"#), ("no version", #"{"app":"porthole","name":"x"}"#),
                     ("version 0", #"{"app":"porthole","version":0}"#), ("string version", #"{"app":"porthole","version":"1"}"#),
                     ("HTML", "<html>not found</html>"), ("empty", "")] {
        check("hello: \(why) is not a Porthole hello", HostHello.parse(Data(s.utf8)) == nil)
    }

    let page = Data("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Porthole</title>\n".utf8)
    check("page sniff: the old host's index.html looks like Porthole", isPortholePage(page))
    check("page sniff: another web app does not", !isPortholePage(Data("<html><title>Plex</title></html>".utf8)))
    let ok = Data(#"{"app":"porthole","name":"mini","version":1}"#.utf8)
    expect("probe: /hello answering is a Porthole host",
           probeVerdict(helloStatus: 200, helloBody: ok, rootStatus: nil, rootBody: nil), .porthole(HostHello(name: "mini", version: 1)))
    expect("probe: /hello 404 but Porthole's page at / is an older host",
           probeVerdict(helloStatus: 404, helloBody: Data("not found".utf8), rootStatus: 200, rootBody: page), .olderPorthole)
    expect("probe: /hello 404 and some other page is not Porthole",
           probeVerdict(helloStatus: 404, helloBody: nil, rootStatus: 200, rootBody: Data("<title>Plex</title>".utf8)), .notPorthole)
    expect("probe: nothing listening is not Porthole", probeVerdict(helloStatus: nil, helloBody: nil, rootStatus: nil, rootBody: nil), .notPorthole)
    expect("probe: /hello 200 with junk is not Porthole",
           probeVerdict(helloStatus: 200, helloBody: Data("hi".utf8), rootStatus: 200, rootBody: page), .notPorthole)
    expect("probe: /hello 500 is not trusted as an older host",
           probeVerdict(helloStatus: 500, helloBody: nil, rootStatus: 200, rootBody: page), .notPorthole)

    let txt = BonjourTXT.make(name: "Leo\u{2019}s Mac mini", tailscaleIP: "100.101.102.103", localHost: "Leos-Mac-mini.local")
    expect("bonjour TXT: version, name, port, tailscale IP and .local name", txt,
           ["v": "1", "name": "Leo\u{2019}s Mac mini", "port": "7878", "ts": "100.101.102.103", "host": "Leos-Mac-mini.local"])
    expect("bonjour TXT: no tailscale IP when unknown or not tailscale",
           BonjourTXT.make(name: "m", tailscaleIP: "192.168.1.2", localHost: nil, port: 9000), ["v": "1", "name": "m", "port": "9000"])
    let long = String(repeating: "é", count: 150)
    let clipped = BonjourTXT.make(name: long, tailscaleIP: nil, localHost: nil)["name"] ?? ""
    check("bonjour TXT: long names are cut on a character boundary to fit in 255 bytes",
          clipped.utf8.count == 200 && clipped.allSatisfy { $0 == "é" })

    let found = BonjourTXT.host(serviceName: "svc", txt: txt)
    expect("bonjour host: built from TXT", found,
           DiscoveredHost(name: "Leo\u{2019}s Mac mini", tailscaleIP: "100.101.102.103", lanHost: "Leos-Mac-mini.local",
                          status: .online, viaBonjour: true))
    expect("bonjour host: missing name uses the service name",
           BonjourTXT.host(serviceName: "svc", txt: ["v": "1", "host": "a.local"])?.name, "svc")
    expect("bonjour host: port comes from TXT", BonjourTXT.host(serviceName: "s", txt: ["v": "1", "host": "a.local", "port": "9000"])?.port, 9000)
    expect("bonjour host: missing or bad port means 7878",
           [nil, "0", "70000", "x"].map { p in BonjourTXT.host(serviceName: "s", txt: ["v": "1", "host": "a.local"].merging(p.map { ["port": $0] } ?? [:]) { a, _ in a })?.port },
           [7878, 7878, 7878, 7878])
    check("bonjour host: without a version it is ignored", BonjourTXT.host(serviceName: "s", txt: ["host": "a.local"]) == nil)
    check("bonjour host: without any address it is ignored", BonjourTXT.host(serviceName: "s", txt: ["v": "1"]) == nil)
    expect("bonjour host: a bogus ts value is dropped",
           BonjourTXT.host(serviceName: "s", txt: ["v": "1", "ts": "8.8.8.8", "host": "a.local"])?.tailscaleIP, nil)

    let both = DiscoveredHost(name: "Mini", tailscaleIP: "100.101.102.103", lanHost: "Mini.local", status: .online)
    expect("address: prefers the Tailscale IP when asked", both.address(preferTailscale: true), "100.101.102.103")
    expect("address: prefers the LAN name otherwise", both.address(preferTailscale: false), "Mini.local")
    expect("address: custom port is appended", DiscoveredHost(name: "m", lanHost: "m.local", port: 9000, status: .online).address(preferTailscale: true), "m.local:9000")
    expect("address: falls back to the other kind", DiscoveredHost(name: "m", lanHost: "m.local", status: .online).address(preferTailscale: true), "m.local")
    expect("address: both addresses listed", both.addresses, ["100.101.102.103", "Mini.local"])

    let viaTS = DiscoveredHost(name: "Leo\u{2019}s Mac mini", tailscaleIP: "100.101.102.103", status: .online, viaTailscale: true)
    let saved = KnownHost(name: "Leo\u{2019}s Mac mini", address: "100.101.102.103").asDiscovered!
    let manual = KnownHost(name: "leos-mac-mini", address: "leos-mac-mini").asDiscovered!
    let older = DiscoveredHost(name: "Old Mini", tailscaleIP: "100.70.9.9", status: .older, viaTailscale: true)
    let lanOnly = DiscoveredHost(name: "Leo's  Mac Mini", lanHost: "Leos-Mac-mini.local", status: .online, viaBonjour: true)
    let merged = mergeHosts([saved, manual, older, viaTS, found!, lanOnly])
    expect("merge: same Tailscale IP, same name with curly vs straight apostrophe and case all collapse; manual name stays separate",
           merged.map(\.name), ["Leo\u{2019}s Mac mini", "Old Mini", "leos-mac-mini"])
    let m = merged.first
    check("merge: the merged host is online, seen both ways, and saved",
          m?.status == .online && m?.viaBonjour == true && m?.viaTailscale == true && m?.saved == true)
    check("merge: the merged host keeps both addresses", m?.tailscaleIP == "100.101.102.103" && m?.lanHost == "Leos-Mac-mini.local")
    expect("merge: label", m?.label, "online, via this network and Tailscale, saved")
    expect("merge: older host label tells you to use the password", merged[1].label, "online, older host: use its password, via Tailscale")
    expect("merge: saved but unseen is not found", merged[2].label, "not found, saved")
    let twins = mergeHosts([DiscoveredHost(name: "Mac", tailscaleIP: "100.64.0.1", status: .online),
                            DiscoveredHost(name: "Mac", tailscaleIP: "100.64.0.2", status: .online)])
    expect("merge: same name but different Tailscale IPs are two hosts", twins.count, 2)
    let byIP = mergeHosts([KnownHost(name: "100.101.102.103", address: "100.101.102.103").asDiscovered!, viaTS])
    expect("merge: a saved bare IP takes the discovered name", byIP.map(\.name), ["Leo\u{2019}s Mac mini"])
    expect("merge: sorted by status then name",
           mergeHosts([DiscoveredHost(name: "b", status: .notFound), DiscoveredHost(name: "c", status: .online),
                       DiscoveredHost(name: "A", status: .online)]).map(\.name), ["A", "c", "b"])

    expect("known host: tailscale address", KnownHost(name: "m", address: "100.101.102.103:9000").asDiscovered,
           DiscoveredHost(name: "m", tailscaleIP: "100.101.102.103", port: 9000, status: .notFound, saved: true))
    check("known host: unusable address is skipped", KnownHost(name: "m", address: "m:abc").asDiscovered == nil)
    let list = [KnownHost(name: "a", address: "a"), KnownHost(name: "b", address: "b")]
    expect("remember: newest first, replacing the same address", rememberHost(list, KnownHost(name: "B2", address: "B")).map(\.name), ["B2", "a"])
    expect("remember: same name with a new address replaces it",
           rememberHost(list, KnownHost(name: "a", address: "100.64.0.1")).map(\.address), ["100.64.0.1", "b"])
    expect("remember: capped", rememberHost((0..<10).map { KnownHost(name: "h\($0)", address: "h\($0)") }, KnownHost(name: "n", address: "n")).count, 10)

    expect("saved password key: host is case-insensitive and the default port is explicit", savedPasswordKey("Mini.Local"), "mini.local:7878")
    expect("saved password key: same host with and without the default port match", savedPasswordKey("http://mini.local:7878/"), "mini.local:7878")
    expect("saved password key: different ports differ", savedPasswordKey("mini.local:9000"), "mini.local:9000")
    expect("saved password key: unusable address has none", savedPasswordKey("mini:abc"), nil)

    expect("service type", portholeServiceType, "_porthole._tcp")
}
