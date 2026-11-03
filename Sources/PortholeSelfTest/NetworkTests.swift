import Foundation
import PortholeCore

private func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

func networkTests() {
    let inside: [(UInt32, String)] = [(ip(100, 64, 0, 0), "100.64.0.0"), (ip(100, 100, 7, 9), "100.100.7.9"),
                                      (ip(100, 127, 255, 255), "100.127.255.255")]
    for (addr, name) in inside { check("tailscale: \(name) is in 100.64.0.0/10", isTailscaleIPv4(addr)) }
    let outside: [(UInt32, String)] = [(ip(100, 63, 255, 255), "100.63.255.255"), (ip(100, 128, 0, 0), "100.128.0.0"),
                                       (ip(10, 64, 0, 1), "10.64.0.1"), (ip(192, 168, 1, 1), "192.168.1.1"),
                                       (ip(101, 64, 0, 0), "101.64.0.0"), (0, "0.0.0.0")]
    for (addr, name) in outside { check("tailscale: \(name) is outside 100.64.0.0/10", !isTailscaleIPv4(addr)) }

    expect("dotted quad: tailscale address", dottedQuad(0x6440_0001), "100.64.0.1")
    expect("dotted quad: byte order is most significant first", dottedQuad(0xC0A8_0A05), "192.168.10.5")
    expect("dotted quad: zero", dottedQuad(0), "0.0.0.0")
    expect("dotted quad: all ones", dottedQuad(.max), "255.255.255.255")

    expect("browser link", viewerLink(host: "100.64.0.1", port: 7878, password: "abc_-9"), "http://100.64.0.1:7878/?pw=abc_-9")

    let plain = tokenURL(hostAddress: "mini", password: "pw", name: "air")
    expect("viewer token URL: bare host uses port 7878", plain?.absoluteString, "http://mini:7878/token?pw=pw&name=air")
    expect("viewer token URL: explicit port is used", tokenURL(hostAddress: "100.64.0.1:9000", password: "pw", name: "air")?.port, 9000)
    let tricky = "a&b=c+d e#f/ő"
    let parsed = tokenURL(hostAddress: "mini", password: tricky, name: "my mac").flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    expect("viewer token URL: query values survive encoding",
           parsed?.queryItems, [URLQueryItem(name: "pw", value: tricky), URLQueryItem(name: "name", value: "my mac")])
    expect("viewer token URL: empty host address gives no URL", tokenURL(hostAddress: "", password: "pw", name: "a"), nil)

    let yaml = [
        "port: 7880",
        "bind_addresses:",
        "  - \"\"",
        "rtc:",
        "  tcp_port: 7881",
        "  udp_port: 7882",
        "  use_external_ip: false",
        "  enable_loopback_candidate: true",
        "keys:",
        "  PHkey: s3cret",
        "logging:",
        "  level: warn",
    ].joined(separator: "\n")
    expect("livekit config: exact YAML with tcp/udp on the next two ports",
           liveKitConfigYAML(port: 7880, apiKey: "PHkey", apiSecret: "s3cret"), yaml)
    let moved = liveKitConfigYAML(port: 9000, apiKey: "k", apiSecret: "v")
    check("livekit config: ports follow the configured port",
          moved.hasPrefix("port: 9000\n") && moved.contains("\n  tcp_port: 9001\n") && moved.contains("\n  udp_port: 9002\n"))
}
