import Foundation

public enum RunCause: Equatable, Sendable {
    case running
    case quit
    case remoteRestart
    case migrate
    case session
    case signal(String)
    case crash(report: String)
    case hang(sample: String?)
    case noTrace

    public var summary: String {
        switch self {
        case .running: return "still running"
        case .quit: return "clean quit from the menu"
        case .remoteRestart: return "restarted from a viewer (Restart Host)"
        case .migrate: return "handed over from the old login agent"
        case .session: return "session end: logout, shutdown or an outside quit (Activity Monitor, osascript)"
        case .signal(let name): return "caught \(name)"
        case .crash(let report): return "crashed; report \(report)"
        case .hang(let sample): return "main thread hung; the watchdog killed it" + (sample.map { "; sample \($0)" } ?? "; no sample")
        case .noTrace: return "gone without a marker and no crash report (crash, SIGKILL, Force Quit or jetsam)"
        }
    }

    public var key: String {
        switch self {
        case .running: return "running"
        case .quit: return "quit"
        case .remoteRestart: return "remote"
        case .migrate: return "migrate"
        case .session: return "session"
        case .signal: return "signal"
        case .crash: return "crash"
        case .hang: return "hang"
        case .noTrace: return "killed"
        }
    }
}

public struct CrashReport: Equatable, Sendable {
    public var path: String
    public var time: Date
    public var pid: Int32?
    public init(path: String, time: Date, pid: Int32?) { self.path = path; self.time = time; self.pid = pid }
}

public struct HostRun: Equatable, Sendable {
    public var pid: Int32?
    public var start: Date?
    public var end: Date?
    public var version: String?
    public var launchedBy: String?
    public var cause: RunCause
    public var relaunch: String?
    public var lastLine: String?

    public var uptime: TimeInterval? {
        guard let start, let end else { return nil }
        return end.timeIntervalSince(start)
    }

    public func render(now: Date = Date()) -> String {
        let s = start.map { LogTime.format($0, milliseconds: false) } ?? "?"
        let e = cause == .running ? "now" : end.map { LogTime.format($0, milliseconds: false) } ?? "?"
        let up = cause == .running ? start.map { formatDuration(now.timeIntervalSince($0)) } : uptime.map(formatDuration)
        var out = "\(s) → \(e)  up \(up ?? "?")  pid \(pid.map(String.init) ?? "?")"
        if let version { out += "  v\(version)" }
        out += "\n    \(cause.summary)"
        if let relaunch { out += "\n    the watchdog relaunched it (\(relaunch))" }
        return out
    }
}

struct RunDraft {
    var pid: Int32?
    var lines: [LogLine] = []
    var notes: [LogLine] = []
}

func isLegacyStart(_ text: String) -> Bool {
    text.hasPrefix("permissions: screen recording") || text.hasPrefix("host started")
}

func isLegacyPreamble(_ text: String) -> Bool {
    ["launched by the watchdog", "stopping older host instance", "PORTHOLE_WATCHDOG=", "removed old login agent",
     "booting out the old login agent", "keep running:", "config.json was unreadable"].contains { text.hasPrefix($0) }
}

func splitRuns(_ host: [LogLine]) -> [RunDraft] {
    var drafts: [RunDraft] = []
    var byPid: [Int32: Int] = [:]
    var legacy: RunDraft?
    var legacyHasStart = false
    var preamble: [LogLine] = []
    func closeLegacy() {
        if let l = legacy { drafts.append(l) }
        legacy = nil
        legacyHasStart = false
    }
    for line in host {
        if let pid = line.pid {
            if !preamble.isEmpty { if legacy == nil { legacy = RunDraft() }; legacy!.lines += preamble; preamble = [] }
            closeLegacy()
            if let i = byPid[pid], line.text.hasPrefix("host started") == false || drafts[i].lines.isEmpty {
                drafts[i].lines.append(line)
            } else {
                byPid[pid] = drafts.count
                drafts.append(RunDraft(pid: pid, lines: [line]))
            }
            continue
        }
        if isLegacyStart(line.text) {
            if legacyHasStart { closeLegacy() }
            if legacy == nil { legacy = RunDraft() }
            legacy!.lines += preamble
            preamble = []
            legacy!.lines.append(line)
            legacyHasStart = true
        } else if isLegacyPreamble(line.text) && (legacyHasStart || legacy == nil) {
            preamble.append(line)
        } else {
            if legacy == nil { legacy = RunDraft() }
            legacy!.lines += preamble
            preamble = []
            legacy!.lines.append(line)
        }
    }
    if !preamble.isEmpty { if legacy == nil { legacy = RunDraft() }; legacy!.lines += preamble }
    closeLegacy()
    return drafts.filter { !$0.lines.isEmpty }.sorted { ($0.lines.first?.time ?? .distantPast) < ($1.lines.first?.time ?? .distantPast) }
}

