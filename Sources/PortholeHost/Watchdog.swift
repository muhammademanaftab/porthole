import AppKit
import Darwin
import PortholeCore
import ServiceManagement

enum HostFiles {
    static var heartbeatURL: URL { HostConfig.directory.appendingPathComponent("heartbeat") }
    static var markerURL: URL { HostConfig.directory.appendingPathComponent("exit-marker") }

    nonisolated(unsafe) static var watched = true

    static func writeHeartbeat() {
        let beat = Heartbeat(pid: getpid(), time: Date().timeIntervalSince1970, watched: watched)
        try? FileManager.default.createDirectory(at: HostConfig.directory, withIntermediateDirectories: true)
        try? beat.text.write(to: heartbeatURL, atomically: true, encoding: .utf8)
    }

    static func readHeartbeat() -> Heartbeat? {
        (try? String(contentsOf: heartbeatURL, encoding: .utf8)).flatMap { Heartbeat(text: $0) }
    }

    static func readMarker() -> ExitMarker? {
        (try? String(contentsOf: markerURL, encoding: .utf8)).flatMap { ExitMarker(text: $0) }
    }

    static func writeMarker(_ m: ExitMarker, unlessPresent: Bool = false) {
        if unlessPresent && FileManager.default.fileExists(atPath: markerURL.path) { return }
        try? FileManager.default.createDirectory(at: HostConfig.directory, withIntermediateDirectories: true)
        try? m.rawValue.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    static func clearMarker() { try? FileManager.default.removeItem(at: markerURL) }

    static var watchdogPidURL: URL { HostConfig.directory.appendingPathComponent("watchdog.pid") }

    static func writeWatchdogPid() {
        try? FileManager.default.createDirectory(at: HostConfig.directory, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: watchdogPidURL, atomically: true, encoding: .utf8)
    }

    static func readWatchdogPid() -> pid_t? {
        (try? String(contentsOf: watchdogPidURL, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

@MainActor
final class Heartbeats {
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    func start(watched: Bool) {
        HostFiles.watched = watched
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Porthole Host answers its watchdog")
        HostFiles.writeHeartbeat()
        let t = Timer(timeInterval: WatchdogMonitor.heartbeatEvery, repeats: true) { _ in HostFiles.writeHeartbeat() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

@MainActor
enum KeepRunning {
    static var service: SMAppService { SMAppService.agent(plistName: LaunchAgent.plistName) }
    static var status: SMAppService.Status { service.status }
    static var isEnabled: Bool { status == .enabled }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    static var stampURL: URL { HostConfig.directory.appendingPathComponent("watchdog-bundle") }

    static var bundleStamp: String? {
        guard let exe = Bundle.main.executableURL,
              let bundle = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath),
              let binary = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let inode = bundle[.systemFileNumber] as? NSNumber, let date = binary[.modificationDate] as? Date else { return nil }
        return "\(Bundle.main.bundlePath) \(inode) \(Int(date.timeIntervalSince1970))"
    }

    static func rememberBundle() {
        guard let stamp = bundleStamp else { return }
        try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
    }

    static var bundleChanged: Bool {
        guard let stamp = bundleStamp else { return false }
        guard let saved = try? String(contentsOf: stampURL, encoding: .utf8) else {
            return Bundle.main.bundlePath.hasPrefix("/Applications/")
        }
        return saved != stamp && saved.hasPrefix(Bundle.main.bundlePath + " ")
    }

    static var watchdogRunning: Bool {
        guard let exe = Bundle.main.executableURL?.path else { return false }
        return Processes.running(executable: exe).contains { Processes.isWatchdog($0) }
    }

    static func registerAgain(attempt: Int = 1) {
        let wait = attempt == 1 ? 8 : attempt * 10
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(wait)) {
            MainActor.assumeIsolated {
                try? service.unregister()
                do {
                    try service.register()
                } catch {
                    Log.error("keep running: registering the watchdog agent again failed (attempt \(attempt)): \(error.localizedDescription)", .watchdog)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) {
                    MainActor.assumeIsolated {
                        if watchdogRunning {
                            rememberBundle()
                            Log.info("keep running: watchdog agent registered again and running, status \(describe(status))", .watchdog)
                        } else if attempt < 4 {
                            Log.info("keep running: the watchdog did not start after registering (attempt \(attempt)); trying again", .watchdog)
                            registerAgain(attempt: attempt + 1)
                        } else {
                            Log.error("keep running: the watchdog did not start after \(attempt) registrations; turn Keep Porthole Host running off and on in Settings", .watchdog)
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    static func apply(_ on: Bool) -> String? {
        let before = status
        do {
            if on {
                if before == .enabled, bundleChanged {
                    Log.info("keep running: Porthole Host was updated or replaced since the watchdog agent was registered; registering it again", .watchdog)
                    registerAgain()
                    return nil
                }
                guard before != .enabled && before != .requiresApproval else { return nil }
                try service.register()
                rememberBundle()
            } else {
                guard before == .enabled || before == .requiresApproval else { return nil }
                try service.unregister()
            }
        } catch {
            Log.info("keep running: \(on ? "register" : "unregister") failed (\(describe(before))): \(error.localizedDescription)", .watchdog)
            return error.localizedDescription
        }
        Log.info("keep running: watchdog agent \(on ? "registered" : "unregistered"), status \(describe(status))", .watchdog)
        return nil
    }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

enum LegacyAgent {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(LaunchAgent.legacyLabel).plist")
    }
    static var leftovers: [URL] {
        [HostConfig.directory.appendingPathComponent("login-agent.plist.disabled"),
         HostConfig.directory.appendingPathComponent("login-agent-offered")]
    }

    static var launchedUs: Bool { ProcessInfo.processInfo.environment[LaunchAgent.legacyLaunchedEnvKey] == "1" }
    static var target: String { "gui/\(getuid())/\(LaunchAgent.legacyLabel)" }
    static var isLoaded: Bool { launchctl(["print", target]) == 0 }

    static func removeFiles() {
        for url in [plistURL] + leftovers where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            Log.info("removed old login agent file \(url.path)", .watchdog)
        }
    }

    static func bootOut() {
        guard isLoaded else { return }
        Log.info("booting out the old login agent \(LaunchAgent.legacyLabel)", .watchdog)
        launchctl(["bootout", target])
    }

    static func bootOutSelf() {
        Log.info("handing over from the old login agent to the watchdog; booting it out", .watchdog)
        Log.flush()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", target]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Log.info("the old login agent was not booted out; exiting so the watchdog starts a fresh host", .watchdog)
            Log.flush()
            exit(0)
        }
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}

enum WatchdogRunner {
    static func run() -> Never {
        Log.becomeWatchdog()
        DispatchQueue.global(qos: .userInitiated).async { watch() }
        dispatchMain()
    }

    static func watch() {
        guard let exe = Bundle.main.executableURL?.path else { Log.info("watchdog: no executable path", .watchdog); exit(1) }
        let app = Bundle.main.bundleURL
        let limit = WatchdogMonitor.hangLimit(from: ProcessInfo.processInfo.environment[WatchdogMonitor.hangEnvKey])
        var monitor = WatchdogMonitor(hangLimit: limit)
        HostFiles.writeWatchdogPid()
        Log.info("watchdog started (pid \(getpid()), app \(app.path), hang limit \(Int(limit)) s)", .watchdog)
        while true {
            let beat = HostFiles.readHeartbeat()
            let host = WatchdogMonitor.pickHost(Processes.hosts(executable: exe), heartbeat: beat)
            switch monitor.step(now: Date().timeIntervalSince1970, host: host, heartbeat: beat, marker: HostFiles.readMarker(),
                                uptime: ProcessInfo.processInfo.systemUptime) {
            case .none:
                break
            case .kill(let pid):
                let silent = beat.map { Int(Date().timeIntervalSince1970 - $0.time) }.map { "\($0) s" } ?? "since launch"
                Log.error("watchdog: host \(pid) has not answered for \(silent); sampling it, then killing it", .watchdog)
                sample(pid)
                kill(pid, SIGKILL)
            case .launch(let reason):
                Log.info(reason == .login ? "watchdog launch reason=login" : "watchdog relaunch reason=\(reason.rawValue)", .watchdog)
                launch(app, reason: reason)
            }
            Thread.sleep(forTimeInterval: WatchdogMonitor.tick)
        }
    }

    static func sample(_ pid: pid_t) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let out = Log.url.deletingLastPathComponent().appendingPathComponent("hang-\(stamp).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(pid), String(WatchdogMonitor.sampleSeconds), "-file", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.info("watchdog: could not run sample: \(error.localizedDescription)", .watchdog); return }
        let deadline = Date().addingTimeInterval(Double(WatchdogMonitor.sampleSeconds) + 12)
        while p.isRunning && Date() < deadline { usleep(200_000) }
        if p.isRunning { p.terminate() }
        if FileManager.default.fileExists(atPath: out.path) { Log.info("watchdog: hang sample written to \(out.path)", .watchdog) }
        else { Log.info("watchdog: sample of \(pid) failed (status \(p.isRunning ? -1 : p.terminationStatus)); no hang sample", .watchdog) }
    }

    static func launch(_ app: URL, reason: WatchdogReason) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.environment = [WatchdogReason.envKey: reason.rawValue, HostCommand.envKey: "app"]
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { running, error in
            if let error { Log.info("watchdog: launching \(app.lastPathComponent) failed: \(error.localizedDescription)", .watchdog) }
            else { Log.info("watchdog: launched host pid \(running?.processIdentifier ?? 0)", .watchdog) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 15)
    }
}
