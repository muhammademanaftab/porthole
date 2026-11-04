import Foundation

public struct RecentPortal: Codable, Equatable, Sendable {
    public var host: String
    public var hostName: String
    public var windowID: UInt32
    public var title: String
    public var app: String
    public var bundle: String?
    public var time: Date

    public init(host: String, hostName: String, windowID: UInt32, title: String, app: String, bundle: String?, time: Date) {
        self.host = host; self.hostName = hostName; self.windowID = windowID; self.title = title
        self.app = app; self.bundle = bundle; self.time = time
    }

    public func same(as other: RecentPortal) -> Bool {
        host == other.host && (windowID == other.windowID || (app == other.app && title == other.title))
    }
}

public enum RecentPortals {
    public static let fileName = "recent-portals.json"
    public static let maxCount = 20

    public static func adding(_ p: RecentPortal, to list: [RecentPortal]) -> [RecentPortal] {
        Array(([p] + list.filter { !$0.same(as: p) }).prefix(maxCount))
    }

    public static func decode(_ data: Data?) -> [RecentPortal] {
        guard let data else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([RecentPortal].self, from: data)) ?? []
    }

    public static func encode(_ list: [RecentPortal]) -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(list)) ?? Data("[]".utf8)
    }

    public static func load(in dir: URL) -> [RecentPortal] {
        decode(try? Data(contentsOf: dir.appendingPathComponent(fileName)))
    }

    @discardableResult
    public static func record(_ p: RecentPortal, in dir: URL) -> Bool {
        writePrivately(encode(adding(p, to: load(in: dir))), to: dir.appendingPathComponent(fileName))
    }

    public static func match(_ p: RecentPortal, in list: [WindowInfo]) -> WindowInfo? {
        if let w = list.first(where: { $0.id == p.windowID && $0.app == p.app }) { return w }
        if let w = list.first(where: { $0.app == p.app && $0.title == p.title }) { return w }
        let sameTitle = list.filter { !p.title.isEmpty && $0.title == p.title }
        if sameTitle.count == 1 { return sameTitle[0] }
        let sameApp = list.filter { $0.app == p.app }
        return sameApp.count == 1 ? sameApp[0] : nil
    }

    public static func render(_ list: [RecentPortal], now: Date = Date()) -> String {
        guard !list.isEmpty else { return "No recent portals yet. Open a window in Porthole and it shows up here." }
        return list.enumerated().map { i, p in
            let ago = formatDuration(now.timeIntervalSince(p.time))
            let title = p.title.isEmpty ? p.app : "\(p.app) — \(p.title)"
            return "\(String(i + 1).leftPad(3))  \(title)\n     on \(p.hostName) (\(p.host)), window \(p.windowID), \(ago) ago"
        }.joined(separator: "\n")
    }
}

public enum WindowPick: Equatable, Sendable {
    case found(WindowInfo)
    case none
    case ambiguous([WindowInfo])
}

public func pickWindow(_ target: String, in list: [WindowInfo]) -> WindowPick {
    let t = target.trimmingCharacters(in: .whitespaces)
    let digits = t.hasPrefix("id:") ? String(t.dropFirst(3)) : t
    if let id = UInt32(digits), let w = list.first(where: { $0.id == id }) { return .found(w) }
    if t.hasPrefix("id:") { return .none }
    let needle = t.lowercased()
    guard !needle.isEmpty else { return .none }
    let exact = list.filter { $0.title.lowercased() == needle || "\($0.app) \($0.title)".lowercased() == needle }
    if exact.count == 1 { return .found(exact[0]) }
    let partial = list.filter { "\($0.app) \($0.title)".lowercased().contains(needle) }
    switch partial.count {
    case 0: return .none
    case 1: return .found(partial[0])
    default: return .ambiguous(partial)
    }
}

public func autoOpenWindow(_ match: String?, in list: [WindowInfo]) -> WindowInfo? {
    guard let m = match?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { return nil }
    if m.hasPrefix("id:") {
        guard let id = UInt32(m.dropFirst(3)) else { return nil }
        return list.first { $0.id == id }
    }
    let needle = m.lowercased()
    return list.first { "\($0.app) \($0.title)".lowercased().contains(needle) }
}

public func resolveHostAddress(_ s: String, trust: ViewerTrust, known: [KnownHost]) -> String {
    if trust.host(forAddress: s) != nil || known.contains(where: { $0.address == s }) { return s }
    let lower = s.lowercased()
    if let h = trust.hosts.first(where: { $0.name.lowercased() == lower }), let a = h.addresses.first { return a }
    if let k = known.first(where: { $0.name.lowercased() == lower }) { return k.address }
    return s
}

public func renderWindowList(_ list: [WindowInfo]) -> String {
    guard !list.isEmpty else { return "No shareable windows." }
    let width = min(28, list.map(\.app.count).max() ?? 8)
    return list.map { w in
        "\(String(w.id).leftPad(7))  \(w.app.padding(toLength: width, withPad: " ", startingAt: 0))  \(w.title.isEmpty ? "(untitled)" : w.title)  \(Int(w.w))x\(Int(w.h))"
    }.joined(separator: "\n")
}
