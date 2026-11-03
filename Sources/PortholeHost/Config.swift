import Foundation
import PortholeCore

extension HostConfig {
    static var directory: URL { portholeSupportDirectory() }

    static func saved() -> HostConfig? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")) else { return nil }
        return try? JSONDecoder().decode(HostConfig.self, from: data)
    }

    static func loadOrCreate() -> HostConfig {
        let (cfg, backup) = load(in: directory)
        if let backup { Log.info("config.json was unreadable; kept it as \(backup.lastPathComponent) and wrote a new one") }
        return cfg
    }
}

func tailscaleAddress() -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
    defer { freeifaddrs(addrs) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        defer { p = cur.pointee.ifa_next }
        guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        var sin = sockaddr_in()
        memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
        let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
        if isTailscaleIPv4(ip) { return dottedQuad(ip) }
    }
    return nil
}
