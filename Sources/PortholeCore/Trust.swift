import CryptoKit
import Foundation

public func portholeSupportDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let home = environment["PORTHOLE_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Porthole", isDirectory: true)
}

public func writePrivately(_ data: Data, to url: URL) -> Bool {
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return false }
    let written = data.withUnsafeBytes { buf -> Bool in
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    let synced = fsync(fd) == 0
    close(fd)
    guard written, synced, rename(temp.path, url.path) == 0 else { unlink(temp.path); return false }
    return true
}

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public var id: String

    public init(id: String) { self.id = id }

    public static let idLength = 16
    public static let fileName = "identity.json"

    public static func makeID(random: () -> UInt8 = { UInt8.random(in: 0...255) }) -> String {
        (0..<(idLength / 2)).map { _ in String(format: "%02x", random()) }.joined()
    }

    public static func isValidID(_ s: String) -> Bool {
        s.utf8.count == idLength && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func loadOrCreate(in directory: URL, makeID: () -> String = { makeID() }) -> DeviceIdentity {
        let url = directory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url), let id = try? JSONDecoder().decode(DeviceIdentity.self, from: data), isValidID(id.id) {
            return id
        }
        let fresh = DeviceIdentity(id: makeID())
        if let data = try? JSONEncoder().encode(fresh) { _ = writePrivately(data, to: url) }
        return fresh
    }
}

public func cleanDeviceName(_ s: String?) -> String {
    let kept = (s ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let trimmed = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Mac" : String(trimmed.prefix(64))
}

public func secretDigest(_ secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
}

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}

public struct PairedDevice: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var secretHash: String
    public var pairedAt: Date

    public init(id: String, name: String, secretHash: String, pairedAt: Date) {
        self.id = id; self.name = name; self.secretHash = secretHash; self.pairedAt = pairedAt
    }

    public func accepts(_ secret: String) -> Bool {
        !secret.isEmpty && constantTimeEqual(secretDigest(secret), secretHash)
    }
}

public enum PairedDevices {
    struct File: Codable { var version: Int; var devices: [PairedDevice] }

    public static func encode(_ devices: [PairedDevice]) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(File(version: 1, devices: devices))) ?? Data()
    }

    public static func decode(_ data: Data) -> [PairedDevice]? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(File.self, from: data), file.version >= 1 else { return nil }
        return file.devices.filter { DeviceIdentity.isValidID($0.id) && !$0.secretHash.isEmpty }
    }

    public static func adding(_ device: PairedDevice, to list: [PairedDevice]) -> [PairedDevice] {
        list.filter { $0.id != device.id } + [device]
    }
}

public enum UnpairMatch: Equatable, Sendable {
    case found(PairedDevice)
    case none
    case ambiguous([PairedDevice])
}

public func findPaired(_ who: String, in devices: [PairedDevice]) -> UnpairMatch {
    let q = who.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return .none }
    if let exact = devices.first(where: { $0.id == q.lowercased() }) { return .found(exact) }
    let byName = devices.filter { normalizedHostName($0.name) == normalizedHostName(q) }
    if byName.count == 1 { return .found(byName[0]) }
    if byName.count > 1 { return .ambiguous(byName) }
    let byPrefix = q.count >= 4 ? devices.filter { $0.id.hasPrefix(q.lowercased()) } : []
    if byPrefix.count == 1 { return .found(byPrefix[0]) }
    return byPrefix.isEmpty ? .none : .ambiguous(byPrefix)
}

public final class TrustStore: @unchecked Sendable {
    public static let fileName = "paired.json"
    public let url: URL
    private let lock = NSLock()
    private let clock: () -> Date
    private var cache: (stamp: FileStamp?, devices: [PairedDevice])?
    public private(set) var fileReads = 0

    struct FileStamp: Equatable { var sec: Int; var nsec: Int; var size: Int64; var inode: UInt64 }

    public init(directory: URL, clock: @escaping () -> Date = Date.init) {
        url = directory.appendingPathComponent(Self.fileName)
        self.clock = clock
    }

