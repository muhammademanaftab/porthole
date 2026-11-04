import CoreGraphics
import Foundation
import PortholeCore

private func scratch() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-diag-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func at(_ s: String) -> Date { LogTime.parse(s)! }

private func line(_ time: String, _ level: LogLevel, _ role: String, _ pid: Int32, _ cat: LogCategory, _ text: String) -> String {
    LogLine.format(time: at(time), level: level, category: cat, role: role, pid: pid, text: text)
}

private func lines(_ text: String, role: String = "host") -> [LogLine] { LogFiles.parse(text, role: role) }

private func win(_ id: UInt32, _ app: String, _ title: String) -> WindowInfo {
    WindowInfo(id: id, app: app, title: title, bundle: nil, w: 800, h: 600)
}

func diagnosticsTests() {
    logTimeTests()
    logLineTests()
    eventNameTests()
    durationTests()
    cliParseTests()
    logQueryTests()
    trailTests()
    whyQuitTests()
    legacyWhyQuitTests()
    scrubTests()
    envFlagTests()
    recentTests()
    pickTests()
    placementTests()
    doctorModelTests()
    logFileTests()
    localStatusRouteTests()
    shellTests()
    openHandOffTests()
    viewerToolCommandTests()
}

private func logTimeTests() {
    let d = Date(timeIntervalSince1970: 1_793_793_309.123)
    expect("log time: formats UTC with milliseconds", LogTime.format(d), "2026-11-04T11:55:09.123Z")
    expect("log time: formats without milliseconds", LogTime.format(d, milliseconds: false), "2026-11-04T11:55:09Z")
    expect("log time: parses its own format", LogTime.parse("2026-11-04T11:55:09.123Z").map { ($0.timeIntervalSince1970 * 1000).rounded() }, 1_793_793_309_123)
    expect("log time: parses the old whole-second lines", LogTime.parse("2026-11-04T11:55:09Z")?.timeIntervalSince1970, 1_793_793_309)
    expect("log time: honours an offset", LogTime.parse("2026-11-04T12:55:09+01:00")?.timeIntervalSince1970, 1_793_793_309)
    expect("log time: honours a negative offset without a colon", LogTime.parse("2026-11-04T06:55:09-0500")?.timeIntervalSince1970, 1_793_793_309)
    expect("log time: leap day", LogTime.format(LogTime.parse("2024-02-29T23:59:59Z")!, milliseconds: false), "2024-02-29T23:59:59Z")
    expect("log time: the epoch", LogTime.format(Date(timeIntervalSince1970: 0), milliseconds: false), "1970-01-01T00:00:00Z")
    expect("log time: junk is no time", LogTime.parse("viewer joined: x"), nil)
    expect("log time: month 13 is no time", LogTime.parse("2026-13-04T11:55:09Z"), nil)
    expect("log time: trailing junk is no time", LogTime.parse("2026-11-04T11:55:09Zjunk"), nil)
    expect("log time: clock is HH:MM:SS", LogTime.clock(d), "11:55:09")
}

private func logLineTests() {
    let raw = line("2026-11-04T11:55:09.500Z", .warn, "host", 4242, .stage, "stage: attempt 2 failed")
    expect("log line: the new format", raw, "2026-11-04T11:55:09.500Z warn host:4242 [stage] stage: attempt 2 failed")
    let p = LogLine.parse(raw)
    expect("log line: round-trips the level", p?.level, .warn)
    expect("log line: round-trips the category", p?.category, .stage)
    expect("log line: round-trips the role and pid", p.map { "\($0.role):\($0.pid ?? 0)" }, "host:4242")
    expect("log line: round-trips the text", p?.text, "stage: attempt 2 failed")
    expect("log line: is structured", p?.structured, true)
    expect("log line: formatted is the original line", p?.formatted, raw)

    let multi = LogLine.format(time: at("2026-11-04T11:55:09Z"), level: .info, category: .host, role: "host", pid: 1, text: "a\nb\r")
    check("log line: a newline in the text stays on one line", !multi.contains("\n") && multi.hasSuffix("a\\nb"))

    let old = LogLine.parse("2026-11-04T11:55:09Z stage: could not move window 42")
    expect("old line: keeps its time", old?.time, at("2026-11-04T11:55:09Z"))
    expect("old line: has no pid", old?.pid, nil)
    expect("old line: is the host's", old?.role, "host")
    expect("old line: category comes from the text", old?.category, .stage)
    expect("old line: failure words make it a warning", old?.level, .warn)
    expect("old line: formatted is the original line", old?.formatted, "2026-11-04T11:55:09Z stage: could not move window 42")
    expect("old line: watchdog lines belong to the watchdog", LogLine.parse("2026-11-04T11:55:09Z watchdog relaunch reason=crash")?.role, "watchdog")
    expect("old line: 'launched by the watchdog' is the host's own line", LogLine.parse("2026-11-04T11:55:09Z launched by the watchdog, reason=crash")?.role, "host")
    expect("old line: in viewer.log it is the viewer's", LogLine.parse("2026-11-04T11:55:09Z reconnected", defaultRole: "viewer")?.category, .net)
    expect("an empty line is no line", LogLine.parse(""), nil)
    expect("a line without a time is kept as text", LogLine.parse("Porthole host ready.")?.text, "Porthole host ready.")
    expect("an unknown level is not structured", LogLine.parse("2026-11-04T11:55:09Z loud host:1 [stage] x")?.structured, false)
    expect("an unknown category is not structured", LogLine.parse("2026-11-04T11:55:09Z info host:1 [nope] x")?.structured, false)
    expect("a structured line with empty text parses", LogLine.parse("2026-11-04T11:55:09Z info host:1 [host]")?.text, "")

    expect("level: 'failed' is a warning", LogLevel.infer("clipboard send failed: gone"), .warn)
    expect("level: 'no error' is not", LogLevel.infer("host left the room: no error"), .info)
    expect("level: a hung host is a warning", LogLevel.infer("watchdog: host 12 has not answered for 61 s"), .warn)
    expect("level: parse accepts warning", LogLevel.parse("WARNING"), .warn)
    check("level: order is debug < info < warn < error", LogLevel.debug < .info && LogLevel.info < .warn && LogLevel.warn < .error)

    let cats: [(String, LogCategory)] = [
        ("permissions: screen recording true, accessibility true, keep running true (watchdog enabled)", .host),
        ("watchdog relaunch reason=hang", .watchdog), ("keep running: watchdog agent registered", .watchdog),
        ("stage ready for a 1512x982 viewer", .stage), ("power: keeping display and system awake", .stage),
        ("window 4: capture scale 2.00 -> 1.50 (encode 31.0 ms)", .capture), ("window 4: encode 2.3 ms, 42 encoded", .encode),
        ("window 4: stream now 60 fps, level 2.0", .encode), ("resize from view-a", .resize), ("audio: stopped", .audio),
        ("clipboard: received 12 bytes", .clipboard), ("pairing request from Air (0123)", .trust), ("mouse from view-a", .input),
        ("viewer joined: view-a", .net), ("settings: verbose logging on", .ui), ("open from view-a", .host),
    ]
    for (text, want) in cats { expect("category: \(text.prefix(40))", LogCategory.infer(text), want) }
    expect("category: the viewer falls back to viewer", LogCategory.infer("portal opened", fallback: .viewer), .viewer)

    let f = logFields("watchdog relaunch reason=crash count=3, ok=true scale=1.5 =x 9a=b")
    expect("fields: key=value pairs", f, ["reason": "crash", "count": "3", "ok": "true", "scale": "1.5"])
    let j = LogLine.parse(line("2026-11-04T11:55:09Z", .info, "watchdog", 7, .watchdog, "watchdog relaunch reason=crash n=2 ok=false"))!.jsonObject()
    check("json: fields are typed", (j["fields"] as? [String: Any])?["n"] as? Int == 2 && (j["fields"] as? [String: Any])?["ok"] as? Bool == false)
    check("json: has time, level, category, role, pid, name, text",
          j["time"] as? String == "2026-11-04T11:55:09.000Z" && j["level"] as? String == "info" && j["category"] as? String == "watchdog"
          && j["role"] as? String == "watchdog" && j["pid"] as? Int == 7 && j["name"] as? String == "watchdog relaunch reason=crash n=# ok=false" && j["text"] != nil)
}

