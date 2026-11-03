import Foundation

public func isTailscaleIPv4(_ ip: UInt32) -> Bool {
    ip >> 22 == (100 << 2) | 1
}

public func dottedQuad(_ ip: UInt32) -> String {
    "\(ip >> 24).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
}

public func viewerLink(host: String, port: UInt16, password: String) -> String {
    "http://\(host):\(port)/?pw=\(password)"
}

public func tokenURL(hostAddress: String, password: String, name: String) -> URL? {
    var comps = URLComponents()
    comps.scheme = "http"
    let parts = hostAddress.split(separator: ":")
    guard let first = parts.first else { return nil }
    comps.host = String(first)
    comps.port = parts.count > 1 ? Int(parts[1]) : 7878
    comps.path = "/token"
    comps.queryItems = [URLQueryItem(name: "pw", value: password), URLQueryItem(name: "name", value: name)]
    return comps.url
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