    private func stamp() -> FileStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return FileStamp(sec: st.st_mtimespec.tv_sec, nsec: st.st_mtimespec.tv_nsec, size: Int64(st.st_size), inode: UInt64(st.st_ino))
    }

    private func read() -> [PairedDevice] {
        let now = stamp()
        if let cache, cache.stamp == now { return cache.devices }
        fileReads += 1
        let devices = (try? Data(contentsOf: url)).flatMap(PairedDevices.decode) ?? []
        cache = (now, devices)
        return devices
    }

    private func store(_ devices: [PairedDevice]) -> Bool {
        cache = nil
        return writePrivately(PairedDevices.encode(devices), to: url)
    }

    public func devices() -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    public func pair(id: String, name: String, secret: String = randomSecret(bytes: 24)) -> String? {
        guard DeviceIdentity.isValidID(id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let device = PairedDevice(id: id, name: cleanDeviceName(name), secretHash: secretDigest(secret), pairedAt: clock())
        return store(PairedDevices.adding(device, to: read())) ? secret : nil
    }

    public func verify(id: String, secret: String) -> PairedDevice? {
        lock.lock(); defer { lock.unlock() }
        return read().first { $0.id == id && $0.accepts(secret) }
    }

    public func isPaired(_ id: String) -> Bool {
        devices().contains { $0.id == id }
    }

    public func unpair(_ who: String) -> UnpairMatch {
        lock.lock(); defer { lock.unlock() }
        let list = read()
        let match = findPaired(who, in: list)
        guard case .found(let device) = match else { return match }
        guard store(list.filter { $0.id != device.id }) else { return .none }
        return match
    }
}

public enum TokenAuth: Equatable, Sendable {
    case password
    case device(PairedDevice)
    case unpaired
    case refused
}

public func authorizeToken(query: [String: String], password: String, verify: (String, String) -> PairedDevice?) -> TokenAuth {
    let device = query["device"] ?? ""
    if !device.isEmpty {
        if let found = verify(device, query["secret"] ?? "") { return .device(found) }
        if let pw = query["pw"], constantTimeEqual(pw, password) { return .password }
        return .unpaired
    }
    return query["pw"].map { constantTimeEqual($0, password) } == true ? .password : .refused
}

public func pairedIdentity(name: String?, suffix: String, device: String) -> String {
    "\(WebRoutes.viewerIdentity(name: name, suffix: suffix)).\(device)"
}

public func deviceID(fromIdentity identity: String) -> String? {
    guard identity.hasPrefix("view-"), let dot = identity.lastIndex(of: ".") else { return nil }
    let id = String(identity[identity.index(after: dot)...])
    return DeviceIdentity.isValidID(id) ? id : nil
}

public func revokedIdentities(_ identities: [String], isPaired: (String) -> Bool) -> [String] {
    identities.filter { deviceID(fromIdentity: $0).map { !isPaired($0) } ?? false }
}

public struct RevokedDevices: Equatable, Sendable {
    public private(set) var ids: Set<String> = []

    public init() {}

    public mutating func revoke(_ device: String) { ids.insert(device) }

    public mutating func accepts(_ identity: String, isPaired: (String) -> Bool) -> Bool {
        guard let device = deviceID(fromIdentity: identity), ids.contains(device) else { return true }
        guard isPaired(device) else { return false }
        ids.remove(device)
        return true
    }
}

public func identities(_ identities: [String], of device: String) -> [String] {
    identities.filter { deviceID(fromIdentity: $0) == device }
}

public enum ViewerCredential: Equatable, Sendable {
    case password(String)
    case device(id: String, secret: String)
}

public func tokenURL(hostAddress: String, credential: ViewerCredential, name: String) -> URL? {
    switch credential {
    case .password(let pw): return tokenURL(hostAddress: hostAddress, password: pw, name: name)
    case .device(let id, let secret):
        return hostURL(hostAddress, path: "/token", ["device": id, "secret": secret, "name": name])
    }
}

func hostURL(_ hostAddress: String, path: String, _ query: KeyValuePairs<String, String>) -> URL? {
    guard let (host, port) = splitHostAddress(hostAddress) else { return nil }
    var comps = URLComponents()
    comps.scheme = "http"
    comps.host = host
    comps.port = port
    comps.path = path
    comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    return comps.url
}

public func pairRequestURL(hostAddress: String, device: String, name: String) -> URL? {
    hostURL(hostAddress, path: "/pair/request", ["device": device, "name": name])
}