func pidMentioned(_ text: String, after marker: String) -> Int32? {
    guard let r = text.range(of: marker) else { return nil }
    return Int32(text[r.upperBound...].prefix { $0.isNumber })
}

public func deriveRuns(_ lines: [LogLine], alive: Set<Int32> = [], hostRunning: Bool = false,
                       crashes: [CrashReport] = [], lastMarker: String? = nil) -> [HostRun] {
    let host = lines.filter { $0.role == "host" }
    let watchdog = lines.filter { $0.role == "watchdog" }
    var drafts = splitRuns(host)
    guard !drafts.isEmpty else { return [] }
    for note in watchdog {
        guard let t = note.time else { continue }
        if let pid = pidMentioned(note.text, after: "watchdog: host "), let i = drafts.lastIndex(where: { $0.pid == pid }) {
            drafts[i].notes.append(note)
            continue
        }
        if let i = drafts.lastIndex(where: { ($0.lines.first?.time ?? .distantPast) <= t }) { drafts[i].notes.append(note) }
    }
    var runs: [HostRun] = []
    for (index, d) in drafts.enumerated() {
        let isLast = index == drafts.count - 1
        let texts = d.lines.map(\.text)
        var run = HostRun(pid: d.pid, start: d.lines.first?.time, end: d.lines.last(where: { $0.time != nil })?.time,
                          cause: .noTrace, lastLine: texts.last)
        if let started = d.lines.first(where: { $0.text.hasPrefix("host started") }) {
            let f = started.fields
            run.version = f["version"]
            run.launchedBy = f["launchedBy"]
        }
        let notes = d.notes.map(\.text)
        let hangNote = notes.first { $0.contains("has not answered") }
        let sample = notes.compactMap { n -> String? in
            guard let r = n.range(of: "hang sample written to ") else { return nil }
            return String(n[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }.first
        run.relaunch = notes.compactMap { n -> String? in
            guard let r = n.range(of: "watchdog relaunch reason=") else { return nil }
            return String(n[r.upperBound...].prefix { !$0.isWhitespace })
        }.first
        if let q = texts.last(where: { $0.hasPrefix("quitting (") }) {
            run.cause = q.hasPrefix("quitting (remote") ? .remoteRestart : q.hasPrefix("quitting (migrate") ? .migrate : .quit
        } else if let s = texts.last(where: { $0.hasPrefix("caught SIG") }) {
            run.cause = .signal(String(s.dropFirst("caught ".count).prefix { $0.isLetter }))
        } else if let term = texts.last(where: { $0.hasPrefix("terminating (") }) {
            run.cause = term.hasPrefix("terminating (quit") ? .quit : term.hasPrefix("terminating (remote") ? .remoteRestart : .session
        } else if hangNote != nil {
            run.cause = .hang(sample: sample)
            if let t = d.notes.first(where: { $0.text.contains("has not answered") })?.time { run.end = t }
        } else if isLast && run.relaunch == nil && (d.pid.map { alive.contains($0) } ?? hostRunning) {
            run.cause = .running
        } else {
            let end = run.end ?? .distantPast
            let report = crashes.first { c in
                if let pid = d.pid, let cp = c.pid { return pid == cp }
                return c.time >= end.addingTimeInterval(-5) && c.time <= end.addingTimeInterval(180)
            }
            if let report { run.cause = .crash(report: report.path) }
            else if run.relaunch == "missingAfterQuit" { run.cause = .session }
            else if run.relaunch == "hang" { run.cause = .hang(sample: sample) }
            else if run.relaunch == "remote" { run.cause = .remoteRestart }
            else if isLast, let m = lastMarker {
                run.cause = m == "quit" ? .quit : m == "remote" ? .remoteRestart : m == "migrate" ? .migrate : m == "session" ? .session : .noTrace
            }
        }
        runs.append(run)
    }
    return runs
}