private func eventNameTests() {
    let cases: [(String, String)] = [
        ("window 62763: encode 2.3 ms, 42 encoded / 57 submitted", "window #: encode # ms"),
        ("window 62763: capture scale 2.00 -> 1.50 (encode 31 ms)", "window #: capture scale"),
        ("send to view-browser-I_4j failed: The operation couldn't be completed", "send to # failed"),
        ("clipboard send failed: gone", "clipboard send failed"),
        ("viewer joined: view-browser-I_4j", "viewer joined"),
        ("stage: attempt 2 failed", "stage: attempt # failed"),
        ("watchdog relaunch reason=crash", "watchdog relaunch reason=crash"),
        ("watchdog: hang sample written to /Users/x/Library/Logs/Porthole/hang-1.txt", "watchdog: hang sample written to"),
        ("open from view-a", "open from"),
        ("host ready", "host ready"),
        ("caught SIGTERM; stopping", "caught SIGTERM"),
        ("disconnected view-a-1 after unpairing (status 200, 1 try)", "disconnected # after unpairing"),
        ("", "(empty)"),
    ]
    for (text, want) in cases { expect("event name: \(want)", logEventName(text), want) }
    expect("event name: ids collapse to one bucket", logEventName("open from view-b"), logEventName("open from view-zz-9"))
    expect("event name: a pid=value field is a placeholder", logEventName("host started pid=12 version=0.1.0"), "host started pid=# version=#")
}

private func durationTests() {
    expect("duration: 30s", parseDuration("30s"), 30)
    expect("duration: 10m", parseDuration("10m"), 600)
    expect("duration: 2h", parseDuration("2h"), 7200)
    expect("duration: 1d", parseDuration("1d"), 86400)
    expect("duration: 1h30m", parseDuration("1h30m"), 5400)
    expect("duration: 1.5h", parseDuration("1.5h"), 5400)
    expect("duration: a bare number is seconds", parseDuration("90"), 90)
    expect("duration: upper case", parseDuration("2H"), 7200)
    expect("duration: an unknown unit is refused", parseDuration("10x"), nil)
    expect("duration: a trailing number without a unit is refused", parseDuration("1h30"), nil)
    expect("duration: empty is refused", parseDuration(""), nil)
    expect("duration: a unit alone is refused", parseDuration("m"), nil)
    expect("duration: negative is refused", parseDuration("-5"), nil)
    expect("format duration: seconds", formatDuration(42), "42s")
    expect("format duration: minutes", formatDuration(192), "3m 12s")
    expect("format duration: hours", formatDuration(3 * 3600 + 5 * 60), "3h 05m")
    expect("format duration: days", formatDuration(2 * 86400 + 3 * 3600), "2d 3h")
}

private func cliParseTests() {
    expect("cli: no arguments prints help", parseCLI([]), .help(error: nil))
    expect("cli: version", parseCLI(["version"]), .version)
    expect("cli: --version", parseCLI(["--version"]), .version)
    expect("cli: env", parseCLI(["env"]), .env(setOnly: false, json: false))
    expect("cli: env --set --json", parseCLI(["env", "--set", "--json"]), .env(setOnly: true, json: true))
    var d = DoctorOptions(); d.quick = true
    expect("cli: doctor --quick", parseCLI(["doctor", "--quick"]), .doctor(d))
    var dw = DoctorOptions(); dw.windows = true; dw.json = true
    expect("cli: doctor --windows --json", parseCLI(["doctor", "--windows", "--json"]), .doctor(dw))
    expect("cli: doctor --json alone is refused", parseCLI(["doctor", "--json"]), .help(error: "doctor: --json goes with --windows"))
    expect("cli: doctor with a stray word is refused", parseCLI(["doctor", "now"]), .help(error: "doctor: unknown option now"))

    expect("cli: log is tail of 50", parseCLI(["log"]), .log(LogOptions()))
    var lf = LogOptions(); lf.mode = .follow; lf.follow = true
    expect("cli: log -f follows", parseCLI(["log", "-f"]), .log(lf))
    var lg = LogOptions(); lg.mode = .grep("stage|resize"); lg.count = 200; lg.category = .stage; lg.level = .warn; lg.since = 7200; lg.json = true
    expect("cli: log grep with every filter", parseCLI(["log", "grep", "stage|resize", "-n", "200", "-c", "stage", "-l", "warn", "--since", "2h", "--json"]), .log(lg))
    var lgf = LogOptions(); lgf.mode = .grep("x"); lgf.follow = true
    expect("cli: log grep -f keeps the grep and follows", parseCLI(["log", "grep", "x", "-f"]), .log(lgf))
    var ls = LogOptions(); ls.mode = .stats; ls.role = "watchdog"
    expect("cli: log --stats -r watchdog", parseCLI(["log", "--stats", "-r", "watchdog"]), .log(ls))
    var lp = LogOptions(); lp.mode = .path
    expect("cli: log path", parseCLI(["log", "path"]), .log(lp))
    expect("cli: log grep needs a pattern", parseCLI(["log", "grep"]), .help(error: "log grep needs a pattern"))
    expect("cli: log grep refuses a broken pattern", parseCLI(["log", "grep", "("]), .help(error: "log grep: \"(\" isn't a valid regular expression"))
    expect("cli: log -n needs a positive number", parseCLI(["log", "-n", "0"]), .help(error: "log -n needs a positive number"))
    check("cli: log -c refuses an unknown category", { if case .help(let e) = parseCLI(["log", "-c", "nope"]) { return e?.hasPrefix("log -c needs one of") == true }; return false }())
    expect("cli: log --since refuses junk", parseCLI(["log", "--since", "soon"]), .help(error: "log --since needs a duration such as 30s, 10m or 2h"))
    expect("cli: log two modes are refused", parseCLI(["log", "path", "--stats"]), .help(error: "log: choose one of tail, -f, grep, path, --stats"))
    expect("cli: log --stats -f is refused", parseCLI(["log", "--stats", "-f"]), .help(error: "log -f works with tail and grep"))

    expect("cli: trail is the last 30 minutes", parseCLI(["trail"]), .trail(TrailOptions()))
    var t = TrailOptions(); t.window = 600; t.all = true
    expect("cli: trail 10 --all", parseCLI(["trail", "10", "--all"]), .trail(t))
    var ts = TrailOptions(); ts.window = 7200
    expect("cli: trail --since 2h", parseCLI(["trail", "--since", "2h"]), .trail(ts))
    expect("cli: trail refuses a word", parseCLI(["trail", "lots"]), .help(error: "trail: \"lots\" isn't a number of minutes"))

    expect("cli: why-quit defaults to 3", parseCLI(["why-quit"]), .whyQuit(3))
    expect("cli: why-quit 10", parseCLI(["why-quit", "10"]), .whyQuit(10))
    expect("cli: why-quit 0 is refused", parseCLI(["why-quit", "0"]), .help(error: "why-quit takes a number of runs"))

    var r = ReportOptions(); r.out = "/tmp/x.zip"; r.since = 86400; r.logs = false; r.description = "picture froze"
    expect("cli: report with options and a description", parseCLI(["report", "--out", "/tmp/x.zip", "--since", "1d", "--no-logs", "picture", "froze"]), .report(r))
    expect("cli: report --out needs a path", parseCLI(["report", "--out"]), .help(error: "report --out needs a path"))

    expect("cli: paircode goes to the host", parseCLI(["paircode"]), .forward(.host, ["paircode"]))
    expect("cli: unpair goes to the host", parseCLI(["unpair", "Air"]), .forward(.host, ["unpair", "Air"]))
    expect("cli: pair goes to the viewer", parseCLI(["pair", "mini", "123456"]), .forward(.viewer, ["pair", "mini", "123456"]))
    expect("cli: machines goes to the viewer", parseCLI(["machines", "--json"]), .forward(.viewer, ["machines", "--json"]))
    expect("cli: ls goes to the viewer", parseCLI(["ls", "mini"]), .forward(.viewer, ["ls", "mini"]))
    expect("cli: ls needs a host", parseCLI(["ls"]), .help(error: "ls needs a host"))
    expect("cli: open goes to the viewer", parseCLI(["open", "mini", "Safari"]), .forward(.viewer, ["open", "mini", "Safari"]))
    expect("cli: open needs two words", parseCLI(["open", "mini"]), .help(error: "open needs a host and a window ID or part of its title"))
    expect("cli: recent goes to the viewer", parseCLI(["recent"]), .forward(.viewer, ["recent"]))
    expect("cli: recent 2 goes to the viewer", parseCLI(["recent", "2"]), .forward(.viewer, ["recent", "2"]))
    expect("cli: recent 0 is refused", parseCLI(["recent", "0"]), .help(error: "recent takes an entry number (1 is the newest)"))
    expect("cli: an unknown command is refused", parseCLI(["frobnicate"]), .help(error: "unknown command \"frobnicate\""))
    check("cli: usage lists every command", ["doctor", "log", "trail", "why-quit", "report", "env", "version", "machines", "ls", "open", "recent"].allSatisfy { cliUsage.contains("\n  \($0)") })
}

