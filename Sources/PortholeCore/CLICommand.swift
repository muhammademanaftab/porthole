import Foundation

public let portholeVersion = "0.1.0"

public func parseDuration(_ s: String) -> TimeInterval? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    guard !t.isEmpty else { return nil }
    if let plain = Double(t) { return plain >= 0 && plain.isFinite ? plain : nil }
    var total = 0.0
    var number = ""
    var sawUnit = false
    for ch in t {
        if ch.isNumber || ch == "." { number.append(ch); continue }
        let unit: Double
        switch ch {
        case "s": unit = 1
        case "m": unit = 60
        case "h": unit = 3600
        case "d": unit = 86400
        case "w": unit = 604800
        default: return nil
        }
        guard let n = Double(number), n.isFinite else { return nil }
        total += n * unit
        number = ""
        sawUnit = true
    }
    guard number.isEmpty, sawUnit else { return nil }
    return total
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
    if s < 86400 { return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m" }
    return "\(s / 86400)d \(s % 86400 / 3600)h"
}

public enum LogMode: Equatable, Sendable {
    case tail, follow, grep(String), path, stats
}

public struct LogOptions: Equatable, Sendable {
    public var mode: LogMode = .tail
    public var follow = false
    public var count: Int?
    public var category: LogCategory?
    public var level: LogLevel?
    public var role: String?
    public var since: TimeInterval?
    public var json = false
    public init() {}
}

public struct DoctorOptions: Equatable, Sendable {
    public var quick = false
    public var windows = false
    public var json = false
    public init() {}
}

public struct TrailOptions: Equatable, Sendable {
    public var window: TimeInterval = 30 * 60
    public var all = false
    public var json = false
    public init() {}
}

public struct ReportOptions: Equatable, Sendable {
    public var out: String?
    public var since: TimeInterval?
    public var logs = true
    public var system = true
    public var trust = true
    public var description: String?
    public init() {}
}

public enum CLITool: String, Equatable, Sendable { case host = "porthole-host", viewer = "porthole-view" }

public enum CLICommand: Equatable, Sendable {
    case help(error: String?)
    case version
    case env(setOnly: Bool, json: Bool)
    case doctor(DoctorOptions)
    case log(LogOptions)
    case trail(TrailOptions)
    case whyQuit(Int)
    case report(ReportOptions)
    case share(ShareOptions)
    case forward(CLITool, [String])
}

public let cliUsage = """
usage: porthole <command> [options]

Diagnostics
  doctor [--quick] [--windows] [--json]   check this Mac: roles, permissions, host, watchdog, ports, Tailscale, Bonjour, pairing, Stage, recent problems
  log [tail|-f|grep RE|path|--stats] [-n N] [-c category] [-l level] [-r role] [--since 30s|10m|2h] [--json]
  trail [minutes] [--since dur] [--all] [--json]   one timeline of the events that matter
  why-quit [n]                            why the last n runs of Porthole (sharing this Mac) ended
  report [--out path] [--since dur] [--no-logs] [--no-system] [--no-trust] [description]
                                          zip logs, samples and readouts to ~/Desktop; nothing is uploaded
  env [--set] [--json]                    every PORTHOLE_* flag with its meaning, default and current value
  version

Sharing (asks the running Porthole, with Share this Mac on)
  share [window] [--control] [--wifi] [--ttl dur] [--json]
                                          browser links to one window (ID or part of its title) or to the
                                          window picker: one for this Wi-Fi and one for the tailnet; view only
                                          unless --control; --wifi prints the Wi-Fi link alone; 24h by default
  share --list | --revoke <id|all>        the live share links; turn one (or all) off and disconnect its guests

Viewing (runs Porthole's viewer)
  machines [--json]                       Porthole hosts on the tailnet and the local network
  ls <host> [--json]                      a host's windows
  open <host> <windowID|title>            open a portal to one window
  recent [n]                              recent portals, or reopen entry n

Pairing
  paircode | devices | unpair <name|id>   (this Mac as host)
  request <host> | pair <host> <code>     (this Mac as viewer)

Log categories: \(LogCategory.allCases.map(\.rawValue).joined(separator: " ")). Levels: debug info warn error.
"""