public enum TokenReply: Equatable, Sendable {
    case ok(url: String, token: String)
    case unpaired(String)
    case refused(String)
}

public func parseTokenReply(status: Int, body: Data) -> TokenReply {
    let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    if status == 200, let url = obj?["url"] as? String, let token = obj?["token"] as? String { return .ok(url: url, token: token) }
    let msg = obj?["error"] as? String
    if obj?["unpaired"] as? Bool == true {
        return .unpaired(msg ?? "This Mac is no longer paired with the host.")
    }
    return .refused(msg == "wrong password" || msg == nil ? "The host refused the password, or isn't running." : msg!)
}

public enum PairRequestReply: Equatable, Sendable {
    case shown(host: String)
    case older
    case refused(String)
}

public func parsePairRequestReply(status: Int, body: Data) -> PairRequestReply {
    let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    if status == 200, obj?["requested"] as? Bool == true { return .shown(host: cleanDeviceName(obj?["host"] as? String)) }
    if status == 404 { return .older }
    if let msg = obj?["error"] as? String, !msg.isEmpty { return .refused(msg) }
    return .refused("The host didn't take the pairing request (HTTP \(status)).")
}

public struct PairedHost: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var addresses: [String]

    public init(id: String, name: String, addresses: [String]) {
        self.id = id; self.name = name; self.addresses = addresses
    }
}

public struct ViewerTrust: Codable, Equatable, Sendable {
    public var hosts: [PairedHost]

    public init(hosts: [PairedHost] = []) { self.hosts = hosts }

