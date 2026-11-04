import Foundation

public enum RouteMode: String, CaseIterable, Equatable, Sendable {
    case auto, local, tailscale

    public static let settingKey = "connection.route"
    public static let envKey = "PORTHOLE_ROUTE"

    public static func parse(_ s: String?) -> RouteMode? {
        switch s?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "auto", "automatic": return .auto
        case "local", "lan", "same-network", "samenetwork": return .local
        case "tailscale", "ts": return .tailscale
        default: return nil
        }
    }

    public static func setting(_ stored: Any?) -> RouteMode {
        parse(stored as? String) ?? .auto
    }

    public static func effective(setting: RouteMode, environment: [String: String] = ProcessInfo.processInfo.environment) -> RouteMode {
        parse(environment[envKey]) ?? setting
    }

    public var label: String {
        switch self {
        case .auto: return "Automatic"
        case .local: return "Same network only"
        case .tailscale: return "Tailscale only"
        }
    }
}

public enum AddressScope: Equatable, Sendable {
    case loopback, local, tailscale, other
}

public func bareHost(_ host: String) -> String {
    var h = host.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
    if h.hasSuffix(".") { h = String(h.dropLast()) }
    return h.lowercased()
}

func parseIPv6(_ s: String) -> [UInt8]? {
    var addr = in6_addr()
    guard s.contains(":"), inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
    return withUnsafeBytes(of: &addr) { Array($0) }
}

public func addressScope(_ host: String) -> AddressScope {
    let h = bareHost(host)
    if let ip = parseDottedQuad(h) { return ipv4Scope(ip) }
    if let b = parseIPv6(h) {
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return ipv4Scope(UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15]))
        }
        if Array(b[0..<6]) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return .tailscale }
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return .local }
        if b[0] & 0xfe == 0xfc { return .local }
        return .other
    }
    if h == "localhost" { return .loopback }
    if h.hasSuffix(".local") { return .local }
    if h.hasSuffix(".ts.net") { return .tailscale }
    return .other
}

func ipv4Scope(_ ip: UInt32) -> AddressScope {
    if ip >> 24 == 127 { return .loopback }
    if isTailscaleIPv4(ip) { return .tailscale }
    if ip >> 24 == 10 || ip >> 20 == (172 << 4 | 1) || ip >> 16 == (192 << 8 | 168) || ip >> 16 == (169 << 8 | 254) { return .local }
    return .other
}

public struct RouteCandidate: Equatable, Sendable {
    public var address: String
    public var scope: AddressScope
    public var budget: TimeInterval?
    public var expectedID: String?

    public init(address: String, scope: AddressScope, budget: TimeInterval? = nil, expectedID: String? = nil) {
        self.address = address; self.scope = scope; self.budget = budget; self.expectedID = expectedID
    }

    public var needsHello: Bool { expectedID != nil }
}

public struct LocalSighting: Equatable, Sendable {
    public var address: String
    public var id: String?
    public var tailscaleIP: String?

    public init(address: String, id: String?, tailscaleIP: String? = nil) {
        self.address = address; self.id = id; self.tailscaleIP = tailscaleIP
    }
}

public enum RoutePlan {
    public static let localBudget: TimeInterval = 1.5
    public static let fallbackBudget: TimeInterval = 6

    public static func formatAddress(_ host: String, port: Int) -> String {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return port == Int(HostConfig.defaultHTTPPort) ? bracketed : "\(bracketed):\(port)"
    }

    public static func sightings(of hostID: String?, saved: String, in hosts: [DiscoveredHost]) -> [LocalSighting] {
        let id = hostID.flatMap { DeviceIdentity.isValidID($0) ? $0 : nil }
        let savedHost = splitHostAddress(saved).map { bareHost($0.host) }
        var out: [LocalSighting] = []
        for h in hosts where h.viaBonjour {
            let same: Bool
            if let id { same = h.hostID == id } else {
                same = h.tailscaleIP.map { bareHost($0) == savedHost } ?? false
                    || [h.lanIP, h.lanHost].compactMap { $0 }.contains { bareHost($0) == savedHost }
            }
            guard same else { continue }
            for host in [h.lanIP, h.lanHost].compactMap({ $0 }) where addressScope(host) == .local {
                out.append(LocalSighting(address: formatAddress(host, port: h.port), id: id ?? h.hostID, tailscaleIP: h.tailscaleIP))
            }
        }
        return out
    }