private let mixed = [
    line("2026-11-04T10:00:00Z", .info, "host", 10, .host, "host started version=0.1.0 launchedBy=user previousExit=none"),
    line("2026-11-04T10:00:01Z", .info, "host", 10, .stage, "stage ready for a 1512x982 viewer: display 5"),
    line("2026-11-04T10:00:02Z", .info, "host", 10, .encode, "window 4: encode 2.3 ms, 42 encoded"),
    line("2026-11-04T10:00:03Z", .warn, "host", 10, .net, "send to view-a failed: gone"),
    line("2026-11-04T10:00:04Z", .info, "host", 10, .capture, "window 4: capture scale 2.00 -> 1.50 (encode 31.0 ms)"),
    line("2026-11-04T10:00:05Z", .warn, "host", 10, .net, "send to view-b failed: gone again"),
    line("2026-11-04T10:00:06Z", .info, "host", 10, .host, "list from view-a"),
    line("2026-11-04T10:00:07Z", .error, "watchdog", 9, .watchdog, "watchdog: host 10 has not answered for 61 s; sampling it, then killing it"),
    line("2026-11-04T10:00:08Z", .info, "host", 10, .clipboard, "clipboard: received 5 bytes from view-a"),
    line("2026-11-04T10:00:09Z", .debug, "host", 10, .input, "mouse from view-a win 4"),
    line("2026-11-04T10:00:10Z", .info, "host", 10, .encode, "window 4: encode 2.6 ms, 40 encoded"),
].joined(separator: "\n")

