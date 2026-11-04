import Foundation

public let portholeServiceType = "_porthole._tcp"
public let portholeProtocolVersion = 1

public func parseDottedQuad(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var ip: UInt32 = 0
    for p in parts {
        guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt32(p), n <= 255 else { return nil }
        ip = ip << 8 | n
    }
    return ip
}

public func isTailscaleAddress(_ s: String) -> Bool {
    parseDottedQuad(s).map(isTailscaleIPv4) ?? false
}

public struct HostHello: Equatable, Sendable {
    public var name: String
    public var version: Int
    public var id: String?

    public init(name: String, version: Int, id: String? = nil) {
        self.name = name; self.version = version; self.id = id
    }

    public var json: Data {
        var obj: [String: Any] = ["app": "porthole", "name": name, "version": version]
        if let id { obj["id"] = id }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    public static func parse(_ data: Data) -> HostHello? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["app"] as? String == "porthole", let version = obj["version"] as? Int, version >= 1 else { return nil }
        let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = (obj["id"] as? String).flatMap { DeviceIdentity.isValidID($0) ? $0 : nil }
        return HostHello(name: name.isEmpty ? "Mac" : name, version: version, id: id)
    }
}

public func isPortholePage(_ html: Data) -> Bool {
    String(decoding: html.prefix(4096), as: UTF8.self).contains("<title>Porthole</title>")
}

public enum ProbeVerdict: Equatable, Sendable {
    case porthole(HostHello)
    case olderPorthole
    case notPorthole
}

public func probeVerdict(helloStatus: Int?, helloBody: Data?, rootStatus: Int?, rootBody: Data?) -> ProbeVerdict {
    if helloStatus == 200, let body = helloBody, let hello = HostHello.parse(body) { return .porthole(hello) }
    guard helloStatus == 404, rootStatus == 200, let root = rootBody, isPortholePage(root) else { return .notPorthole }
    return .olderPorthole
}

public struct TailscalePeer: Equatable, Sendable {
    public var hostName: String
    public var dnsName: String
    public var ipv4: String?
    public var online: Bool
    public var os: String
    public var ips: [String]
    public var curAddr: String
    public var relay: String

    public init(hostName: String, dnsName: String, ipv4: String?, online: Bool, os: String, ips: [String] = [], curAddr: String = "", relay: String = "") {
        self.hostName = hostName; self.dnsName = dnsName; self.ipv4 = ipv4; self.online = online; self.os = os
        self.ips = ips; self.curAddr = curAddr; self.relay = relay
    }

    public var isMac: Bool { os == "macOS" }

    public var isRelayed: Bool { curAddr.isEmpty && !relay.isEmpty }
}

public struct TailscaleStatus: Equatable, Sendable {
    public var running: Bool
    public var selfIPv4: String?
    public var peers: [TailscalePeer]

    private struct Node: Decodable {
        var HostName: String?
        var DNSName: String?
        var OS: String?
        var TailscaleIPs: [String]?
        var Online: Bool?
        var CurAddr: String?
        var Relay: String?
    }

    private struct Status: Decodable {
        var BackendState: String?
        var TailscaleIPs: [String]?
        var `Self`: Node?
        var Peer: [String: Node]?
    }

    public static func parse(_ data: Data) -> TailscaleStatus? {
        guard let s = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        let peers = (s.Peer ?? [:]).values.map { n in
            TailscalePeer(hostName: n.HostName ?? "", dnsName: n.DNSName ?? "",
                          ipv4: (n.TailscaleIPs ?? []).first(where: isTailscaleAddress),
                          online: n.Online ?? false, os: n.OS ?? "", ips: n.TailscaleIPs ?? [],
                          curAddr: n.CurAddr ?? "", relay: n.Relay ?? "")
        }
        let ips = s.TailscaleIPs ?? s.Self?.TailscaleIPs ?? []
        return TailscaleStatus(running: s.BackendState == "Running", selfIPv4: ips.first(where: isTailscaleAddress),
                               peers: peers.sorted { ($0.hostName, $0.dnsName) < ($1.hostName, $1.dnsName) })
    }

    public func peer(withIP ip: String) -> TailscalePeer? {
        let want = bareHost(ip)
        return peers.first { p in p.ips.contains { bareHost($0) == want } || p.ipv4.map { bareHost($0) == want } == true }
    }

    public var probeTargets: [TailscalePeer] {
        guard running else { return [] }
        return peers.filter { $0.isMac && $0.online && $0.ipv4 != nil }
    }
}

public func peerDisplayName(_ peer: TailscalePeer) -> String {
    if !peer.hostName.isEmpty && peer.hostName != "localhost" { return peer.hostName }
    let label = peer.dnsName.split(separator: ".").first.map(String.init) ?? ""
    return label.isEmpty ? (peer.ipv4 ?? "Mac") : label
}

public enum BonjourTXT {
    public static func make(name: String, tailscaleIP: String?, localHost: String?,
                            port: Int = Int(HostConfig.defaultHTTPPort), id: String? = nil, lanIP: String? = nil) -> [String: String] {
        var txt = ["v": String(portholeProtocolVersion), "name": clip(name, bytes: 200), "port": String(port)]
        if let lanIP, addressScope(lanIP) == .local { txt["ip"] = lanIP }
        if let id, DeviceIdentity.isValidID(id) { txt["id"] = id }
        if let tailscaleIP, isTailscaleAddress(tailscaleIP) { txt["ts"] = tailscaleIP }
        if let localHost, !localHost.isEmpty { txt["host"] = clip(localHost, bytes: 200) }
        return txt
    }

