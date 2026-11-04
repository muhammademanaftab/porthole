import Foundation

public enum HostCommand: Equatable, Sendable {
    case app, watchdog, agentPlist

    public static let envKey = "PORTHOLE_COMMAND"

    public static func parse(arguments: [String], environment: [String: String]) -> HostCommand {
        if arguments.first == "agent-plist" { return .agentPlist }
        if arguments.first == "watchdog" { return .watchdog }
        if arguments.isEmpty || arguments.first?.hasPrefix("-") == true, environment[envKey] == "watchdog" { return .watchdog }
        return .app
    }
}

public enum WatchdogReason: String, Sendable {
    case login, crash, hang, remote, migrate, missingAfterQuit

    public static let envKey = "PORTHOLE_WATCHDOG_RELAUNCH"
}

public enum ExitMarker: String, Sendable {
    case quit, session, remote, migrate

    public var relaunch: WatchdogReason? {
        switch self {
        case .quit, .session: return nil
        case .remote: return .remote
        case .migrate: return .migrate
        }
    }

    public init?(text: String) {
        self.init(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct Heartbeat: Equatable, Sendable {
    public var pid: Int32
    public var time: Double
    public var watched: Bool

    public static let unwatchedWord = "unwatched"

    public init(pid: Int32, time: Double, watched: Bool = true) { self.pid = pid; self.time = time; self.watched = watched }

    public var text: String { "\(pid) \(String(format: "%.3f", time))\(watched ? "" : " " + Self.unwatchedWord)\n" }

    public init?(text: String) {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count == 2 || (parts.count == 3 && parts[2] == Self.unwatchedWord),
              let pid = Int32(parts[0]), pid > 0, let time = Double(parts[1]), time.isFinite else { return nil }
        self.init(pid: pid, time: time, watched: parts.count == 2)
    }
}

public enum WatchdogAction: Equatable, Sendable {
    case none
    case kill(Int32)
    case launch(WatchdogReason)
}

public struct WatchdogMonitor: Sendable {
    public static let tick: Double = 2
    public static let heartbeatEvery: Double = 5
    public static let defaultHangLimit: Double = 60
    public static let minimumHangLimit: Double = 15
    public static let wakeGap: Double = 15
    public static let launchGap: Double = 10
    public static let crashLoopGap: Double = 120
    public static let crashLoopLaunches = 5
    public static let crashLoopWindow: Double = 600
    public static let missingAfterQuitDelay: Double = 45
    public static let honourQuitAfterUptime: Double = 300
    public static let sampleSeconds = 3
    public static let hangEnvKey = "PORTHOLE_WATCHDOG_HANG_SECS"

    public let hangLimit: Double
    public private(set) var watched: Int32?
    public private(set) var since: Double = 0
    public private(set) var pending: WatchdogReason?
    private var lastTick: Double?
    private var hungPid: Int32?
    private var optedOut = false
    private var sessionEndedAt: Double?
    private var launches: [Double] = []

    public init(hangLimit: Double = defaultHangLimit) {
        self.hangLimit = max(hangLimit, Self.minimumHangLimit)
    }

    public static func hangLimit(from env: String?) -> Double {
        guard let env, let n = Double(env), n.isFinite else { return defaultHangLimit }
        return max(n, minimumHangLimit)
    }

    public static func isHung(heartbeat: Heartbeat?, pid: Int32, watchingSince: Double, now: Double, limit: Double) -> Bool {
        let beat = heartbeat.flatMap { $0.pid == pid ? $0.time : nil } ?? watchingSince
        return now - max(beat, watchingSince) > limit
    }

    public static func pickHost(_ pids: [Int32], heartbeat: Heartbeat?) -> Int32? {
        if let hb = heartbeat, pids.contains(hb.pid) { return hb.pid }
        return pids.max()
    }

    public func launchGap(at now: Double) -> Double {
        launches.filter { now - $0 < Self.crashLoopWindow }.count >= Self.crashLoopLaunches ? Self.crashLoopGap : Self.launchGap
    }

    public mutating func step(now: Double, host: Int32?, heartbeat: Heartbeat?, marker: ExitMarker?, uptime: Double = 0) -> WatchdogAction {
        let first = lastTick == nil
        if let last = lastTick, now - last > Self.wakeGap { since = now }
        lastTick = now
        if let pid = host {
            if pid != watched { watched = pid; since = now; pending = nil; hungPid = nil; optedOut = false }
            sessionEndedAt = nil
            if let hb = heartbeat, hb.pid == pid { optedOut = !hb.watched }
            if hungPid == pid || optedOut { return .none }
            if Self.isHung(heartbeat: heartbeat, pid: pid, watchingSince: since, now: now, limit: hangLimit) {
                hungPid = pid
                return .kill(pid)
            }
            return .none
        }
        if watched != nil {
            watched = nil
            if hungPid != nil { pending = .hang }
            else if optedOut { pending = nil }
            else if let marker { pending = marker.relaunch; if marker == .session { sessionEndedAt = now } }
            else { pending = .crash }
            hungPid = nil
            optedOut = false
        } else if first {
            pending = marker == .quit && uptime > Self.honourQuitAfterUptime ? nil : .login
        }
        if let ended = sessionEndedAt, now - ended >= Self.missingAfterQuitDelay {
            sessionEndedAt = nil
            pending = .missingAfterQuit
        }
        guard let reason = pending else { return .none }
        if let last = launches.last, now - last < launchGap(at: now) { return .none }
        launches = launches.filter { now - $0 < Self.crashLoopWindow } + [now]
        return .launch(reason)
    }
}

public enum LaunchAgent {
    public static let label = "io.github.muhammademanaftab.porthole.watchdog"
    public static let plistName = label + ".plist"
    public static let hostBundleID = "io.github.muhammademanaftab.porthole"
    public static let legacyLabel = "io.github.muhammademanaftab.porthole"
    public static let legacyLaunchedEnvKey = "PORTHOLE_LAUNCH_AGENT"

    public static func plist(executableName: String) -> [String: Any] {
        let program = "Contents/MacOS/\(executableName)"
        return [
            "Label": label,
            "BundleProgram": program,
            "ProgramArguments": [program, "watchdog"],
            "EnvironmentVariables": [HostCommand.envKey: "watchdog"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": [hostBundleID],
        ]
    }

    public static func plistData(executableName: String) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: plist(executableName: executableName), format: .xml, options: 0)
    }
}

public struct HostSettings: Equatable, Sendable {
    public static let keepRunningKey = "keepRunning"
    public static let verboseKey = "verboseLogging"
    public static let overrideEnvKey = "PORTHOLE_WATCHDOG"

    public var keepRunning: Bool
    public var verbose: Bool

    public static let defaults = HostSettings(keepRunning: true, verbose: false)

    public init(keepRunning: Bool, verbose: Bool) { self.keepRunning = keepRunning; self.verbose = verbose }

    public init(lookup: (String) -> Any?) {
        keepRunning = lookup(Self.keepRunningKey) as? Bool ?? Self.defaults.keepRunning
        verbose = lookup(Self.verboseKey) as? Bool ?? Self.defaults.verbose
    }

    public func keepRunningThisRun(environment: [String: String]) -> Bool {
        switch environment[Self.overrideEnvKey] {
        case "1": return true
        case "0": return false
        default: return keepRunning
        }
    }
}

public enum RestartDecision: Equatable, Sendable {
    case restart
    case refuse(String)
}

public func restartDecision(hasOpenWindow: Bool, agentEnabled: Bool) -> RestartDecision {
    guard hasOpenWindow else { return .refuse("Open a window from that Mac first: only a viewer with a window open can restart its host.") }
    guard agentEnabled else {
        return .refuse("Keep Porthole running is off on that Mac, so it can't restart itself. Turn it on in Porthole Settings › Sharing.")
    }
    return .restart
}

public struct ProcessArguments: Equatable, Sendable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String], environment: [String: String]) { self.arguments = arguments; self.environment = environment }

    public init(procargs bytes: [UInt8]) {
        self.init(arguments: [], environment: [:])
        let head = MemoryLayout<Int32>.size
        guard bytes.count > head else { return }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc > 0, argc < 4096 else { return }
        var i = head
        while i < bytes.count && bytes[i] != 0 { i += 1 }
        while i < bytes.count && bytes[i] == 0 { i += 1 }
        var strings: [String] = []
        while i < bytes.count {
            let start = i
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            if start == i && strings.count >= argc { break }
            strings.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        arguments = Array(strings.prefix(argc))
        for pair in strings.dropFirst(argc) {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            environment[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
    }

    public var isWatchdog: Bool {
        HostCommand.parse(arguments: Array(arguments.dropFirst()), environment: environment) == .watchdog
    }
}