private func logQueryTests() {
    let all = lines(mixed)
    expect("query: everything", LogQuery().select(all).count, 11)
    expect("query: by category", LogQuery(category: .encode).select(all).map(\.text.count).count, 2)
    expect("query: by minimum level", LogQuery(level: .warn).select(all).count, 3)
    expect("query: by role", LogQuery(role: "watchdog").select(all).count, 1)
    expect("query: since", LogQuery(since: at("2026-11-04T10:00:08Z")).select(all).count, 3)
    expect("query: grep is case-insensitive over the whole line", LogQuery(pattern: "SEND TO").select(all).count, 2)
    expect("query: grep sees the category tag", LogQuery(pattern: #"\[capture\]"#).select(all).count, 1)
    expect("query: the limit keeps the last lines after filtering", LogQuery(category: .encode, limit: 1).select(all).map(\.text), ["window 4: encode 2.6 ms, 40 encoded"])
    var o = LogOptions(); o.since = 60
    expect("query: options --since counts back from now", LogQuery(o, now: at("2026-11-04T10:01:05Z")).select(all).count, 6)
    var g = LogOptions(); g.mode = .grep("x")
    expect("query: grep has no default limit", LogQuery(g).limit, nil)
    expect("query: tail defaults to 50", LogQuery(LogOptions()).limit, 50)

    let stats = logStats(all)
    expect("stats: biggest bucket first, ties in order of appearance", stats.prefix(2).map { "\($0.event) \($0.count)" }, ["window #: encode # ms 2", "send to # failed 2"])
    expect("stats: the encode samples bucket together", stats.first { $0.event == "window #: encode # ms" }?.count, 2)
    expect("stats: first and last times", stats.first { $0.event == "send to # failed" }.map { [$0.first!, $0.last!] }, [at("2026-11-04T10:00:03Z"), at("2026-11-04T10:00:05Z")])
    expect("stats: most severe level wins", logStats(lines([line("2026-11-04T10:00:00Z", .info, "host", 1, .host, "a b"), line("2026-11-04T10:00:01Z", .error, "host", 1, .host, "a b")].joined(separator: "\n"))).first?.level, .error)
    check("stats: renders a row per bucket", renderStats(stats).split(separator: "\n").count == stats.count)

    let problems = recentProblems(all)
    expect("problems: only warnings and errors", problems.map(\.count).reduce(0, +), 3)
    expect("problems: newest event first", problems.first?.event, "watchdog: host # has not answered")
    expect("problems: repeats are counted", problems.first { $0.event == "send to # failed" }?.count, 2)
    expect("problems: the limit counts lines, not buckets", recentProblems(all, limit: 1).map(\.count), [1])
    check("problems: rendered with counts", renderProblems(problems).contains("2× warn send to # failed"))
    expect("problems: none", renderProblems([]), "none")
}

private func trailTests() {
    let all = lines(mixed)
    let trail = Trail.select(all, since: at("2026-11-04T09:00:00Z"))
    expect("trail: keeps the events that matter", trail.map(\.event), [
        "host started version=# launchedBy=user previousExit=none", "stage ready for a # viewer", "send to # failed",
        "window #: capture scale", "send to # failed", "watchdog: host # has not answered",
    ])
    expect("trail: --all keeps every info line but not debug", Trail.select(all, since: .distantPast, all: true).count, 10)
    expect("trail: since cuts the start", Trail.select(all, since: at("2026-11-04T10:00:04Z")).count, 3)
    let more = lines([
        line("2026-11-04T10:00:00Z", .info, "host", 1, .stage, "stage modes: 1512x982@3024"),
        line("2026-11-04T10:00:01Z", .info, "host", 1, .stage, "stage: parked window 4 at (0, 0), scale 2.0"),
        line("2026-11-04T10:00:02Z", .info, "host", 1, .stage, "stage: unparked window 4 back to (10, 10)"),
        line("2026-11-04T10:00:03Z", .info, "host", 1, .encode, "window 4: stream now 60 fps, level 2.0, 20000 kbps cap"),
        line("2026-11-04T10:00:04Z", .info, "host", 1, .host, "open from view-a"),
        line("2026-11-04T10:00:05Z", .info, "host", 1, .host, "close from view-a"),
        line("2026-11-04T10:00:06Z", .info, "host", 1, .net, "host rejoined the room"),
        line("2026-11-04T10:00:07Z", .info, "host", 1, .resize, "resize from view-a"),
        line("2026-11-04T10:00:08Z", .info, "watchdog", 2, .watchdog, "watchdog relaunch reason=crash"),
        line("2026-11-04T10:00:09Z", .info, "viewer", 3, .viewer, "reconnected to mini"),
        line("2026-11-04T10:00:10Z", .info, "host", 1, .host, "thumb from view-a"),
        line("2026-11-04T10:00:11Z", .info, "host", 1, .audio, "audio: stopped"),
    ].joined(separator: "\n"))
    expect("trail: stage moves, budget, open/close, reconnects, resize, relaunches and viewer lines; no mode lists, thumbnails or audio",
           Trail.select(more, since: .distantPast).count, 9)
    check("trail: renders one row per event with the role", Trail.render(Array(more.prefix(2))).contains("host:1"))
    expect("trail: an empty window says so", Trail.render([]), "Nothing happened in that window.")
    let burst = lines([
        line("2026-11-04T10:00:00Z", .info, "host", 1, .resize, "resize from view-a"),
        line("2026-11-04T10:00:01Z", .info, "host", 1, .resize, "resize from view-a"),
        line("2026-11-04T10:00:02Z", .info, "host", 1, .resize, "resize from view-b"),
        line("2026-11-04T10:00:03Z", .info, "host", 1, .stage, "stage: released"),
        line("2026-11-04T10:00:04Z", .info, "host", 1, .resize, "resize from view-a"),
    ].joined(separator: "\n"))
    expect("trail: a burst of the same event collapses", Trail.collapse(burst).map(\.repeats), [3, 1, 1])
    expect("trail: the burst remembers its last time", Trail.collapse(burst).first?.last, at("2026-11-04T10:00:02Z"))
    check("trail: the collapsed row shows the count", Trail.render(burst).contains("(×3, last 10:00:02)"))
}

private func whyQuitTests() {
    let log = [
        line("2026-11-04T08:00:00Z", .info, "watchdog", 5, .watchdog, "watchdog started (pid 5, app /Applications/Porthole Host.app, hang limit 60 s)"),
        line("2026-11-04T08:00:00Z", .info, "watchdog", 5, .watchdog, "watchdog launch reason=login"),
        line("2026-11-04T08:00:01Z", .info, "host", 100, .host, "host started version=0.1.0 launchedBy=watchdog previousExit=none"),
        line("2026-11-04T08:10:00Z", .info, "host", 100, .host, "quitting (quit)"),
        line("2026-11-04T08:10:00Z", .info, "host", 100, .host, "terminating (quit)"),
        line("2026-11-04T09:00:00Z", .info, "host", 200, .host, "host started version=0.1.0 launchedBy=user previousExit=quit"),
        line("2026-11-04T09:05:00Z", .info, "host", 200, .host, "open from view-a"),
        line("2026-11-04T09:05:02Z", .info, "watchdog", 5, .watchdog, "watchdog relaunch reason=crash"),
        line("2026-11-04T09:05:03Z", .info, "host", 300, .host, "host started version=0.1.0 launchedBy=watchdog previousExit=none"),
        line("2026-11-04T09:30:00Z", .error, "watchdog", 5, .watchdog, "watchdog: host 300 has not answered for 61 s; sampling it, then killing it"),
        line("2026-11-04T09:30:05Z", .info, "watchdog", 5, .watchdog, "watchdog: hang sample written to /Users/me/Library/Logs/Porthole/hang-2026-11-04T093000Z.txt"),
        line("2026-11-04T09:30:06Z", .info, "watchdog", 5, .watchdog, "watchdog relaunch reason=hang"),
        line("2026-11-04T09:30:07Z", .info, "host", 400, .host, "host started version=0.1.0 launchedBy=watchdog previousExit=none"),
        line("2026-11-04T10:00:00Z", .info, "host", 400, .host, "terminating (session)"),
        line("2026-11-04T10:00:45Z", .info, "watchdog", 5, .watchdog, "watchdog relaunch reason=missingAfterQuit"),
        line("2026-11-04T10:00:46Z", .info, "host", 500, .host, "host started version=0.1.0 launchedBy=watchdog previousExit=session"),
        line("2026-11-04T10:20:00Z", .warn, "host", 500, .host, "caught SIGTERM; stopping"),
        line("2026-11-04T11:00:00Z", .info, "host", 600, .host, "host started version=0.2.0 launchedBy=user previousExit=none"),
        line("2026-11-04T11:00:30Z", .info, "host", 600, .host, "host ready"),
    ].joined(separator: "\n")
    let runs = deriveRuns(lines(log), alive: [600])
    expect("why-quit: one run per host pid", runs.map { $0.pid ?? 0 }, [100, 200, 300, 400, 500, 600])
    expect("why-quit: the causes", runs.map(\.cause.key), ["quit", "killed", "hang", "session", "signal", "running"])
    expect("why-quit: a menu quit", runs[0].cause, .quit)
    expect("why-quit: uptime from first to last line", runs[0].uptime, 599)
    expect("why-quit: launched by", runs[0].launchedBy, "watchdog")
    expect("why-quit: a watchdog crash relaunch with no report is no trace, not a crash", runs[1].cause, .noTrace)
    check("why-quit: no trace says there is no crash report", RunCause.noTrace.summary.contains("no crash report") && RunCause.noTrace.summary.contains("SIGKILL"))
    expect("why-quit: the crash was relaunched", runs[1].relaunch, "crash")
    expect("why-quit: a hang keeps its sample path", runs[2].cause, .hang(sample: "/Users/me/Library/Logs/Porthole/hang-2026-11-04T093000Z.txt"))
    expect("why-quit: a hang ends when the watchdog gave up on it", runs[2].end, at("2026-11-04T09:30:00Z"))
    expect("why-quit: a session end", runs[3].cause, .session)
    expect("why-quit: the session end was relaunched after 45 s", runs[3].relaunch, "missingAfterQuit")
    expect("why-quit: a signal", runs[4].cause, .signal("SIGTERM"))
    expect("why-quit: the live one is running", runs[5].cause, .running)
    expect("why-quit: the version", runs[5].version, "0.2.0")
    let notAlive = deriveRuns(lines(log), alive: [])
    expect("why-quit: the last one, gone without a word, is killed with no trace", notAlive.last?.cause, .noTrace)
    let report = CrashReport(path: "/Users/me/Library/Logs/DiagnosticReports/porthole-host-2026-11-04-090501.ips", time: at("2026-11-04T09:05:01Z"), pid: 200)
    expect("why-quit: a crash report with the same pid is named", deriveRuns(lines(log), alive: [600], crashes: [report])[1].cause, .crash(report: report.path))
    let otherPid = CrashReport(path: "/x.ips", time: at("2026-11-04T09:05:01Z"), pid: 999)
    expect("why-quit: a crash report for another pid is not", deriveRuns(lines(log), alive: [600], crashes: [otherPid])[1].cause, .noTrace)
    expect("why-quit: the exit marker explains a silent last run", deriveRuns(lines(log), alive: [], lastMarker: "quit").last?.cause, .quit)
    check("why-quit: render names the pid, uptime and cause", runs[2].render().contains("pid 300") && runs[2].render().contains("up 24m 57s") && runs[2].render().contains("sample /Users/me"))
    check("why-quit: render of a relaunched run says so", runs[3].render().contains("the watchdog relaunched it (missingAfterQuit)"))
    expect("why-quit: no host lines, no runs", deriveRuns(lines(line("2026-11-04T08:00:00Z", .info, "watchdog", 5, .watchdog, "watchdog started"))), [])
}

private func legacyWhyQuitTests() {
    let old = """
    2026-11-04T11:10:00Z permissions: screen recording true, accessibility true, keep running true (watchdog enabled)
    2026-11-04T11:10:01Z host ready
    2026-11-04T11:12:00Z open from view-a
    2026-11-04T11:12:30Z quitting (quit)
    2026-11-04T11:20:00Z permissions: screen recording true, accessibility true, keep running true (watchdog enabled)
    2026-11-04T11:20:01Z host ready
    2026-11-04T11:25:00Z watchdog relaunch reason=crash
    2026-11-04T11:25:01Z launched by the watchdog, reason=crash
    2026-11-04T11:25:01Z stopping older host instance(s) [12]
    2026-11-04T11:25:02Z permissions: screen recording true, accessibility true, keep running true (watchdog enabled)
    2026-11-04T11:25:03Z host ready
    2026-11-04T11:40:00Z watchdog: host 77 has not answered for 60 s; sampling it, then killing it
    2026-11-04T11:40:05Z watchdog: hang sample written to /tmp/hang-1.txt
    2026-11-04T11:40:06Z watchdog relaunch reason=hang
    2026-11-04T11:40:07Z launched by the watchdog, reason=hang
    2026-11-04T11:40:08Z permissions: screen recording true, accessibility true, keep running true (watchdog enabled)
    2026-11-04T11:50:00Z keep running: watchdog agent registered, status enabled
    2026-11-04T11:55:00Z viewer left: view-a
    2026-11-04T11:59:00Z watchdog relaunch reason=missingAfterQuit
    """
    let runs = deriveRuns(lines(old))
    expect("old log: runs split at each permissions line", runs.count, 4)
    expect("old log: causes; a crash relaunch with no report is no trace", runs.map(\.cause.key), ["quit", "killed", "hang", "session"])
    expect("old log: the watchdog's launch lines start the next run", runs[2].start, at("2026-11-04T11:25:01Z"))
    expect("old log: a mid-run settings line stays in its run", runs[3].end, at("2026-11-04T11:55:00Z"))
    expect("old log: the hang sample", runs[2].cause, .hang(sample: "/tmp/hang-1.txt"))
    expect("old log: a running host with no pids is running", deriveRuns(lines(old), hostRunning: true).last?.cause, .session)
    let silent = deriveRuns(lines("2026-11-04T11:10:00Z permissions: screen recording true\n2026-11-04T11:10:01Z host ready"), hostRunning: true)
    expect("old log: the live old run is running", silent.first?.cause, .running)
}

private func scrubTests() {
    let s = Scrubber(secrets: ["hunter2-long-pw", "abc"])
    expect("scrub: a known secret", s.scrub("password is hunter2-long-pw ok"), "password is [redacted] ok")
    expect("scrub: short known secrets are left alone", s.scrub("abc def"), "abc def")
    expect("scrub: ?pw= in a link", s.scrub("http://mini:7878/?pw=Zx81_aa&name=x"), "http://mini:7878/?pw=[redacted]&name=x")
    expect("scrub: token= and secret=", s.scrub("token=eyJx secret=s3cr3t"), "token=[redacted] secret=[redacted]")
    expect("scrub: JSON secrets", s.scrub(#"{"apiSecret": "zzz", "password":"p", "name":"Mini"}"#), #"{"apiSecret":"[redacted]", "password":"[redacted]", "name":"Mini"}"#)
    expect("scrub: a JWT", s.scrub("got eyJhbGciOiJIUzI1.eyJzdWIiOiJ2aWV3.SflKxwRJSMeKKF2QT4f now"), "got [redacted] now")
    expect("scrub: a bearer token", s.scrub("Authorization: Bearer abc.def"), "Authorization: [redacted]")
    expect("scrub: the local secret header", s.scrub("X-Porthole-Local: kkkkkkkk"), "X-Porthole-Local: [redacted]")
    expect("scrub: a pairing code", s.scrub("pairing code 123 456 for Air"), "pairing code [redacted] for Air")
    expect("scrub: code=123456", s.scrub("code=123456"), "code=[redacted]")
    let plain = "2026-11-04T11:55:09Z info host:1 [stage] stage: parked window 62763 at (0, 0), scale 2.0"
    expect("scrub: ordinary lines are untouched", s.scrub(plain), plain)
    expect("scrub: a 16-hex device ID is shortened", s.scrub("paired device 0123456789abcdef (Air)"), "paired device 01234567… (Air)")
    expect("scrub: a device ID in a field is shortened", s.scrub("open from view-a device=a1b2c3d4e5f60718 ok"), "open from view-a device=a1b2c3d4… ok")
    expect("scrub: longer hex runs are left alone", s.scrub("sha 0123456789abcdef0123"), "sha 0123456789abcdef0123")
    expect("scrub: window IDs and times are left alone", s.scrub("window 62763 at 2026-11-04T11:55:09Z"), "window 62763 at 2026-11-04T11:55:09Z")
    expect("short id: 16 hex characters become 8 and an ellipsis", shortID("0123456789abcdef"), "01234567…")
    expect("short id: short ids stay", shortID("abc"), "abc")
}

private func envFlagTests() {
    let names = Set(EnvFlags.all.map(\.name))
    for n in ["PORTHOLE_HOME", "PORTHOLE_WATCHDOG", "PORTHOLE_WATCHDOG_HANG_SECS", "PORTHOLE_STAGE_IDLE_SECS", "PORTHOLE_ENCODE_LOG",
              "PORTHOLE_ENCODE_BUDGET_MS", "PORTHOLE_PAIR_HEADLESS", "PORTHOLE_WEB_ROOT", "PORTHOLE_LIVEKIT_SERVER", "PORTHOLE_OPEN",
              "PORTHOLE_COMMAND", "PORTHOLE_WATCHDOG_RELAUNCH", "PORTHOLE_LAUNCH_AGENT", "PORTHOLE_LOG"] {
        check("env: \(n) is listed", names.contains(n))
    }
    expect("env: every name is unique", names.count, EnvFlags.all.count)
    expect("env: the hang default matches the watchdog", EnvFlags.all.first { $0.name == "PORTHOLE_WATCHDOG_HANG_SECS" }?.defaultValue, String(Int(WatchdogMonitor.hangLimit(from: nil))))
    expect("env: the Stage default matches the Stage", EnvFlags.all.first { $0.name == "PORTHOLE_STAGE_IDLE_SECS" }?.defaultValue, String(Int(StageLayout.idleSeconds)))
    let env = ["PORTHOLE_WATCHDOG": "0", "PORTHOLE_PW": "sekrit", "PORTHOLE_TYPO": "1", "PATH": "/bin"]
    let set = EnvFlags.rows(environment: env, setOnly: true)
    expect("env --set: only the set ones, unknown ones last", set.map(\.flag.name), ["PORTHOLE_WATCHDOG", "PORTHOLE_PW", "PORTHOLE_TYPO"])
    expect("env: an unknown PORTHOLE_ flag is marked unknown", set.last?.known, false)
    expect("env: secret values are masked", EnvFlags.shown(set[1]), "[redacted]")
    expect("env: plain values are shown", EnvFlags.shown(set[0]), "0")
    expect("env: every flag is a row", EnvFlags.rows(environment: [:], setOnly: false).count, EnvFlags.all.count)
    check("env: render shows unset values", EnvFlags.render(EnvFlags.rows(environment: [:], setOnly: false)).contains("(unset)"))
    check("env: json masks secrets", (EnvFlags.json(set)[1]["current"] as? String) == "[redacted]")
    let odd = EnvFlags.rows(environment: ["PORTHOLE_API_KEY": "k1", "PORTHOLE_my_pass": "p1", "PORTHOLE_OLD_PW": "p2", "PORTHOLE_AuthToken": "t1",
                                          "PORTHOLE_SECRET2": "s1", "PORTHOLE_TYPO": "visible"], setOnly: true)
    expect("env: unknown flags named like secrets are masked, others shown", odd.map { "\($0.flag.name)=\(EnvFlags.shown($0))" },
           ["PORTHOLE_API_KEY=[redacted]", "PORTHOLE_AuthToken=[redacted]", "PORTHOLE_OLD_PW=[redacted]", "PORTHOLE_SECRET2=[redacted]",
            "PORTHOLE_TYPO=visible", "PORTHOLE_my_pass=[redacted]"])
    check("env: render never prints a masked unknown value", !EnvFlags.render(odd).contains("k1") && !EnvFlags.render(odd).contains("p1"))
}

private func recentTests() {
    let t0 = Date(timeIntervalSince1970: 1_793_793_309)
    let a = RecentPortal(host: "100.64.0.2", hostName: "Mini", windowID: 4, title: "Notes", app: "TextEdit", bundle: nil, time: t0)
    let b = RecentPortal(host: "100.64.0.2", hostName: "Mini", windowID: 5, title: "Inbox", app: "Mail", bundle: nil, time: t0 + 1)
    var list = RecentPortals.adding(a, to: [])
    list = RecentPortals.adding(b, to: list)
    expect("recent: newest first", list.map(\.windowID), [5, 4])
    var again = a; again.time = t0 + 2
    list = RecentPortals.adding(again, to: list)
    expect("recent: reopening moves it to the top without a duplicate", list.map(\.windowID), [4, 5])
    var moved = a; moved.windowID = 99; moved.time = t0 + 3
    expect("recent: the same app and title on the same host is the same portal", RecentPortals.adding(moved, to: list).map(\.windowID), [99, 5])
    var other = a; other.host = "mini.local"
    expect("recent: another host is another portal", RecentPortals.adding(other, to: list).count, 3)
    var many: [RecentPortal] = []
    for i in 0..<30 { many = RecentPortals.adding(RecentPortal(host: "h", hostName: "h", windowID: UInt32(i), title: "t\(i)", app: "A", bundle: nil, time: t0), to: many) }
    expect("recent: capped at 20", many.count, RecentPortals.maxCount)
    expect("recent: round-trips through JSON", RecentPortals.decode(RecentPortals.encode(list)), list)
    expect("recent: junk decodes to nothing", RecentPortals.decode(Data("nope".utf8)), [])
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    RecentPortals.record(a, in: dir)
    RecentPortals.record(b, in: dir)
    expect("recent: recorded to disk", RecentPortals.load(in: dir).map(\.windowID), [5, 4])
    let mode = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(RecentPortals.fileName).path))?[.posixPermissions] as? Int
    expect("recent: the file is private", mode, 0o600)

    let live = [win(4, "TextEdit", "Other"), win(7, "TextEdit", "Notes"), win(8, "Mail", "Inbox")]
    expect("recent match: the same id and app", RecentPortals.match(a, in: [win(4, "TextEdit", "Renamed")])?.id, 4)
    expect("recent match: a reused id for another app is not it", RecentPortals.match(a, in: [win(4, "Safari", "x")]), nil)
    expect("recent match: the app and title after the id changed", RecentPortals.match(moved, in: live)?.id, 7)
    expect("recent match: the only window of that app", RecentPortals.match(b, in: [win(9, "Mail", "Drafts")])?.id, 9)
    expect("recent match: two windows of that app and no title match is no match", RecentPortals.match(b, in: [win(9, "Mail", "Drafts"), win(10, "Mail", "Sent")]), nil)
    check("recent: render numbers entries from 1", RecentPortals.render(list, now: t0 + 60).hasPrefix("  1  TextEdit — Notes"))
}

private func pickTests() {
    let list = [win(10, "Safari", "Apple"), win(11, "Safari", "GitHub"), win(12, "Notes", "Shopping"), win(13, "Terminal", "apple")]
    expect("pick: by window ID", pickWindow("12", in: list), .found(list[2]))
    expect("pick: by id:", pickWindow("id:11", in: list), .found(list[1]))
    expect("pick: an unknown id: is nothing", pickWindow("id:99", in: list), .none)
    expect("pick: by unique part of the title", pickWindow("git", in: list), .found(list[1]))
    expect("pick: by app name", pickWindow("notes", in: list), .found(list[2]))
    expect("pick: ambiguous text lists every match", pickWindow("apple", in: list), .ambiguous([list[0], list[3]]))
    expect("pick: an exact app and title wins over partial matches", pickWindow("Terminal apple", in: list), .found(list[3]))
    expect("pick: nothing matches", pickWindow("zzz", in: list), .none)
    expect("pick: empty is nothing", pickWindow("  ", in: list), .none)
    expect("auto open: id:", autoOpenWindow("id:13", in: list)?.id, 13)
    expect("auto open: text keeps the old first-match rule", autoOpenWindow("Safari", in: list)?.id, 10)
    expect("auto open: unset", autoOpenWindow(nil, in: list), nil)
    expect("auto open: a bad id:", autoOpenWindow("id:x", in: list), nil)
    let trust = ViewerTrust(hosts: [PairedHost(id: "0123456789abcdef", name: "Mini", addresses: ["100.64.0.2"])])
    expect("host name: a paired name resolves to its address", resolveHostAddress("mini", trust: trust, known: []), "100.64.0.2")
    expect("host name: a saved host's name resolves", resolveHostAddress("Studio", trust: ViewerTrust(hosts: []), known: [KnownHost(name: "Studio", address: "studio.local")]), "studio.local")
    expect("host name: an address passes through", resolveHostAddress("10.0.0.5", trust: trust, known: []), "10.0.0.5")
    check("window list: renders ids and apps", renderWindowList(list).contains("     10  Safari"))
}

private func placementTests() {
    let main = DisplayRect(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isStage: false)
    let side = DisplayRect(id: 2, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080), isStage: false)
    let stage = DisplayRect(id: 5, bounds: CGRect(x: 3840, y: 0, width: 1512, height: 982), isStage: true)
    let ds = [main, side, stage]
    expect("placement: on the main display", placeWindow(CGRect(x: 100, y: 100, width: 800, height: 600), displays: ds), .onDisplay([1]))
    expect("placement: across two displays", placeWindow(CGRect(x: 1800, y: 100, width: 400, height: 300), displays: ds), .onDisplay([1, 2]))
    expect("placement: on the Stage", placeWindow(CGRect(x: 3900, y: 50, width: 800, height: 600), displays: ds), .onStage)
    expect("placement: off every display", placeWindow(CGRect(x: -5000, y: -5000, width: 800, height: 600), displays: ds), .offDisplay)
    expect("placement: mostly off", placeWindow(CGRect(x: -700, y: 0, width: 800, height: 600), displays: ds), .partlyOff(0.125))
    check("placement: on-display is not flagged, the rest are", !WindowPlacement.onDisplay([1]).flagged && WindowPlacement.onStage.flagged && WindowPlacement.offDisplay.flagged)
    expect("placement: label", WindowPlacement.partlyOff(0.125).label, "partly off-display (13% visible)")
}

private func doctorModelTests() {
    let now = at("2026-11-04T12:00:00Z")
    expect("doctor: no host process fails", hostRunningCheck(status: nil, pids: [], now: now).status, .fail)
    expect("doctor: a host that doesn't answer is a warning", hostRunningCheck(status: nil, pids: [7], now: now).status, .warn)
    let fresh: [String: Any] = ["pid": 7, "started": "2026-11-04T11:00:00.000Z", "updated": "2026-11-04T11:59:58.000Z", "state": "Sharing", "connected": true]
    let ok = hostRunningCheck(status: fresh, pids: [7], now: now)
    expect("doctor: a healthy host", ok.status, .ok)
    expect("doctor: its detail", ok.detail, "pid 7, up 1h 00m, Sharing")
    var stale = fresh; stale["updated"] = "2026-11-04T11:59:00.000Z"
    check("doctor: a stale snapshot hints at a hang", hostRunningCheck(status: stale, pids: [7], now: now).status == .warn && hostRunningCheck(status: stale, pids: [7], now: now).detail.contains("may be hung"))
    var offline = fresh; offline["connected"] = false
    expect("doctor: not in its own room is a warning", hostRunningCheck(status: offline, pids: [7], now: now).status, .warn)
    expect("doctor: two host processes is a warning", hostRunningCheck(status: fresh, pids: [7, 8], now: now).status, .warn)
    expect("doctor: an unused Stage", stageCheck(["ready": false], now: now).detail, "not in use (created when a viewer opens a window)")
    let st = stageCheck(["ready": true, "display": 5, "bounds": [3840.0, 0.0, 1512.0, 982.0], "parked": 2, "idleSince": "2026-11-04T11:58:00.000Z", "idleLimit": 600], now: now)
    expect("doctor: a Stage in use", st.detail, "display 5 at 3840,0 1512x982, 2 window(s) parked, empty for 2m 00s; released after 10m 00s")
    let text = renderDoctor([DoctorCheck("Host", "running", .ok, "fine"), DoctorCheck("Host", "accessibility", .fail, "missing\nsecond line"),
                             DoctorCheck("Network", "Tailscale", .warn, "off")], header: "Porthole doctor")
    check("doctor: sections and marks", text.contains("\nHost\n  ✓ running") && text.contains("✗ accessibility") && text.contains("\nNetwork\n  ! Tailscale"))
    check("doctor: continuation lines line up under the detail", text.contains("\n" + String(repeating: " ", count: 4 + "accessibility".count + 2) + "second line"))
    check("doctor: the summary counts problems", text.hasSuffix("1 problem(s), 1 warning(s)."))
    check("doctor: all good says so", renderDoctor([DoctorCheck("Host", "running", .ok, "fine")], header: "h").hasSuffix("No problems found."))
}

private func logFileTests() {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let w = LogWriter(role: "watchdog", directory: dir, echo: false)
    expect("log writer: the watchdog writes into host.log", w.url.lastPathComponent, "host.log")
    w.write(.info, nil, "watchdog relaunch reason=crash")
    w.write(.debug, .watchdog, "hidden unless verbose")
    w.flush()
    w.writeNow(.warn, .host, "caught SIGTERM; stopping")
    let back = LogFiles.read(role: "host", in: dir)
    expect("log writer: lines read back", back.map(\.text), ["watchdog relaunch reason=crash", "caught SIGTERM; stopping"])
    expect("log writer: role and pid are written", back.first.map { "\($0.role) \($0.pid ?? 0)" }, "watchdog \(getpid())")
    expect("log writer: a missing category is inferred", back.first?.category, .watchdog)
    let v = LogWriter(role: "viewer", directory: dir, echo: false, verbose: true)
    v.write(.debug, .viewer, "debug line")
    v.flush()
    expect("log writer: verbose keeps debug lines", LogFiles.read(role: "viewer", in: dir).map(\.level), [.debug])

    let live = LogFiles.url(role: "host", in: dir)
    try? Data(repeating: 65, count: 64).write(to: live)
    expect("rotate: a small file stays", LogFiles.rotateIfNeeded(role: "host", in: dir, maxBytes: 100), false)
    try? Data(repeating: 66, count: 200).write(to: live)
    expect("rotate: a big file moves aside", LogFiles.rotateIfNeeded(role: "host", in: dir, maxBytes: 100), true)
    expect("rotate: host.1.log holds it", (try? Data(contentsOf: LogFiles.generation(1, role: "host", in: dir)))?.count, 200)
    try? Data(repeating: 67, count: 300).write(to: live)
    _ = LogFiles.rotateIfNeeded(role: "host", in: dir, maxBytes: 100)
    expect("rotate: generations shift up", (try? Data(contentsOf: LogFiles.generation(2, role: "host", in: dir)))?.count, 200)
    expect("rotate: generations read oldest first", LogFiles.generations(role: "host", in: dir).map(\.lastPathComponent), ["host.2.log", "host.1.log"])
    for _ in 0..<6 { try? Data(repeating: 68, count: 300).write(to: live); _ = LogFiles.rotateIfNeeded(role: "host", in: dir, maxBytes: 100) }
    check("rotate: at most \(LogFiles.keep) old generations", !FileManager.default.fileExists(atPath: LogFiles.generation(LogFiles.keep + 1, role: "host", in: dir).path))
    rotateLockTests()

    let h = lines("2026-11-04T10:00:00Z a\n2026-11-04T10:00:02Z c\nno time here\n2026-11-04T10:00:04Z e")
    let vw = lines("2026-11-04T10:00:01Z b\n2026-11-04T10:00:03Z d", role: "viewer")
    expect("merge: by time across files, untimed lines stay after their neighbour", LogFiles.merge([h, vw]).map(\.text), ["a", "b", "c", "no time here", "d", "e"])
    check("verbose: PORTHOLE_LOG=debug", verboseFromEnvironment(["PORTHOLE_LOG": "debug"]) && verboseFromEnvironment(["PORTHOLE_VERBOSE": "1"]) && !verboseFromEnvironment([:]))
}

private final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private func rotateLockTests() {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let live = LogFiles.url(role: "viewer", in: dir)
    try? Data(repeating: 70, count: 500).write(to: live)
    let rotated = Counter()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
        if LogFiles.rotateIfNeeded(role: "viewer", in: dir, maxBytes: 100) { rotated.bump() }
    }
    expect("rotate lock: racing rotations move the file once", rotated.n, 1)
    expect("rotate lock: the file lands in viewer.1.log, not shifted twice", LogFiles.generations(role: "viewer", in: dir).map(\.lastPathComponent), ["viewer.1.log"])
    expect("rotate lock: the lock file is per log", LogFiles.lockURL(role: "viewer", in: dir).lastPathComponent, "viewer.log.lock")

    try? Data(repeating: 71, count: 500).write(to: live)
    let fd = open(LogFiles.lockURL(role: "viewer", in: dir).path, O_RDWR | O_CREAT, 0o644)
    _ = flock(fd, LOCK_EX)
    let done = DispatchSemaphore(value: 0)
    let result = Counter()
    DispatchQueue.global().async {
        if LogFiles.rotateIfNeeded(role: "viewer", in: dir, maxBytes: 100) { result.bump() }
        done.signal()
    }
    let waitedWhileLocked = done.wait(timeout: .now() + 0.3) == .timedOut
    check("rotate lock: a rotation waits while another process holds the lock", waitedWhileLocked && FileManager.default.fileExists(atPath: live.path))
    try? FileManager.default.moveItem(at: live, to: dir.appendingPathComponent("moved-by-other.log"))
    _ = flock(fd, LOCK_UN)
    close(fd)
    _ = done.wait(timeout: .now() + 5)
    expect("rotate lock: after the lock, the size is checked again and a rotation already done elsewhere is not repeated", result.n, 0)
    expect("rotate lock: viewer.2.log was not made", FileManager.default.fileExists(atPath: LogFiles.generation(2, role: "viewer", in: dir).path), false)
}