    public static func host(serviceName: String, txt: [String: String]) -> DiscoveredHost? {
        guard let v = txt["v"].flatMap(Int.init), v >= 1 else { return nil }
        let port = txt["port"].flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
        let name = (txt["name"] ?? "").isEmpty ? serviceName : txt["name"]!
        let ts = txt["ts"].flatMap { isTailscaleAddress($0) ? $0 : nil }
        let lan = txt["host"].flatMap { $0.isEmpty ? nil : $0 }
        let ip = txt["ip"].flatMap { addressScope($0) == .local ? $0 : nil }
        guard ts != nil || lan != nil || ip != nil else { return nil }
        var host = DiscoveredHost(name: name, tailscaleIP: ts, lanHost: lan, port: port ?? Int(HostConfig.defaultHTTPPort),
                                  status: .online, viaBonjour: true, hostID: txt["id"].flatMap { DeviceIdentity.isValidID($0) ? $0 : nil })
        host.lanIP = ip
        return host
    }

    static func clip(_ s: String, bytes: Int) -> String {
        var out = ""
        for ch in s {
            if out.utf8.count + String(ch).utf8.count > bytes { break }
            out.append(ch)
        }
        return out
    }
}

public struct DiscoveredHost: Equatable, Sendable {
    public enum Status: Int, Comparable, Sendable {
        case online, older, notFound
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    public var name: String
    public var tailscaleIP: String?
    public var lanHost: String?
    public var port: Int
    public var status: Status
    public var viaBonjour: Bool
    public var viaTailscale: Bool
    public var saved: Bool
    public var hostID: String?
    public var lanIP: String?

    public init(name: String, tailscaleIP: String? = nil, lanHost: String? = nil, port: Int = Int(HostConfig.defaultHTTPPort),
                status: Status, viaBonjour: Bool = false, viaTailscale: Bool = false, saved: Bool = false, hostID: String? = nil) {
        self.name = name; self.tailscaleIP = tailscaleIP; self.lanHost = lanHost; self.port = port
        self.status = status; self.viaBonjour = viaBonjour; self.viaTailscale = viaTailscale; self.saved = saved
        self.hostID = hostID
    }

    public func address(preferTailscale: Bool) -> String {
        let host = (preferTailscale ? tailscaleIP ?? lanHost : lanHost ?? tailscaleIP) ?? name
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port == Int(HostConfig.defaultHTTPPort) ? bracketed : "\(bracketed):\(port)"
    }

    public var addresses: [String] {
        Array(Set([address(preferTailscale: true), address(preferTailscale: false)])).sorted()
    }

    public var label: String {
        var parts: [String] = []
        switch status {
        case .online: parts.append("online")
        case .older: parts.append("online, older host: use its password")
        case .notFound: parts.append("not found")
        }
        var via: [String] = []
        if viaBonjour { via.append("this network") }
        if viaTailscale { via.append("Tailscale") }
        if !via.isEmpty { parts.append("via " + via.joined(separator: " and ")) }
        if saved { parts.append("saved") }
        return parts.joined(separator: ", ")
    }

    func matches(_ o: DiscoveredHost) -> Bool {
        if let a = hostID, let b = o.hostID, a != b { return false }
        if let a = tailscaleIP, let b = o.tailscaleIP { return a == b }
        if let a = lanHost?.lowercased(), let b = o.lanHost?.lowercased(), a == b { return true }
        return normalizedHostName(name) == normalizedHostName(o.name)
    }

    mutating func absorb(_ o: DiscoveredHost) {
        status = min(status, o.status)
        tailscaleIP = tailscaleIP ?? o.tailscaleIP
        lanHost = lanHost ?? o.lanHost
        if port == Int(HostConfig.defaultHTTPPort) { port = o.port }
        viaBonjour = viaBonjour || o.viaBonjour
        viaTailscale = viaTailscale || o.viaTailscale
        saved = saved || o.saved
        hostID = hostID ?? o.hostID
        lanIP = lanIP ?? o.lanIP
        if name == tailscaleIP || name == lanHost || name.isEmpty { name = o.name }
    }
}

public func normalizedHostName(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

public func mergeHosts(_ hosts: [DiscoveredHost]) -> [DiscoveredHost] {
    var out: [DiscoveredHost] = []
    for h in hosts {
        if let i = out.firstIndex(where: { $0.matches(h) }) { out[i].absorb(h) } else { out.append(h) }
    }
    return out.sorted { ($0.status, normalizedHostName($0.name)) < ($1.status, normalizedHostName($1.name)) }
}

public struct KnownHost: Codable, Equatable, Sendable {
    public var name: String
    public var address: String

    public init(name: String, address: String) {
        self.name = name; self.address = address
    }

    public var asDiscovered: DiscoveredHost? {
        guard let (host, port) = splitHostAddress(address) else { return nil }
        let ts = isTailscaleAddress(host) ? host : nil
        return DiscoveredHost(name: name.isEmpty ? host : name, tailscaleIP: ts, lanHost: ts == nil ? host : nil, port: port,
                              status: .notFound, saved: true)
    }
}

public func savedPasswordKey(_ address: String) -> String? {
    guard let (host, port) = splitHostAddress(address) else { return nil }
    return "\(host.lowercased()):\(port)"
}

public func rememberHost(_ list: [KnownHost], _ host: KnownHost, limit: Int = 10) -> [KnownHost] {
    let rest = list.filter { $0.address.lowercased() != host.address.lowercased() && !($0.name == host.name && !host.name.isEmpty) }
    return Array(([host] + rest).prefix(limit))
}