public func parseCLI(_ args: [String]) -> CLICommand {
    guard let first = args.first else { return .help(error: nil) }
    let rest = Array(args.dropFirst())
    switch first {
    case "help", "-h", "--help": return .help(error: nil)
    case "version", "--version", "-v": return rest.isEmpty ? .version : .help(error: "version takes no arguments")
    case "env": return parseEnv(rest)
    case "doctor": return parseDoctor(rest)
    case "log", "logs": return parseLog(rest)
    case "trail": return parseTrail(rest)
    case "why-quit", "whyquit": return parseWhyQuit(rest)
    case "report": return parseReport(rest)
    case "share": return parseShare(rest)
    case "paircode", "devices":
        return rest.isEmpty ? .forward(.host, [first]) : .help(error: "\(first) takes no arguments")
    case "unpair":
        return rest.count == 1 ? .forward(.host, args) : .help(error: "unpair needs one name or device ID")
    case "request":
        return rest.count == 1 ? .forward(.viewer, args) : .help(error: "request needs a host")
    case "pair":
        return rest.count == 2 ? .forward(.viewer, args) : .help(error: "pair needs a host and a code")
    case "machines":
        return rest.allSatisfy({ $0 == "--json" }) ? .forward(.viewer, args) : .help(error: "machines takes only --json")
    case "ls":
        let positional = rest.filter { $0 != "--json" }
        return positional.count == 1 ? .forward(.viewer, args) : .help(error: "ls needs a host")
    case "open":
        return rest.count == 2 ? .forward(.viewer, args) : .help(error: "open needs a host and a window ID or part of its title")
    case "recent":
        if rest.isEmpty { return .forward(.viewer, args) }
        guard rest.count == 1, let n = Int(rest[0]), n >= 1 else { return .help(error: "recent takes an entry number (1 is the newest)") }
        return .forward(.viewer, args)
    default:
        return .help(error: "unknown command \"\(first)\"")
    }
}

func parseShare(_ args: [String]) -> CLICommand {
    var o = ShareOptions()
    var words: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--control", "-c": o.control = true
        case "--wifi", "-w": o.wifiOnly = true
        case "--json": o.json = true
        case "--list", "-l", "list": o.list = true
        case "--revoke", "revoke":
            i += 1
            guard i < args.count, !args[i].isEmpty, !args[i].hasPrefix("-") else { return .help(error: "share --revoke needs a link ID (or all)") }
            o.revoke = args[i]
        case "--ttl", "--expires":
            i += 1
            guard i < args.count, let d = parseDuration(args[i]), d >= 60, d <= 30 * 86400 else {
                return .help(error: "share --ttl needs a duration from 1m to 30d, such as 2h or 7d")
            }
            o.ttl = d
        default:
            if a.hasPrefix("-") { return .help(error: "share: unknown option \(a)") }
            words.append(a)
        }
        i += 1
    }
    if !words.isEmpty { o.window = words.joined(separator: " ") }
    if (o.list || o.revoke != nil) && (o.window != nil || o.control || o.wifiOnly || o.ttl != nil) {
        return .help(error: "share --list and --revoke take no window or link options")
    }
    if o.list && o.revoke != nil { return .help(error: "share: choose --list or --revoke") }
    return .share(o)
}

func parseEnv(_ args: [String]) -> CLICommand {
    var setOnly = false, json = false
    for a in args {
        switch a {
        case "--set": setOnly = true
        case "--json": json = true
        default: return .help(error: "env: unknown option \(a)")
        }
    }
    return .env(setOnly: setOnly, json: json)
}

func parseDoctor(_ args: [String]) -> CLICommand {
    var o = DoctorOptions()
    for a in args {
        switch a {
        case "--quick", "-q": o.quick = true
        case "--windows", "-w": o.windows = true
        case "--json": o.json = true
        default: return .help(error: "doctor: unknown option \(a)")
        }
    }
    if o.json && !o.windows { return .help(error: "doctor: --json goes with --windows") }
    return .doctor(o)
}

func positiveInt(_ s: String?) -> Int? {
    guard let s, let n = Int(s), n > 0 else { return nil }
    return n
}