private func shellTests() {
    let echo = Shell.run("/bin/sh", ["-c", "printf hello"])
    expect("shell: output and status", echo.map { "\($0.status) \($0.out)" }, "0 hello")
    expect("shell: a missing tool is nil", Shell.run("/no/such/tool", []) == nil, true)
    let slow = Date()
    let sleeper = Shell.run("/bin/sh", ["-c", "printf early; exec sleep 30"], timeout: 0.5)
    check("shell: a timed-out command is stopped with SIGTERM promptly", Date().timeIntervalSince(slow) < 2.5 && sleeper?.status == SIGTERM)
    expect("shell: output before the timeout is kept", sleeper?.out, "early")
    let stubborn = Date()
    let ignoring = Shell.run("/bin/sh", ["-c", "trap '' TERM; printf x; while :; do sleep 0.1; done"], timeout: 0.5, grace: 0.5)
    check("shell: a command ignoring SIGTERM is killed after the grace period", Date().timeIntervalSince(stubborn) < 4 && ignoring?.status == SIGKILL && ignoring?.out == "x")
    let held = Date()
    let orphan = Shell.run("/bin/sh", ["-c", "sleep 4 & printf done"], timeout: 5)
    check("shell: a child left holding the pipe does not block the read", Date().timeIntervalSince(held) < 2 && orphan?.out == "done" && orphan?.status == 0)
}

