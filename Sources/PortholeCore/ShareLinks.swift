import Foundation

public struct ShareLink: Codable, Equatable, Sendable {
    public var id: String
    public var tokenHash: String
    public var window: UInt32?
    public var label: String
    public var control: Bool
    public var created: Date
    public var expires: Date

    public init(id: String, tokenHash: String, window: UInt32?, label: String, control: Bool, created: Date, expires: Date) {
        self.id = id; self.tokenHash = tokenHash; self.window = window; self.label = label
        self.control = control; self.created = created; self.expires = expires
    }

    public var isPicker: Bool { window == nil }

    public func isLive(at now: Date) -> Bool { now < expires }

    public func accepts(_ token: String) -> Bool {
        !token.isEmpty && constantTimeEqual(secretDigest(token), tokenHash)
    }

    public var kindLabel: String { isPicker ? "Window picker" : "One window" }

    public var accessLabel: String { control ? "May control" : "View only" }
}

public enum ShareLinks {
    public static let fileName = "share-links.json"
    public static let defaultTTL: TimeInterval = 24 * 3600
    public static let ttlChoices: [TimeInterval] = [3600, 8 * 3600, 24 * 3600, 7 * 24 * 3600]
    public static let maxLinks = 50
    public static let pickerLabel = "All windows (picker)"

    struct File: Codable { var version: Int; var links: [ShareLink] }

    public static func encode(_ links: [ShareLink]) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(File(version: 1, links: links))) ?? Data()
    }

    public static func decode(_ data: Data) -> [ShareLink]? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(File.self, from: data), file.version >= 1 else { return nil }
        return file.links.filter { isValidID($0.id) && !$0.tokenHash.isEmpty }
    }

    public static func isValidID(_ s: String) -> Bool {
        s.utf8.count == 8 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func ttlLabel(_ ttl: TimeInterval) -> String {
        let hours = Int(ttl / 3600)
        if hours % 24 == 0 { return hours == 24 ? "24 hours" : "\(hours / 24) days" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    public static func expiryLabel(_ link: ShareLink, now: Date) -> String {
        let left = link.expires.timeIntervalSince(now)
        guard left > 0 else { return "expired" }
        return "expires in \(formatDuration(left))"
    }
}

public final class ShareLinkStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let clock: () -> Date
    private var cache: [ShareLink]?

    public init(directory: URL, clock: @escaping () -> Date = Date.init) {
        url = directory.appendingPathComponent(ShareLinks.fileName)
        self.clock = clock
    }

    private func read() -> [ShareLink] {
        if let cache { return cache }
        let links = (try? Data(contentsOf: url)).flatMap(ShareLinks.decode) ?? []
        cache = links
        return links
    }

    private func store(_ links: [ShareLink]) -> Bool {
        cache = nil
        let ok = writePrivately(ShareLinks.encode(links), to: url)
        if ok { cache = links }
        return ok
    }

    public func mint(window: UInt32?, label: String, control: Bool, ttl: TimeInterval = ShareLinks.defaultTTL,
                     token: String = randomSecret(bytes: 24), id: String? = nil) -> (link: ShareLink, token: String)? {
        let now = clock()
        let ttl = ttl.isNaN ? ShareLinks.defaultTTL : min(max(ttl, 60), 30 * 24 * 3600)
        lock.lock(); defer { lock.unlock() }
        var live = read().filter { $0.isLive(at: now) }
        var linkID = id ?? DeviceIdentity.makeID().prefix(8).description
        while live.contains(where: { $0.id == linkID }) { linkID = DeviceIdentity.makeID().prefix(8).description }
        let clean = cleanDeviceName(label.isEmpty ? (window == nil ? ShareLinks.pickerLabel : "Window") : label)
        let link = ShareLink(id: linkID, tokenHash: secretDigest(token), window: window, label: String(clean.prefix(80)),
                             control: control, created: now, expires: now.addingTimeInterval(ttl))
        live.append(link)
        if live.count > ShareLinks.maxLinks { live.removeFirst(live.count - ShareLinks.maxLinks) }
        return store(live) ? (link, token) : nil
    }

    public func verify(_ token: String) -> ShareLink? {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        return read().first { $0.isLive(at: now) && $0.accepts(token) }
    }

    public func link(id: String) -> ShareLink? {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        return read().first { $0.id == id && $0.isLive(at: now) }
    }

    public func links() -> [ShareLink] {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        let all = read()
        let live = all.filter { $0.isLive(at: now) }
        if live.count != all.count { _ = store(live) }
        return live.sorted { $0.created > $1.created }
    }

    @discardableResult
    public func revoke(id: String) -> ShareLink? {
        lock.lock(); defer { lock.unlock() }
        let all = read()
        guard let gone = all.first(where: { $0.id == id }) else { return nil }
        return store(all.filter { $0.id != id }) ? gone : nil
    }

    @discardableResult
    public func revokeAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = read().count
        return store([]) ? n : 0
    }
}

public enum GuestIdentity {
    public static let prefix = "guest-"

