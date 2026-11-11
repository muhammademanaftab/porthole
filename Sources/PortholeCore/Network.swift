import Foundation

public func isTailscaleIPv4(_ ip: UInt32) -> Bool {
    ip >> 22 == (100 << 2) | 1
}

public func dottedQuad(_ ip: UInt32) -> String {
    "\(ip >> 24).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
}

private let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

public func viewerLink(host: String, port: UInt16, password: String) -> String {
    "http://\(host):\(port)/#pw=\(password.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
}

public func splitHostAddress(_ address: String, defaultPort: Int = Int(HostConfig.defaultHTTPPort)) -> (host: String, port: Int)? {
    var s = address.trimmingCharacters(in: .whitespaces)
    if s.lowercased().hasPrefix("http://") { s = String(s.dropFirst(7)) }
    if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
    func port(_ p: Substring) -> Int? {
        guard !p.isEmpty, p.count <= 5, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p), (1...65535).contains(n) else { return nil }
        return n
    }
    if s.hasPrefix("[") {
        guard let end = s.firstIndex(of: "]") else { return nil }
        let host = String(s[...end])
        let rest = s[s.index(after: end)...]
        guard host.count > 2 else { return nil }
        if rest.isEmpty { return (host, defaultPort) }
        guard rest.hasPrefix(":"), let p = port(rest.dropFirst()) else { return nil }
        return (host, p)
    }
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count > 2 { return ("[\(s)]", defaultPort) }
    guard let first = parts.first, !first.isEmpty else { return nil }
    if parts.count == 1 { return (String(first), defaultPort) }
    guard let p = port(parts[1]) else { return nil }
    return (String(first), p)
}

public func tokenURL(hostAddress: String, password: String, name: String) -> URL? {
    guard let (host, port) = splitHostAddress(hostAddress) else { return nil }
    var comps = URLComponents()
    comps.scheme = "http"
    comps.host = host
    comps.port = port
    comps.path = "/token"
    comps.queryItems = [URLQueryItem(name: "pw", value: password), URLQueryItem(name: "name", value: name)]
    return comps.url
}

public func shortHostName(_ hostName: String) -> String {
    let first = hostName.components(separatedBy: ".").first ?? ""
    return first.isEmpty ? "mac" : first
}

public func viewerArguments(_ args: [String]) -> (host: String?, password: String?) {
    let flagsWithValue: Set<String> = ["-NSDocumentRevisionsDebugMode", "-ApplePersistenceIgnoreState", "-AppleLanguages",
                                       "-AppleLocale", "-NSTreatUnknownArgumentsAsOpen"]
    var positional: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if flagsWithValue.contains(a) { i += 2; continue }
        if a.hasPrefix("-psn_") { i += 1; continue }
        positional.append(a)
        i += 1
    }
    return (positional.first, positional.dropFirst().first)
}

public func nextBackoff(_ seconds: UInt64) -> UInt64 {
    min(seconds * 2, 30)
}

public func restartDelay(after previous: UInt64?, uptime: TimeInterval) -> UInt64 {
    guard let previous, uptime < 60 else { return 1 }
    return nextBackoff(previous)
}

public enum RetryPolicy {
    public static let list = (times: 10, every: 1.0)
    public static let open = (times: 5, every: 2.0)
}

public enum DisconnectKind: Equatable, Sendable { case byViewer, removed, replaced, roomGone, lost }

public let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 30, 30]

public let stableConnection: TimeInterval = 30

public func nextReconnectAttempt(previous: Int, upFor: TimeInterval?) -> Int {
    if let upFor, upFor >= stableConnection { return 1 }
    return max(previous, 0) + 1
}

public func reconnectDelay(after kind: DisconnectKind, attempt: Int) -> TimeInterval? {
    guard kind == .lost, attempt >= 1, attempt <= reconnectDelays.count else { return nil }
    return reconnectDelays[attempt - 1]
}

public func liveKitConfigYAML(port: Int, apiKey: String, apiSecret: String) -> String {
    """
    port: \(port)
    bind_addresses:
      - ""
    rtc:
      tcp_port: \(port + 1)
      udp_port: \(port + 2)
      use_external_ip: false
      enable_loopback_candidate: true
    keys:
      \(apiKey): \(apiSecret)
    logging:
      level: warn
    """
}
