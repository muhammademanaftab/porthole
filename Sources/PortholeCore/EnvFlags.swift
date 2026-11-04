import Foundation

public struct EnvFlag: Equatable, Sendable {
    public var name: String
    public var scope: String
    public var meaning: String
    public var defaultValue: String
    public var secret: Bool

    public init(_ name: String, _ scope: String, _ meaning: String, _ defaultValue: String, secret: Bool = false) {
        self.name = name; self.scope = scope; self.meaning = meaning; self.defaultValue = defaultValue; self.secret = secret
    }
}

public enum EnvFlags {
    public static let all: [EnvFlag] = [
        EnvFlag("PORTHOLE_HOME", "host, viewer", "folder for identity, pairing, config and markers (a second, isolated instance)", "~/Library/Application Support/Porthole"),
        EnvFlag("PORTHOLE_LOG", "host, viewer", "debug: verbose (debug-level) lines for this process, like Settings > Verbose logging", "info"),
        EnvFlag("PORTHOLE_VERBOSE", "host, viewer", "1: the same as PORTHOLE_LOG=debug", "0"),
        EnvFlag("PORTHOLE_WATCHDOG", "host", "0 or 1: whether the watchdog watches this run, without changing the saved Keep running switch", "the saved switch"),
        EnvFlag("PORTHOLE_WATCHDOG_HANG_SECS", "watchdog", "seconds without a heartbeat before the watchdog samples and kills a hung host (at least 15)", "60"),
        EnvFlag("PORTHOLE_STAGE_IDLE_SECS", "host", "seconds the empty Stage waits before it is released (at least 5)", "600"),
        EnvFlag("PORTHOLE_ENCODE_LOG", "host", "1: log every encoder sample (cost, fps, capture scale)", "0"),
        EnvFlag("PORTHOLE_ENCODE_BUDGET_MS", "host", "encode cost per frame above which the capture scale steps down", "30"),
        EnvFlag("PORTHOLE_TEXT_BATCH", "host", "how committed text (dictation, input methods, Paste as Keystrokes) is typed: 0 = one key pair per character; 1 or unset = key pairs carrying up to 200 UTF-16 units; a number = that many units (at most 2000)", "200"),
        EnvFlag("PORTHOLE_SHARE_ALLOW_CONTROL", "host", "Allow Remote Control for this run, not remembered (one switch for every share link): 1 = control links may type and click and a guest's ask is answered yes at once; 0 = every link watches and guests ask", "the saved switch (off)"),
        EnvFlag("PORTHOLE_PAIR_HEADLESS", "host", "1: print pairing codes to standard output without opening the pairing window", "0"),
        EnvFlag("PORTHOLE_WEB_ROOT", "host", "folder served as the browser viewer instead of the bundled web files", "Contents/Resources/web"),
        EnvFlag("PORTHOLE_LIVEKIT_SERVER", "host", "path of the livekit-server binary to run", "the bundled one, then Homebrew's"),
        EnvFlag("PORTHOLE_SOUNDS", "viewer", "0: every sound cue is silent for this run; 1: cues play even with Settings › General › Sound Effects off", "the setting (on)"),
        EnvFlag("PORTHOLE_OPEN", "viewer", "open the first window whose app and title contain this text (or id:<windowID>) once the list arrives", "unset"),
        EnvFlag("PORTHOLE_COMMAND", "internal", "watchdog: run the watchdog loop (set by the launch agent); app: run the host", "app"),
        EnvFlag("PORTHOLE_WATCHDOG_RELAUNCH", "internal", "why the watchdog launched this host (login, crash, hang, remote, migrate, missingAfterQuit)", "unset"),
        EnvFlag("PORTHOLE_LAUNCH_AGENT", "internal", "1: launched by the old login agent, which is then handed over to the watchdog", "unset"),
        EnvFlag("PORTHOLE_APP", "probe", "app whose window the probe opens", "TextEdit"),
        EnvFlag("PORTHOLE_AUDIO", "probe", "set: check that sound arrives", "unset"),
        EnvFlag("PORTHOLE_HOST", "probe", "host the probe connects to", "127.0.0.1"),
        EnvFlag("PORTHOLE_PW", "probe", "host password for the probe", "from config.json", secret: true),
        EnvFlag("PORTHOLE_DEVICE", "probe", "device ID the probe pairs as", "unset"),
        EnvFlag("PORTHOLE_SECRET", "probe", "pairing secret for PORTHOLE_DEVICE", "unset", secret: true),
        EnvFlag("PORTHOLE_EXPECT_UNPAIR", "probe", "set: expect the host to refuse this device", "unset"),
        EnvFlag("PORTHOLE_STREAM", "probe", "stream prefs to ask for, as key=value pairs separated by commas", "unset"),
        EnvFlag("PORTHOLE_CLIP_SEND", "probe", "text to send to the host clipboard", "unset"),
        EnvFlag("PORTHOLE_CLIP_EXPECT", "probe", "text expected back from the host clipboard", "unset"),
        EnvFlag("PORTHOLE_HOLD", "probe", "seconds to keep watching the picture", "unset"),
    ]

    public struct Row: Equatable, Sendable {
        public var flag: EnvFlag
        public var current: String?
        public var known: Bool
    }

    public static func rows(environment: [String: String], setOnly: Bool) -> [Row] {
        var rows = all.map { Row(flag: $0, current: environment[$0.name], known: true) }
        let known = Set(all.map(\.name))
        for name in environment.keys.sorted() where name.hasPrefix("PORTHOLE_") && !known.contains(name) {
            rows.append(Row(flag: EnvFlag(name, "unknown", "not a flag Porthole reads", "-", secret: looksSecret(name)), current: environment[name], known: false))
        }
        return setOnly ? rows.filter { $0.current != nil } : rows
    }

    public static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["PW", "PASS", "SECRET", "TOKEN", "KEY"].contains { upper.contains($0) }
    }

    public static func shown(_ row: Row) -> String {
        guard let v = row.current else { return "(unset)" }
        return row.flag.secret ? Scrubber.mask : v
    }

    public static func render(_ rows: [Row]) -> String {
        guard !rows.isEmpty else { return "No PORTHOLE_* flags are set in this environment." }
        let width = rows.map(\.flag.name.count).max() ?? 20
        return rows.map { r in
            "\(r.flag.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(shown(r))\n" +
            "\(String(repeating: " ", count: width))  \(r.flag.meaning) [\(r.flag.scope); default \(r.flag.defaultValue)]"
        }.joined(separator: "\n")
    }

    public static func json(_ rows: [Row]) -> [[String: Any]] {
        rows.map { r in
            var o: [String: Any] = ["name": r.flag.name, "scope": r.flag.scope, "meaning": r.flag.meaning, "default": r.flag.defaultValue, "known": r.known]
            if r.current != nil { o["current"] = shown(r) }
            return o
        }
    }
}