    public static func isGuest(_ identity: String) -> Bool { identity.hasPrefix(prefix) }

    public static func cleanClient(_ s: String?) -> String? {
        guard let s, (6...24).contains(s.utf8.count),
              s.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else { return nil }
        return s
    }

    public static func make(link: String, client: String?, random: () -> String = { randomSecret(bytes: 6).lowercased().filter { $0.isLetter || $0.isNumber } }) -> String {
        let c = cleanClient(client) ?? String(random().prefix(8))
        return "\(prefix)\(link)-\(c.isEmpty ? "x" : c)"
    }

    public static func linkID(_ identity: String) -> String? {
        guard isGuest(identity) else { return nil }
        let rest = identity.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let id = String(rest[..<dash])
        return ShareLinks.isValidID(id) ? id : nil
    }
}

public enum GuestRequest: Equatable, Sendable {
    case list
    case open(win: UInt32, parent: UInt32?)
    case close
    case icon(win: UInt32)
    case thumbnails
    case input(win: UInt32)
    case restart
    case ask
    case clipboardFromGuest
    case clipboardToGuest
    case pair
}

public enum GuestAccess {
    public static func allows(_ request: GuestRequest, link: ShareLink, controlling: Bool) -> Bool {
        switch request {
        case .list, .close, .ask: return true
        case .open(let win, let parent): return covers(link, win: win, parent: parent)
        case .icon(let win): return covers(link, win: win, parent: nil)
        case .thumbnails: return link.isPicker
        case .input(let win): return controlling && !WholeMac.isScreen(win)
        case .clipboardFromGuest: return controlling
        case .clipboardToGuest, .restart, .pair: return false
        }
    }

    public static func covers(_ link: ShareLink, win: UInt32, parent: UInt32?) -> Bool {
        guard !WholeMac.isScreen(win), !(parent.map(WholeMac.isScreen) ?? false) else { return false }
        guard let only = link.window else { return true }
        return win == only || parent == only
    }

    public static func visible(_ list: [WindowInfo], link: ShareLink) -> [WindowInfo] {
        let windows = list.filter { !WholeMac.isScreen($0.id) }
        guard let only = link.window else { return windows }
        return windows.filter { $0.id == only }
    }

    public static func request(for m: Message, parent: (UInt32) -> UInt32?) -> GuestRequest? {
        switch m.t {
        case .list: return .list
        case .open: return m.win.map { .open(win: $0, parent: parent($0)) }
        case .close: return .close
        case .icon: return m.win.map { .icon(win: $0) }
        case .thumb: return .thumbnails
        case .key, .text, .mouse, .scroll, .resize: return m.win.map { .input(win: $0) }
        case .restart: return .restart
        case .ask: return .ask
        default: return nil
        }
    }
}

public enum RemoteControlSwitch {
    public static let settingKey = "sharing.allowRemoteControl"
    public static let envKey = "PORTHOLE_SHARE_ALLOW_CONTROL"

    public static func enabled(stored: Any?, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch environment[envKey] {
        case "1": return true
        case "0": return false
        default: return (stored as? Bool) ?? false
        }
    }

    public static func overridden(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ["0", "1"].contains(environment[envKey] ?? "")
    }

    public static func controlsAtOnce(_ link: ShareLink, switchOn: Bool) -> Bool { switchOn && link.control }

    public enum AskAnswer: Equatable, Sendable { case granted, alreadyControlling, prompt }

    public static func answer(ask link: ShareLink, switchOn: Bool, controlling: Bool) -> AskAnswer {
        if controlling { return .alreadyControlling }
        return switchOn ? .granted : .prompt
    }
}

public struct TrackGrant: Equatable, Sendable {
    public var participantSid: String
    public var allTracks: Bool
    public var trackSids: [String]

    public init(participantSid: String, allTracks: Bool, trackSids: [String]) {
        self.participantSid = participantSid; self.allTracks = allTracks; self.trackSids = trackSids
    }
}

public struct TrackGrantPlan: Equatable, Sendable {
    public var allParticipantsAllowed: Bool
    public var grants: [TrackGrant]

    public init(allParticipantsAllowed: Bool, grants: [TrackGrant]) {
        self.allParticipantsAllowed = allParticipantsAllowed; self.grants = grants
    }

    public struct Participant: Equatable, Sendable {
        public var sid: String
        public var identity: String
        public init(sid: String, identity: String) { self.sid = sid; self.identity = identity }
    }

    public struct Track: Equatable, Sendable {
        public var sid: String
        public var name: String
        public init(sid: String, name: String) { self.sid = sid; self.name = name }
    }

