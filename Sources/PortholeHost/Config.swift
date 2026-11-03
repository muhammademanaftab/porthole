import Foundation
import PortholeCore

struct HostConfig: Codable {
    var password: String
    var apiKey: String
    var apiSecret: String
    var httpPort: UInt16 = 7878
    var livekitPort: Int = 7880

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Porthole", isDirectory: true)
    }

    static func loadOrCreate() -> HostConfig {
        let url = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url), let cfg = try? JSONDecoder().decode(HostConfig.self, from: data) {
            return cfg
        }
        let cfg = HostConfig(password: randomSecret(bytes: 9), apiKey: "PH" + randomSecret(bytes: 6),
                             apiSecret: randomSecret(bytes: 32))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(cfg).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
