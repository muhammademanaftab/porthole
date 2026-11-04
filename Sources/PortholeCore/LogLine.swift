import Foundation

public enum LogLevel: String, CaseIterable, Comparable, Codable, Sendable {
    case debug, info, warn, error

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }

    public static func parse(_ s: String) -> LogLevel? {
        switch s.lowercased() {
        case "debug", "verbose": return .debug
        case "info": return .info
        case "warn", "warning": return .warn
        case "error", "err": return .error
        default: return nil
        }
    }

    static let warnMarkers = [" failed", "could not", "couldn't", "never came online", "unavailable", "was terminated",
                              "exited with status", "is busy", "refused", "has not answered", "not booted out"]

    public static func infer(_ text: String) -> LogLevel {
        let t = text.lowercased()
        return warnMarkers.contains { t.contains($0) } ? .warn : .info
    }
}

public enum LogCategory: String, CaseIterable, Codable, Sendable {
    case host, viewer, watchdog, stage, capture, encode, input, resize, net, trust, audio, clipboard, ui

    public static func parse(_ s: String) -> LogCategory? { LogCategory(rawValue: s.lowercased()) }

    static let rules: [(LogCategory, [String])] = [
        (.host, ["permissions:", "host started", "host ready", "quitting (", "terminating (", "caught sig"]),
        (.watchdog, ["watchdog", "keep running", "old login agent", "login agent"]),
        (.stage, ["stage", "power:"]),
        (.resize, ["resize"]),
        (.capture, ["capture scale", "capture of", "frame rate change"]),
        (.encode, ["encod", "stream now", "kbps"]),
        (.audio, ["audio"]),
        (.clipboard, ["clipboard"]),
        (.trust, ["pair", "unpaired", "belongs to an unpaired"]),
        (.input, ["mouse from", "key from", "text from", "scroll from"]),
        (.ui, ["settings:"]),
        (.net, ["web server", "advertising", "bonjour", "viewer joined", "viewer left", "room", "livekit", "send to", "send failed",
                "reconnect", "disconnected", "connected to", "connecting to", "lost the connection"]),
    ]

    public static func infer(_ text: String, fallback: LogCategory = .host) -> LogCategory {
        let t = text.lowercased()
        for (category, needles) in rules where needles.contains(where: { t.contains($0) }) { return category }
        return fallback
    }
}

public enum LogTime {
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    public static func format(_ date: Date, milliseconds: Bool = true) -> String {
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded(.down))
        let secs = Int((Double(ms) / 1000).rounded(.down))
        let days = Int((Double(secs) / 86400).rounded(.down))
        let rem = secs - days * 86400
        let (y, m, d) = civilFromDays(days)
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", y, m, d, rem / 3600, rem % 3600 / 60, rem % 60)
        return milliseconds ? base + String(format: ".%03dZ", ms - secs * 1000) : base + "Z"
    }

    public static func clock(_ date: Date) -> String {
        let s = format(date)
        return String(s.dropFirst(11).prefix(8))
    }

    public static func parse<S: StringProtocol>(_ s: S) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 20 else { return nil }
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<(a + n) {
                guard i < u.count, (48...57).contains(u[i]) else { return nil }
                v = v * 10 + Int(u[i] - 48)
            }
            return v
        }
        guard u[4] == 45, u[7] == 45, u[10] == 84 || u[10] == 32, u[13] == 58, u[16] == 58,
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61 else { return nil }
        var i = 19
        var frac = 0.0
        if i < u.count, u[i] == 46 {
            i += 1
            var scale = 0.1
            while i < u.count, (48...57).contains(u[i]) { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
        }
        guard i < u.count else { return nil }
        var offset = 0
        if u[i] == 90 {
            i += 1
        } else if u[i] == 43 || u[i] == 45, let oh = num(i + 1, 2) {
            let sign = u[i] == 45 ? -1 : 1
            var om = 0
            if i + 3 < u.count, u[i + 3] == 58, let m = num(i + 4, 2) { om = m; i += 6 }
            else if let m = num(i + 3, 2) { om = m; i += 5 }
            else { i += 3 }
            offset = sign * (oh * 3600 + om * 60)
        } else { return nil }
        guard i == u.count else { return nil }
        let secs = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset
        return Date(timeIntervalSince1970: Double(secs) + frac)
    }
}

public struct LogLine: Equatable, Sendable {
    public var time: Date?
    public var level: LogLevel
    public var category: LogCategory
    public var role: String
    public var pid: Int32?
    public var text: String
    public var structured: Bool

    public init(time: Date?, level: LogLevel, category: LogCategory, role: String, pid: Int32?, text: String, structured: Bool = true) {
        self.time = time; self.level = level; self.category = category; self.role = role; self.pid = pid
        self.text = text; self.structured = structured
    }

    public static func format(time: Date, level: LogLevel, category: LogCategory, role: String, pid: Int32, text: String) -> String {
        let clean = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n")
        return "\(LogTime.format(time)) \(level.rawValue) \(role):\(pid) [\(category.rawValue)] \(clean)"
    }