    public static func candidates(mode: RouteMode, saved: String, hostID: String?, local: [LocalSighting], known: [String]) -> [RouteCandidate] {
        guard let savedKey = savedPasswordKey(saved), let (savedHost, savedPort) = splitHostAddress(saved) else { return [] }
        let id = hostID.flatMap { DeviceIdentity.isValidID($0) ? $0 : nil }
        let savedScope = addressScope(savedHost)
        var list: [RouteCandidate] = []
        var seen: Set<String> = []
        func add(_ address: String, expected: String?, isSaved: Bool = false) {
            guard let key = savedPasswordKey(address), let (host, _) = splitHostAddress(address), !seen.contains(key) else { return }
            if !isSaved && expected == nil { return }
            seen.insert(key)
            list.append(RouteCandidate(address: address, scope: addressScope(host), expectedID: key == savedKey ? nil : expected))
        }
        let sightedTS = local.compactMap(\.tailscaleIP).map { formatAddress($0, port: savedPort) }
        let tailscaleKnown = (known + sightedTS).filter { a in splitHostAddress(a).map { addressScope($0.host) == .tailscale } ?? false }
        let localExpected = { (s: LocalSighting) in id ?? s.id }
        let anyID = id ?? local.lazy.compactMap(\.id).first
        switch mode {
        case .auto:
            for s in local { add(s.address, expected: localExpected(s)) }
            add(saved, expected: nil, isSaved: true)
            for a in tailscaleKnown { add(a, expected: anyID) }
        case .local:
            for s in local { add(s.address, expected: localExpected(s)) }
            if savedScope == .local || savedScope == .loopback { add(saved, expected: nil, isSaved: true) }
        case .tailscale:
            if savedScope == .tailscale || savedScope == .other { add(saved, expected: nil, isSaved: true) }
            for a in tailscaleKnown { add(a, expected: anyID) }
        }
        for i in list.indices {
            let last = i == list.count - 1
            if list[i].scope == .local || list[i].scope == .loopback {
                list[i].budget = last ? nil : localBudget
            } else {
                list[i].budget = last ? nil : fallbackBudget
            }
        }
        return list
    }

    public static func noRouteMessage(mode: RouteMode, hostName: String) -> String {
        switch mode {
        case .local: return "\(hostName) isn't on this network. Settings › General › Connection is set to Same network only."
        case .tailscale: return "No Tailscale address is known for \(hostName). Settings › General › Connection is set to Tailscale only."
        case .auto: return "No address is known for \(hostName)."
        }
    }

    public static func helloConfirms(_ hello: HostHello?, expectedID: String?) -> Bool {
        guard let expectedID else { return true }
        return hello?.id == expectedID
    }
}

public enum RouteKind: String, Equatable, Sendable {
    case thisMac, sameNetwork, tailscale, tailscaleRelay, relayed, internet

    public var label: String {
        switch self {
        case .thisMac: return "This Mac"
        case .sameNetwork: return "Same network"
        case .tailscale: return "Tailscale"
        case .tailscaleRelay: return "Tailscale relay"
        case .relayed: return "Relayed"
        case .internet: return "Internet"
        }
    }
}

public struct RouteInfo: Equatable, Sendable {
    public var kind: RouteKind
    public var address: String?

    public init(kind: RouteKind, address: String?) {
        self.kind = kind; self.address = address
    }

    public var text: String {
        guard let address, !address.isEmpty else { return kind.label }
        return "\(kind.label) (\(address))"
    }

    public var menuTitle: String { "Connection: \(text)" }
}

public func classifyRoute(remoteAddress: String?, remoteType: String?, localType: String?, tailscale: TailscaleStatus? = nil) -> RouteKind {
    if remoteType == "relay" || localType == "relay" { return .relayed }
    let address = remoteAddress.map(bareHost) ?? ""
    switch addressScope(address) {
    case .loopback: return .thisMac
    case .local: return .sameNetwork
    case .tailscale:
        if let peer = tailscale?.peer(withIP: address), peer.isRelayed { return .tailscaleRelay }
        return .tailscale
    case .other: return .internet
    }
}

public struct IceCandidateFacts: Equatable, Sendable {
    public var id: String?
    public var address: String?
    public var type: String?

    public init(id: String? = nil, address: String?, type: String?) {
        self.id = id; self.address = address; self.type = type
    }
}

public func routeInfo(remote: IceCandidateFacts?, local: IceCandidateFacts?, tailscale: TailscaleStatus? = nil) -> RouteInfo? {
    guard let remote, let address = remote.address, !address.isEmpty else { return nil }
    let kind = classifyRoute(remoteAddress: address, remoteType: remote.type, localType: local?.type, tailscale: tailscale)
    return RouteInfo(kind: kind, address: bareHost(address))
}

public func helloURL(hostAddress: String) -> URL? {
    guard let (host, port) = splitHostAddress(hostAddress) else { return nil }
    var comps = URLComponents()
    comps.scheme = "http"
    comps.host = host
    comps.port = port
    comps.path = "/hello"
    return comps.url
}

public func signalingRoute(address: String) -> RouteInfo? {
    guard let (host, _) = splitHostAddress(address) else { return nil }
    let kind: RouteKind
    switch addressScope(host) {
    case .loopback: kind = .thisMac
    case .local: kind = .sameNetwork
    case .tailscale: kind = .tailscale
    case .other: kind = .internet
    }
    return RouteInfo(kind: kind, address: bareHost(host))
}