private func openHandOffTests() {
    let r = OpenRequest(address: "100.64.0.2", windowID: 62763, token: "t-1")
    expect("open hand-off: the request survives a notification round trip", OpenRequest(userInfo: r.userInfo as [AnyHashable: Any]), r)
    expect("open hand-off: it opens by window ID", r.match, "id:62763")
    expect("open hand-off: a request without a window is ignored", OpenRequest(userInfo: ["address": "x", "token": "t"]), nil)
    expect("open hand-off: a request without a token is ignored", OpenRequest(userInfo: ["address": "x", "window": "1", "token": ""]), nil)
    expect("open hand-off: same host refreshes the list", r.plan(connectedTo: "100.64.0.2", hasCredential: false), .refreshList)
    expect("open hand-off: another host with a saved pairing connects", r.plan(connectedTo: "mini.local", hasCredential: true), .connect)
    expect("open hand-off: no connection and no pairing is refused", r.plan(connectedTo: nil, hasCredential: false), .noCredential)
    let reply = OpenReply(token: "t-1", ok: false, message: "no pairing")
    expect("open hand-off: the reply survives a round trip", OpenReply(userInfo: reply.userInfo as [AnyHashable: Any]), reply)
    expect("open hand-off: a running Porthole gets the request", ViewerLaunch.decide(viewers: [500, 42], me: 42), .handOff([500]))
    expect("open hand-off: only this process running means launch", ViewerLaunch.decide(viewers: [42], me: 42), .launch)
    expect("open hand-off: nothing running means launch", ViewerLaunch.decide(viewers: [], me: 42), .launch)
}