func parseLog(_ args: [String]) -> CLICommand {
    var o = LogOptions()
    var modeSet = false
    var i = 0
    func value() -> String? {
        i += 1
        return i < args.count ? args[i] : nil
    }
    func setMode(_ m: LogMode) -> Bool {
        if modeSet { return false }
        modeSet = true; o.mode = m
        return true
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "tail": if !setMode(.tail) { return .help(error: "log: choose one of tail, -f, grep, path, --stats") }
        case "-f", "--follow", "follow": o.follow = true
        case "grep":
            guard let re = value(), !re.isEmpty else { return .help(error: "log grep needs a pattern") }
            guard (try? NSRegularExpression(pattern: re, options: [.caseInsensitive])) != nil else { return .help(error: "log grep: \"\(re)\" isn't a valid regular expression") }
            if !setMode(.grep(re)) { return .help(error: "log: choose one of tail, -f, grep, path, --stats") }
        case "path": if !setMode(.path) { return .help(error: "log: choose one of tail, -f, grep, path, --stats") }
        case "--stats", "stats": if !setMode(.stats) { return .help(error: "log: choose one of tail, -f, grep, path, --stats") }
        case "-n":
            guard let n = positiveInt(value()) else { return .help(error: "log -n needs a positive number") }
            o.count = n
        case "-c", "--category":
            guard let v = value(), let c = LogCategory.parse(v) else { return .help(error: "log -c needs one of: \(LogCategory.allCases.map(\.rawValue).joined(separator: " "))") }
            o.category = c
        case "-l", "--level":
            guard let v = value(), let l = LogLevel.parse(v) else { return .help(error: "log -l needs one of: debug info warn error") }
            o.level = l
        case "-r", "--role":
            guard let v = value(), ["host", "watchdog", "viewer"].contains(v) else { return .help(error: "log -r needs host, watchdog or viewer") }
            o.role = v
        case "--since":
            guard let v = value(), let d = parseDuration(v) else { return .help(error: "log --since needs a duration such as 30s, 10m or 2h") }
            o.since = d
        case "--json": o.json = true
        default: return .help(error: "log: unknown option \(a)")
        }
        i += 1
    }
    if o.follow {
        switch o.mode {
        case .tail: o.mode = .follow
        case .grep: break
        default: return .help(error: "log -f works with tail and grep")
        }
    }
    if o.json && o.mode == .path { return .help(error: "log path has no --json") }
    return .log(o)
}

func parseTrail(_ args: [String]) -> CLICommand {
    var o = TrailOptions()
    var i = 0
    var gotMinutes = false
    while i < args.count {
        let a = args[i]
        switch a {
        case "--all": o.all = true
        case "--json": o.json = true
        case "--since":
            i += 1
            guard i < args.count, let d = parseDuration(args[i]), d > 0 else { return .help(error: "trail --since needs a duration such as 10m or 2h") }
            o.window = d
        default:
            guard !gotMinutes, let m = Double(a), m > 0, m.isFinite else { return .help(error: "trail: \"\(a)\" isn't a number of minutes") }
            o.window = m * 60
            gotMinutes = true
        }
        i += 1
    }
    return .trail(o)
}

func parseWhyQuit(_ args: [String]) -> CLICommand {
    guard !args.isEmpty else { return .whyQuit(3) }
    guard args.count == 1, let n = positiveInt(args[0]) else { return .help(error: "why-quit takes a number of runs") }
    return .whyQuit(n)
}

func parseReport(_ args: [String]) -> CLICommand {
    var o = ReportOptions()
    var words: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--out", "-o":
            i += 1
            guard i < args.count, !args[i].isEmpty else { return .help(error: "report --out needs a path") }
            o.out = args[i]
        case "--since":
            i += 1
            guard i < args.count, let d = parseDuration(args[i]), d > 0 else { return .help(error: "report --since needs a duration such as 2h or 1d") }
            o.since = d
        case "--no-logs": o.logs = false
        case "--no-system": o.system = false
        case "--no-trust": o.trust = false
        default:
            if a.hasPrefix("-") { return .help(error: "report: unknown option \(a)") }
            words.append(a)
        }
        i += 1
    }
    if !words.isEmpty { o.description = words.joined(separator: " ") }
    return .report(o)
}