    public static func decode(_ data: Data?) -> ViewerTrust {
        data.flatMap { try? JSONDecoder().decode(ViewerTrust.self, from: $0) } ?? ViewerTrust()
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public func host(forAddress address: String) -> PairedHost? {
        guard let key = savedPasswordKey(address) else { return nil }
        return hosts.first { $0.addresses.contains { savedPasswordKey($0) == key } }
    }

    public func host(for discovered: DiscoveredHost) -> PairedHost? {
        discovered.addresses.lazy.compactMap { host(forAddress: $0) }.first
    }

    public mutating func remember(id: String, name: String, address: String) {
        let key = savedPasswordKey(address)
        var others = hosts.filter { $0.id != id }
        for i in others.indices { others[i].addresses.removeAll { savedPasswordKey($0) == key } }
        let old = hosts.first { $0.id == id }?.addresses.filter { savedPasswordKey($0) != key } ?? []
        hosts = [PairedHost(id: id, name: cleanDeviceName(name), addresses: [address] + old)] + others.filter { !$0.addresses.isEmpty }
    }

    public func addresses(of id: String?) -> [String] {
        guard let id else { return [] }
        return hosts.first { $0.id == id }?.addresses ?? []
    }

    public mutating func forget(id: String) {
        hosts.removeAll { $0.id == id }
    }
}

public func hostKeyForTrust(hostID: String?, address: String) -> String {
    if let hostID, !hostID.isEmpty { return hostID }
    return "addr:" + (savedPasswordKey(address) ?? address.lowercased())
}

public enum HostPairCommand: Equatable, Sendable {
    case app
    case paircode
    case devices
    case unpair(String)
    case usage(error: String?)
}

public let hostUsage = """
usage: porthole-host [command]
  (no command)     run Porthole Host
  paircode         print this Mac's current pairing code (asks the running host; works over SSH)
  devices          print this Mac's device ID and the Macs paired with it
  unpair <name|id> forget a paired Mac; it loses access immediately
"""

public func hostPairCommand(_ args: [String]) -> HostPairCommand {
    guard let first = args.first else { return .app }
    switch first {
    case "paircode": return args.count == 1 ? .paircode : .usage(error: "paircode takes no arguments")
    case "devices": return args.count == 1 ? .devices : .usage(error: "devices takes no arguments")
    case "unpair":
        guard args.count >= 2 else { return .usage(error: "unpair needs a name or device ID") }
        let who = args.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return who.isEmpty ? .usage(error: "unpair needs a name or device ID") : .unpair(who)
    case "help", "-h", "--help": return .usage(error: nil)
    default: return .app
    }
}

public enum ViewerCommand: Equatable, Sendable {
    case app
    case request(host: String)
    case pair(host: String, code: String)
    case machines(json: Bool)
    case list(host: String, json: Bool)
    case open(host: String, target: String)
    case recent(Int?)
    case usage(error: String?)
}

public let viewerUsage = """
usage: porthole-view [command]
  (no command)        open Porthole
  <host> [password]   open Porthole and connect to host
  request <host>      ask the host to show a pairing code for this Mac
  pair <host> <code>  pair with the host using the code it shows; this Mac may view it from then on
  machines [--json]   Porthole hosts on the tailnet and the local network
  ls <host> [--json]  the host's windows (uses the saved pairing or password)
  open <host> <windowID|title>  open Porthole on one window
  recent [n]          recent portals, or reopen entry n
  gallery [screen]    show one screen with sample data and no network, for design review
"""

public func viewerCommand(_ args: [String]) -> ViewerCommand {
    guard let first = args.first else { return .app }
    switch first {
    case "request":
        guard args.count == 2 else { return args.count == 1 ? .usage(error: "request needs a host") : .app }
        return .request(host: args[1])
    case "pair":
        guard args.count == 3 else { return args.count < 3 ? .usage(error: "pair needs a host and a code") : .app }
        guard looksLikePairingCode(args[2]) else { return .usage(error: "\"\(args[2])\" isn't a 6-digit pairing code") }
        return .pair(host: args[1], code: normalizePairingCode(args[2]))
    case "machines":
        let rest = args.dropFirst()
        guard rest.allSatisfy({ $0 == "--json" }) else { return .usage(error: "machines takes only --json") }
        return .machines(json: !rest.isEmpty)
    case "ls", "list":
        let rest = Array(args.dropFirst())
        let hosts = rest.filter { $0 != "--json" }
        guard hosts.count == 1, !hosts[0].hasPrefix("-") else { return .usage(error: "ls needs a host") }
        return .list(host: hosts[0], json: rest.contains("--json"))
    case "open":
        guard args.count == 3, !args[2].trimmingCharacters(in: .whitespaces).isEmpty else {
            return .usage(error: "open needs a host and a window ID or part of its title")
        }
        return .open(host: args[1], target: args[2])
    case "recent":
        guard args.count <= 2 else { return .usage(error: "recent takes one entry number") }
        guard args.count == 2 else { return .recent(nil) }
        guard let n = Int(args[1]), n >= 1 else { return .usage(error: "recent takes an entry number (1 is the newest)") }
        return .recent(n)
    case "help", "-h", "--help": return .usage(error: nil)
    default: return .app
    }
}

public func isLocalHostHeader(_ header: String) -> Bool {
    ["127.0.0.1", "localhost", "[::1]"].contains(WebRoutes.hostname(from: header).lowercased())
}

public let localRouteHeader = "X-Porthole-Local"

public enum LocalSecret {
    public static let fileName = "local-secret"

    public static func read(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count >= 32 ? s : nil
    }

    public static func create(in directory: URL, secret: String = randomSecret(bytes: 32)) -> String? {
        writePrivately(Data(secret.utf8), to: directory.appendingPathComponent(fileName)) ? secret : nil
    }
}

public func showsPairingWindow(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["PORTHOLE_PAIR_HEADLESS"] != "1"
}

public func localURL(port: UInt16, path: String, _ query: KeyValuePairs<String, String> = [:]) -> URL? {
    hostURL("127.0.0.1:\(port)", path: path, query)
}

public func removeRetryDelay(status: Int?, attempt: Int) -> TimeInterval? {
    if let status, (200..<300).contains(status) || status == 404 { return nil }
    let delays: [TimeInterval] = [0.5, 1, 2, 4]
    return attempt <= delays.count ? delays[attempt - 1] : nil
}

public func removeParticipantRequest(livekitPort: Int, token: String, room: String, identity: String) -> URLRequest? {
    guard let url = URL(string: "http://127.0.0.1:\(livekitPort)/twirp/livekit.RoomService/RemoveParticipant"),
          let body = try? JSONSerialization.data(withJSONObject: ["room": room, "identity": identity], options: [.sortedKeys]) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.httpBody = body
    req.timeoutInterval = 5
    return req
}