private func localStatusRouteTests() {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    var routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: AccessToken(apiKey: "k", apiSecret: "s"), webRoot: nil,
                           pairing: PairingDesk(random: { 1 }), hostName: "Mini", trust: TrustStore(directory: dir), hostID: nil)
    let secret = String(repeating: "q", count: 43)
    routes.localSecret = secret
    routes.localStatus = { ["pid": 42, "stage": ["ready": false]] }
    func get(_ host: String, _ extra: [String]) -> String {
        "GET /local/status HTTP/1.1\r\nHost: \(host)\r\n" + extra.map { $0 + "\r\n" }.joined() + "\r\n"
    }
    let ok = routes.respond(to: get("127.0.0.1:7878", ["\(localRouteHeader): \(secret)"]), fromLoopback: true)
    check("local status: loopback with the secret gets the snapshot", ok.status == "200 OK" && json(ok.body)?["pid"] as? Int == 42)
    expect("local status: without the secret it's a plain 404", routes.respond(to: get("127.0.0.1:7878", []), fromLoopback: true).status, "404 Not Found")
    expect("local status: from the network it's a plain 404", routes.respond(to: get("mini:7878", ["\(localRouteHeader): \(secret)"]), fromLoopback: false).status, "404 Not Found")
    routes.localStatus = nil
    expect("local status: no snapshot yet is an empty object", String(decoding: routes.respond(to: get("127.0.0.1", ["\(localRouteHeader): \(secret)"]), fromLoopback: true).body, as: UTF8.self), "{}")
}

