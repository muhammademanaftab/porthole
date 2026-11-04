import Foundation

public struct LogQuery {
    public var category: LogCategory?
    public var level: LogLevel?
    public var role: String?
    public var since: Date?
    public var pattern: NSRegularExpression?
    public var limit: Int?

    public init(category: LogCategory? = nil, level: LogLevel? = nil, role: String? = nil, since: Date? = nil,
                pattern: String? = nil, limit: Int? = nil) {
        self.category = category; self.level = level; self.role = role; self.since = since; self.limit = limit
        self.pattern = pattern.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    public init(_ o: LogOptions, now: Date = Date()) {
        var grep: String?
        if case .grep(let re) = o.mode { grep = re }
        let defaultLimit: Int? = { switch o.mode { case .grep, .stats: return nil; default: return 50 } }()
        self.init(category: o.category, level: o.level, role: o.role, since: o.since.map { now.addingTimeInterval(-$0) },
                  pattern: grep, limit: o.count ?? defaultLimit)
    }

    public func matches(_ line: LogLine) -> Bool {
        if let category, line.category != category { return false }
        if let level, line.level < level { return false }
        if let role, line.role != role { return false }
        if let since {
            guard let t = line.time, t >= since else { return false }
        }
        if let pattern {
            let s = line.formatted
            guard pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil else { return false }
        }
        return true
    }

    public func select(_ lines: [LogLine]) -> [LogLine] {
        let kept = lines.filter(matches)
        guard let limit, kept.count > limit else { return kept }
        return Array(kept.suffix(limit))
    }
}

public struct LogBucket: Equatable, Sendable {
    public var event: String
    public var count: Int
    public var level: LogLevel
    public var first: Date?
    public var last: Date?
    public var sample: String

    public func jsonObject() -> [String: Any] {
        var o: [String: Any] = ["name": event, "count": count, "level": level.rawValue, "sample": sample]
        if let first { o["first"] = LogTime.format(first) }
        if let last { o["last"] = LogTime.format(last) }
        return o
    }
}

public func logStats(_ lines: [LogLine]) -> [LogBucket] {
    var buckets: [String: LogBucket] = [:]
    var order: [String] = []
    for line in lines {
        let key = line.event
        if var b = buckets[key] {
            b.count += 1
            b.level = max(b.level, line.level)
            if let t = line.time { b.first = b.first.map { min($0, t) } ?? t; b.last = b.last.map { max($0, t) } ?? t }
            b.sample = line.text
            buckets[key] = b
        } else {
            buckets[key] = LogBucket(event: key, count: 1, level: line.level, first: line.time, last: line.time, sample: line.text)
            order.append(key)
        }
    }
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    return buckets.values.sorted { a, b in a.count != b.count ? a.count > b.count : rank[a.event]! < rank[b.event]! }
}

public func recentProblems(_ lines: [LogLine], limit: Int = 20) -> [LogBucket] {
    let problems = Array(lines.filter { $0.level >= .warn }.suffix(limit))
    var buckets = logStats(problems)
    buckets.sort { a, b in (a.last ?? .distantPast) > (b.last ?? .distantPast) }
    return buckets
}

public func renderStats(_ buckets: [LogBucket]) -> String {
    guard !buckets.isEmpty else { return "No lines." }
    let width = min(48, buckets.map(\.event.count).max() ?? 10)
    return buckets.map { b in
        let span = [b.first, b.last].compactMap { $0.map(LogTime.clock) }
        let when = span.count == 2 ? (span[0] == span[1] ? span[0] : "\(span[0])–\(span[1])") : "-"
        return "\(String(b.count).leftPad(6))  \(b.level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0))  \(b.event.padding(toLength: width, withPad: " ", startingAt: 0))  \(when)"
    }.joined(separator: "\n")
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

public enum Trail {
    static let hostEvents = ["host started", "host ready", "quitting", "terminating", "caught sig", "open from", "close from",
                             "restart", "screen is locked", "launched by the watchdog"]
    static let netEvents = ["viewer joined", "viewer left", "host left the room", "rejoin", "web server failed", "unpaired", "disconnected", "unlock: "]
    static let encodeEvents = ["stream now", "encoder drops", "encoding "]
    static let captureEvents = ["capture scale", "capture of", "resize capture"]

    public static func matches(_ line: LogLine, all: Bool = false) -> Bool {
        if line.level >= .warn { return true }
        if line.level == .debug { return false }
        if all { return true }
        let t = line.text.lowercased()
        switch line.category {
        case .stage, .resize, .watchdog, .viewer: return !t.hasPrefix("stage modes:")
        case .capture: return captureEvents.contains { t.contains($0) }
        case .encode: return encodeEvents.contains { t.contains($0) }
        case .net, .trust: return netEvents.contains { t.contains($0) }
        case .host: return hostEvents.contains { t.contains($0) }
        case .input, .audio, .clipboard, .ui: return false
        }
    }

    public static func select(_ lines: [LogLine], since: Date, all: Bool = false) -> [LogLine] {
        lines.filter { line in
            guard let t = line.time, t >= since else { return false }
            return matches(line, all: all)
        }
    }

    public struct Entry: Equatable, Sendable {
        public var line: LogLine
        public var repeats: Int
        public var last: Date?
    }

    public static func collapse(_ lines: [LogLine]) -> [Entry] {
        var out: [Entry] = []
        for l in lines {
            if var prev = out.last, prev.line.event == l.event, prev.line.category == l.category, prev.line.role == l.role, prev.line.level == l.level {
                prev.repeats += 1
                prev.last = l.time ?? prev.last
                out[out.count - 1] = prev
            } else {
                out.append(Entry(line: l, repeats: 1, last: l.time))
            }
        }
        return out
    }

    public static func render(_ lines: [LogLine]) -> String {
        guard !lines.isEmpty else { return "Nothing happened in that window." }
        return collapse(lines).map { e in
            let l = e.line
            let more = e.repeats > 1 ? "  (×\(e.repeats)\(e.last.map { ", last \(LogTime.clock($0))" } ?? ""))" : ""
            return row(l) + more
        }.joined(separator: "\n")
    }

    static func row(_ l: LogLine) -> String {
            let who = l.role + (l.pid.map { ":\($0)" } ?? "")
            let mark = l.level >= .warn ? "!" : " "
            return "\(l.time.map { LogTime.format($0) } ?? "-".padding(toLength: 24, withPad: " ", startingAt: 0)) \(mark) \(l.category.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(who.padding(toLength: 15, withPad: " ", startingAt: 0)) \(l.text)"
    }
}
