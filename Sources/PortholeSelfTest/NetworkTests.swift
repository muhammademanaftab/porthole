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

    expect("dotted quad: byte order is most significant first", dottedQuad(0xC0A8_0A05), "192.168.10.5")
    expect("dotted quad: zero", dottedQuad(0), "0.0.0.0")
    expect("dotted quad: all ones", dottedQuad(.max), "255.255.255.255")

    expect("viewer link: host, port and URL-safe password", viewerLink(host: "100.64.0.1", port: 7878, password: "abc_-9"),
           "http://100.64.0.1:7878/#pw=abc_-9")
    expect("viewer link: password is percent-encoded", viewerLink(host: "mini", port: 7878, password: "a b&c=d+e#f/ő"),
           "http://mini:7878/#pw=a%20b%26c%3Dd%2Be%23f%2F%C5%91")

    let addresses: [(String, String, Int)] = [
        ("mini", "mini", 7878), ("100.64.0.1:9000", "100.64.0.1", 9000), ("[::1]:9000", "[::1]", 9000),
        ("[fe80::1]", "[fe80::1]", 7878), ("fe80::1", "[fe80::1]", 7878), ("http://mini:9000/", "mini", 9000),
        ("HTTP://mini", "mini", 7878), ("  mini  ", "mini", 7878), ("mini:65535", "mini", 65535),
    ]
    for (input, host, port) in addresses {
        let r = splitHostAddress(input)
        check("host address: \"\(input)\" is \(host) port \(port)", r?.host == host && r?.port == port)
    }
    for input in ["", "mini:abc", "mini:", "mini:0", "mini:65536", "mini:+80", "[::1", "[]", "[::1]x", "[::1]:", ":9000", "http://"] {
        check("host address: \"\(input)\" is rejected", splitHostAddress(input) == nil)
    }

    expect("viewer token URL: bare host uses port 7878", tokenURL(hostAddress: "mini", password: "pw", name: "air")?.absoluteString,
           "http://mini:7878/token?pw=pw&name=air")
    expect("viewer token URL: bracketed IPv6 with port", tokenURL(hostAddress: "[::1]:9000", password: "pw", name: "air")?.absoluteString,
           "http://[::1]:9000/token?pw=pw&name=air")
    let tricky = "a&b=c+d e#f/ő"
    let parsed = tokenURL(hostAddress: "mini", password: tricky, name: "my mac").flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    expect("viewer token URL: query values survive encoding",
           parsed?.queryItems, [URLQueryItem(name: "pw", value: tricky), URLQueryItem(name: "name", value: "my mac")])
    expect("viewer token URL: non-numeric port gives no URL", tokenURL(hostAddress: "mini:abc", password: "pw", name: "a"), nil)

    var d: UInt64 = 1
    var seq: [UInt64] = [d]
    for _ in 0..<6 { d = nextBackoff(d); seq.append(d) }
    expect("backoff: doubles from 1 s and caps at 30 s", seq, [1, 2, 4, 8, 16, 30, 30])
    expect("livekit restart: first restart after 1 s", restartDelay(after: nil, uptime: 0), 1)
    expect("livekit restart: quick crashes back off", restartDelay(after: 8, uptime: 5), 16)
    expect("livekit restart: backoff caps at 30 s", restartDelay(after: 30, uptime: 59.9), 30)
    expect("livekit restart: a run of a minute or more resets to 1 s", restartDelay(after: 16, uptime: 60), 1)

    check("retry: list is asked 10 times, 1 s apart", RetryPolicy.list.times == 10 && RetryPolicy.list.every == 1.0)
    check("retry: open is asked 5 times, 2 s apart", RetryPolicy.open.times == 5 && RetryPolicy.open.every == 2.0)

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