    public var formatted: String {
        guard let time else { return text }
        guard structured else { return LogTime.format(time, milliseconds: false) + " " + text }
        return Self.format(time: time, level: level, category: category, role: role, pid: pid ?? 0, text: text)
    }

    public static func parse(_ raw: String, defaultRole: String = "host") -> LogLine? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard !line.isEmpty else { return nil }
        guard let space = line.firstIndex(of: " "), let time = LogTime.parse(line[..<space]) else {
            return LogLine(time: nil, level: LogLevel.infer(line), category: LogCategory.infer(line, fallback: fallback(defaultRole)),
                           role: defaultRole, pid: nil, text: line, structured: false)
        }
        let rest = line[line.index(after: space)...]
        if let parsed = structuredRest(rest) {
            return LogLine(time: time, level: parsed.level, category: parsed.category, role: parsed.role, pid: parsed.pid, text: parsed.text)
        }
        let text = String(rest)
        let role = legacyRole(text, defaultRole: defaultRole)
        return LogLine(time: time, level: LogLevel.infer(text), category: LogCategory.infer(text, fallback: fallback(role)),
                       role: role, pid: nil, text: text, structured: false)
    }

    static func fallback(_ role: String) -> LogCategory {
        role == "viewer" ? .viewer : role == "watchdog" ? .watchdog : .host
    }

    static func legacyRole(_ text: String, defaultRole: String) -> String {
        defaultRole == "host" && text.hasPrefix("watchdog") ? "watchdog" : defaultRole
    }

    static func structuredRest(_ rest: Substring) -> (level: LogLevel, role: String, pid: Int32, category: LogCategory, text: String)? {
        let parts = rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, let level = LogLevel(rawValue: String(parts[0])) else { return nil }
        let who = parts[1].split(separator: ":")
        guard who.count == 2, !who[0].isEmpty, who[0].allSatisfy({ $0.isLetter || $0 == "-" }), let pid = Int32(who[1]) else { return nil }
        let tag = parts[2]
        guard tag.hasPrefix("["), tag.hasSuffix("]"), let category = LogCategory(rawValue: String(tag.dropFirst().dropLast())) else { return nil }
        let text = parts.count > 3 ? String(parts[3]) : ""
        return (level, String(who[0]), pid, category, text)
    }

    public var event: String { logEventName(text) }

    public var fields: [String: String] { logFields(text) }

    public func jsonObject() -> [String: Any] {
        var o: [String: Any] = ["level": level.rawValue, "category": category.rawValue, "role": role, "name": event, "text": text]
        if let time { o["time"] = LogTime.format(time) }
        if let pid { o["pid"] = Int(pid) }
        var f: [String: Any] = [:]
        for (k, v) in fields { f[k] = typedField(v) }
        o["fields"] = f
        return o
    }
}

public func typedField(_ v: String) -> Any {
    if v == "true" { return true }
    if v == "false" { return false }
    if let i = Int(v) { return i }
    if let d = Double(v), v.contains(".") { return d }
    return v
}

public func logFields(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for word in text.split(separator: " ") {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { continue }
        let key = word[..<eq]
        guard let first = key.first, first.isLetter || first == "_", key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
        var value = String(word[word.index(after: eq)...])
        while let last = value.last, ",;)".contains(last) { value.removeLast() }
        if !value.isEmpty { out[String(key)] = value }
    }
    return out
}

func isVariableWord(_ w: Substring) -> Bool {
    !w.contains { $0.isLetter } || w.contains { $0.isNumber || $0 == "(" || $0 == ")" || $0 == "[" || $0 == "]" } || w.hasPrefix("view-") || w.hasPrefix("\"") || w.hasPrefix("'") || w.hasPrefix("(") || w.contains("/")
}

public func logEventName(_ text: String) -> String {
    var words: [String] = []
    var real = 0
    for raw in text.split(separator: " ", omittingEmptySubsequences: true) {
        guard real < 5, words.count < 8 else { break }
        let stop = raw.hasSuffix(":") || raw.hasSuffix(",") || raw.hasSuffix(";")
        let bare = stop ? raw.dropLast() : raw
        var word: String
        if let eq = bare.firstIndex(of: "="), eq != bare.startIndex {
            let value = bare[bare.index(after: eq)...]
            word = isVariableWord(value) ? String(bare[...eq]) + "#" : String(bare)
            real += 1
        } else if isVariableWord(bare) {
            word = "#"
        } else {
            word = String(bare)
            real += 1
        }
        if stop { word += String(raw.last!) }
        if word.hasPrefix("#"), let last = words.last, last.hasPrefix("#") { continue }
        words.append(word)
        if stop && real >= 2 { break }
    }
    while words.count > 1, let last = words.last, last.hasPrefix("#") { words.removeLast() }
    var name = words.joined(separator: " ")
    while let last = name.last, ":,;".contains(last) { name.removeLast() }
    return name.isEmpty ? "(empty)" : name
}