    public static func make(participants: [Participant], tracks: [Track], link: (String) -> ShareLink?,
                            parent: (UInt32) -> UInt32?, sharedParents: Set<UInt32>, linksExist: Bool = false) -> TrackGrantPlan {
        guard linksExist || participants.contains(where: { GuestIdentity.isGuest($0.identity) }) else {
            return TrackGrantPlan(allParticipantsAllowed: true, grants: [])
        }
        let grants = participants.sorted { $0.identity < $1.identity }.map { p -> TrackGrant in
            guard GuestIdentity.isGuest(p.identity) else { return TrackGrant(participantSid: p.sid, allTracks: true, trackSids: []) }
            guard let l = link(p.identity) else { return TrackGrant(participantSid: p.sid, allTracks: false, trackSids: []) }
            let sids = tracks.filter { t in
                if let win = Message.windowID(fromTrackName: t.name) { return GuestAccess.covers(l, win: win, parent: parent(win)) }
                if Message.isAudioTrackName(t.name) { return audioAllowed(l, sharedParents: sharedParents) }
                return false
            }.map(\.sid).sorted()
            return TrackGrant(participantSid: p.sid, allTracks: false, trackSids: sids)
        }
        return TrackGrantPlan(allParticipantsAllowed: false, grants: grants)
    }

    public static func audioAllowed(_ link: ShareLink, sharedParents: Set<UInt32>) -> Bool {
        guard let only = link.window else { return true }
        return sharedParents.subtracting([only]).isEmpty
    }
}

public enum ShareURLs {
    public struct Item: Equatable, Sendable {
        public var kind: String
        public var url: String
    }

    public static func path(token: String, window: UInt32?) -> String {
        let t = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? token
        return window.map { "/?share=\(t)&win=\($0)" } ?? "/?share=\(t)"
    }

    public static func make(token: String, window: UInt32?, lan: String?, tailnet: String?, port: UInt16, wifiOnly: Bool) -> [Item] {
        var out: [Item] = []
        if let lan { out.append(Item(kind: "wifi", url: "http://\(lan):\(port)\(path(token: token, window: window))")) }
        if !wifiOnly, let tailnet, tailnet != lan { out.append(Item(kind: "tailnet", url: "http://\(tailnet):\(port)\(path(token: token, window: window))")) }
        return out
    }
}

public struct NetworkInterface: Equatable, Sendable {
    public var name: String
    public var ip: UInt32
    public init(name: String, ip: UInt32) { self.name = name; self.ip = ip }
}

public func isPrivateLANIPv4(_ ip: UInt32) -> Bool {
    let a = ip >> 24, b = (ip >> 16) & 0xff
    return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
}

public func pickLANAddress(_ interfaces: [NetworkInterface]) -> String? {
    let candidates = interfaces.filter { isPrivateLANIPv4($0.ip) && !isTailscaleIPv4($0.ip) && !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("bridge") }
    let best = candidates.first { $0.name == "en0" } ?? candidates.first { $0.name.hasPrefix("en") } ?? candidates.first
    return best.map { dottedQuad($0.ip) }
}

public enum ShareText {
    public static func minted(_ body: [String: Any], now: Date = Date()) -> String {
        let links = body["links"] as? [[String: Any]] ?? []
        let control = body["control"] as? Bool ?? false
        let allow = body["allowRemoteControl"] as? Bool ?? false
        var lines: [String] = []
        for l in links {
            let kind = (l["kind"] as? String) == "wifi" ? "This Wi-Fi" : "Tailnet"
            lines.append("\(kind.padding(toLength: 11, withPad: " ", startingAt: 0)) \(l["url"] as? String ?? "")")
        }
        if let warning = body["warning"] as? String { lines.append(warning) }
        let what = body["window"] != nil ? (body["label"] as? String ?? "one window") : "the window picker"
        var access = control ? "guests may type and click" : "view only; a guest can ask to control"
        if control && !allow { access = "a control link, but Allow Remote Control is off, so guests watch and ask" }
        if !control && allow { access = "view only; Allow Remote Control is on, so a guest who asks may control at once" }
        let expires = (body["expires"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let left = expires.map { formatDuration($0.timeIntervalSince(now)) } ?? "?"
        let id = body["id"] as? String ?? "?"
        lines.append("Shares \(what): \(access). Expires in \(left). Revoke with: porthole share --revoke \(id)")
        return lines.joined(separator: "\n")
    }

    public static func list(_ links: [[String: Any]], allowControl: Bool, now: Date = Date()) -> String {
        var lines = ["Allow Remote Control: \(allowControl ? "on" : "off")"]
        guard !links.isEmpty else { return (lines + ["No share links."]).joined(separator: "\n") }
        for l in links {
            let expires = (l["expires"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let left = expires.map { formatDuration($0.timeIntervalSince(now)) } ?? "?"
            let access = (l["control"] as? Bool ?? false) ? "control" : "view"
            lines.append("\(l["id"] as? String ?? "?")  \(access.padding(toLength: 7, withPad: " ", startingAt: 0)) \(left.padding(toLength: 8, withPad: " ", startingAt: 0)) \(l["label"] as? String ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}

public struct ShareOptions: Equatable, Sendable {
    public var window: String?
    public var control = false
    public var wifiOnly = false
    public var list = false
    public var revoke: String?
    public var ttl: TimeInterval?
    public var json = false
    public init() {}
}
