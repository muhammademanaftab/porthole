import Foundation

public struct HostConfig: Codable, Equatable, Sendable {
    public var password: String
    public var apiKey: String
    public var apiSecret: String
    public var httpPort: UInt16
    public var livekitPort: Int

    public static let defaultHTTPPort: UInt16 = 7878
    public static let defaultLiveKitPort = 7880

    public init(password: String, apiKey: String, apiSecret: String,
                httpPort: UInt16 = defaultHTTPPort, livekitPort: Int = defaultLiveKitPort) {
        self.password = password; self.apiKey = apiKey; self.apiSecret = apiSecret
        self.httpPort = httpPort; self.livekitPort = livekitPort
    }

    enum CodingKeys: String, CodingKey { case password, apiKey, apiSecret, httpPort, livekitPort }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        password = try c.decode(String.self, forKey: .password)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        apiSecret = try c.decode(String.self, forKey: .apiSecret)
        httpPort = try c.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? Self.defaultHTTPPort
        livekitPort = try c.decodeIfPresent(Int.self, forKey: .livekitPort) ?? Self.defaultLiveKitPort
    }

    public static func fresh() -> HostConfig {
        HostConfig(password: randomSecret(bytes: 9), apiKey: "PH" + randomSecret(bytes: 6), apiSecret: randomSecret(bytes: 32))
    }

    public static func load(in directory: URL) -> (config: HostConfig, backup: URL?) {
        let fm = FileManager.default
        let url = directory.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url), let cfg = try? JSONDecoder().decode(HostConfig.self, from: data) {
            return (cfg, nil)
        }
        let cfg = fresh()
        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            var candidate = directory.appendingPathComponent("config.json.bad")
            var n = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("config.json.bad.\(n)"); n += 1
            }
            guard (try? fm.moveItem(at: url, to: candidate)) != nil else { return (cfg, nil) }
            backup = candidate
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) { _ = writePrivately(data, to: url) }
        return (cfg, backup)
    }
}