private func viewerToolCommandTests() {
    expect("viewer command: machines", viewerCommand(["machines"]), .machines(json: false))
    expect("viewer command: machines --json", viewerCommand(["machines", "--json"]), .machines(json: true))
    expect("viewer command: machines with junk", viewerCommand(["machines", "x"]), .usage(error: "machines takes only --json"))
    expect("viewer command: ls", viewerCommand(["ls", "mini", "--json"]), .list(host: "mini", json: true))
    expect("viewer command: list is ls", viewerCommand(["list", "mini"]), .list(host: "mini", json: false))
    expect("viewer command: ls without a host", viewerCommand(["ls"]), .usage(error: "ls needs a host"))
    expect("viewer command: open", viewerCommand(["open", "mini", "Safari"]), .open(host: "mini", target: "Safari"))
    expect("viewer command: open without a window", viewerCommand(["open", "mini"]), .usage(error: "open needs a host and a window ID or part of its title"))
    expect("viewer command: recent", viewerCommand(["recent"]), .recent(nil))
    expect("viewer command: recent 3", viewerCommand(["recent", "3"]), .recent(3))
    expect("viewer command: recent x", viewerCommand(["recent", "x"]), .usage(error: "recent takes an entry number (1 is the newest)"))
    expect("viewer command: a host still opens the app", viewerCommand(["100.64.0.2", "pw"]), .app)
}
