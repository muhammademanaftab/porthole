import Foundation
import PortholeCore

func watchdogTests() {
    expect("no arguments runs the app", HostCommand.parse(arguments: [], environment: [:]), .app)
    expect("`watchdog` runs the watchdog", HostCommand.parse(arguments: ["watchdog"], environment: [:]), .watchdog)
    expect("the agent's environment alone runs the watchdog", HostCommand.parse(arguments: [], environment: ["PORTHOLE_COMMAND": "watchdog"]), .watchdog)
    expect("a Finder launch argument with the agent's environment still runs the watchdog",
           HostCommand.parse(arguments: ["-psn_0_1234"], environment: ["PORTHOLE_COMMAND": "watchdog"]), .watchdog)
    expect("PORTHOLE_COMMAND=app runs the app", HostCommand.parse(arguments: [], environment: ["PORTHOLE_COMMAND": "app"]), .app)
    expect("`agent-plist` prints the plist", HostCommand.parse(arguments: ["agent-plist"], environment: ["PORTHOLE_COMMAND": "watchdog"]), .agentPlist)
    expect("an unknown argument runs the app", HostCommand.parse(arguments: ["something"], environment: [:]), .app)

    expect("quit stays quit", ExitMarker.quit.relaunch, nil)
    expect("a logout or shutdown stays quit", ExitMarker.session.relaunch, nil)
    expect("a remote restart relaunches", ExitMarker.remote.relaunch, .remote)
    expect("a migration relaunches", ExitMarker.migrate.relaunch, .migrate)
    expect("marker text with a newline parses", ExitMarker(text: "remote\n"), .remote)
    expect("junk marker text is no marker", ExitMarker(text: "bogus"), nil)

    let hb = Heartbeat(pid: 4242, time: 1_700_000_000.25)
    expect("heartbeat round-trips", Heartbeat(text: hb.text), hb)
    expect("an empty heartbeat file is no heartbeat", Heartbeat(text: ""), nil)
    expect("a torn heartbeat write is no heartbeat", Heartbeat(text: "4242"), nil)
    expect("a zero pid is no heartbeat", Heartbeat(text: "0 12.5"), nil)

    let limit = 30.0
    check("a fresh heartbeat is not a hang",
          !WatchdogMonitor.isHung(heartbeat: Heartbeat(pid: 7, time: 100), pid: 7, watchingSince: 50, now: 110, limit: limit))
    check("a heartbeat older than the limit is a hang",
          WatchdogMonitor.isHung(heartbeat: Heartbeat(pid: 7, time: 100), pid: 7, watchingSince: 50, now: 131, limit: limit))
    check("exactly the limit is not yet a hang",
          !WatchdogMonitor.isHung(heartbeat: Heartbeat(pid: 7, time: 100), pid: 7, watchingSince: 50, now: 130, limit: limit))
    check("another process's heartbeat does not count; time since watching does",
          WatchdogMonitor.isHung(heartbeat: Heartbeat(pid: 6, time: 200), pid: 7, watchingSince: 100, now: 131, limit: limit))
    check("a just-started host with no heartbeat yet is not hung",
          !WatchdogMonitor.isHung(heartbeat: nil, pid: 7, watchingSince: 100, now: 120, limit: limit))
    check("an old heartbeat from before watching started is measured from watching",
          !WatchdogMonitor.isHung(heartbeat: Heartbeat(pid: 7, time: 10), pid: 7, watchingSince: 100, now: 120, limit: limit))

    expect("hang limit defaults to 30 s", WatchdogMonitor.hangLimit(from: nil), 30)
    expect("hang limit reads the environment", WatchdogMonitor.hangLimit(from: "90"), 90)
    expect("hang limit never drops below 15 s", WatchdogMonitor.hangLimit(from: "3"), 15)
    expect("a junk hang limit falls back to the default", WatchdogMonitor.hangLimit(from: "soon"), 30)
    expect("the monitor clamps its hang limit too", WatchdogMonitor(hangLimit: 1).hangLimit, 15)

    expect("the host with the heartbeat is the one watched", WatchdogMonitor.pickHost([10, 20], heartbeat: Heartbeat(pid: 10, time: 0)), 10)
    expect("without a matching heartbeat the newest pid is watched", WatchdogMonitor.pickHost([10, 20], heartbeat: Heartbeat(pid: 5, time: 0)), 20)
    expect("no host processes means nothing to watch", WatchdogMonitor.pickHost([], heartbeat: nil), nil)

    var m = WatchdogMonitor()
    expect("at login with no host the watchdog launches it", m.step(now: 0, host: nil, heartbeat: nil, marker: nil), .launch(.login))
    expect("it waits for the launched host instead of launching again", m.step(now: 2, host: nil, heartbeat: nil, marker: nil), .none)
    expect("it retries a launch that never showed up", m.step(now: 10, host: nil, heartbeat: nil, marker: nil), .launch(.login))
    expect("a running host is watched", m.step(now: 12, host: 100, heartbeat: nil, marker: nil), .none)
    expect("the watched pid is remembered", m.watched, 100)
    expect("a beating host is left alone", m.step(now: 24, host: 100, heartbeat: Heartbeat(pid: 100, time: 22), marker: nil), .none)
    expect("a host gone without a marker crashed", m.step(now: 26, host: nil, heartbeat: Heartbeat(pid: 100, time: 22), marker: nil), .launch(.crash))
    expect("the relaunched host is watched", m.step(now: 28, host: 101, heartbeat: nil, marker: nil), .none)
    expect("one heartbeat in", m.step(now: 40, host: 101, heartbeat: Heartbeat(pid: 101, time: 29), marker: nil), .none)
    expect("23 s of silence is tolerated", m.step(now: 52, host: 101, heartbeat: Heartbeat(pid: 101, time: 29), marker: nil), .none)
    expect("a host silent past the limit is killed", m.step(now: 62, host: 101, heartbeat: Heartbeat(pid: 101, time: 29), marker: nil), .kill(101))
    expect("it is not killed twice while it dies", m.step(now: 64, host: 101, heartbeat: Heartbeat(pid: 101, time: 29), marker: nil), .none)
    expect("the killed host is relaunched as a hang, not a crash", m.step(now: 66, host: nil, heartbeat: nil, marker: nil), .launch(.hang))
    expect("the next host is watched afresh", m.step(now: 68, host: 102, heartbeat: Heartbeat(pid: 101, time: 29), marker: nil), .none)
    expect("its predecessor's stale heartbeat does not make it hung", m.step(now: 80, host: 102, heartbeat: Heartbeat(pid: 101, time: 29), marker: nil), .none)
    expect("a remote restart is relaunched as remote", m.step(now: 94, host: nil, heartbeat: nil, marker: .remote), .launch(.remote))
    _ = m.step(now: 96, host: 103, heartbeat: nil, marker: nil)
    expect("Quit from the menu stays quit", m.step(now: 98, host: nil, heartbeat: nil, marker: .quit), .none)
    expect("it stays quit later on", m.step(now: 110, host: nil, heartbeat: nil, marker: .quit), .none)
    expect("nothing is pending after a quit", m.pending, nil)
    expect("opening it again by hand is watched again", m.step(now: 112, host: 104, heartbeat: nil, marker: nil), .none)
    expect("the reopened host is watched", m.watched, 104)
    expect("a logout or shutdown is not relaunched", m.step(now: 114, host: nil, heartbeat: nil, marker: .session), .none)

    var w = WatchdogMonitor()
    _ = w.step(now: 0, host: 9, heartbeat: Heartbeat(pid: 9, time: 0), marker: nil)
    expect("after sleep the stale heartbeat is not a hang", w.step(now: 3600, host: 9, heartbeat: Heartbeat(pid: 9, time: 0), marker: nil), .none)
    let afterWake = [3610.0, 3620, 3630, 3640].map { w.step(now: $0, host: 9, heartbeat: Heartbeat(pid: 9, time: 0), marker: nil) }
    expect("but a host that stays silent for the limit after waking is killed", afterWake, [.none, .none, .none, .kill(9)])

    var started = WatchdogMonitor()
    expect("a watchdog started beside a running host just watches it", started.step(now: 0, host: 5, heartbeat: nil, marker: nil), .none)
    var quitBefore = WatchdogMonitor()
    expect("at login a quit marker from the last session does not keep it stopped",
           quitBefore.step(now: 0, host: nil, heartbeat: nil, marker: .quit), .launch(.login))

    var loop = WatchdogMonitor()
    var t = 0.0
    var relaunches = 0
    for pid in Int32(1)...6 {
        _ = loop.step(now: t, host: pid, heartbeat: nil, marker: nil)
        t += 2
        if case .launch(.crash) = loop.step(now: t, host: nil, heartbeat: nil, marker: nil) { relaunches += 1 }
        t += 10
    }
    expect("a crash loop is relaunched five times in a row", relaunches, 5)
    expect("then the watchdog backs off to two minutes", loop.launchGap(at: t), 120)
    expect("it still means to relaunch", loop.pending, .crash)

    let p = LaunchAgent.plist(executableName: "porthole-host")
    expect("agent label", p["Label"] as? String, "io.github.muhammademanaftab.porthole.watchdog")
    expect("agent plist name matches its label", LaunchAgent.plistName, "io.github.muhammademanaftab.porthole.watchdog.plist")
    expect("agent runs the host binary inside the bundle", p["BundleProgram"] as? String, "Contents/MacOS/porthole-host")
    expect("agent passes `watchdog`", p["ProgramArguments"] as? [String], ["Contents/MacOS/porthole-host", "watchdog"])
    expect("agent also sets PORTHOLE_COMMAND=watchdog", (p["EnvironmentVariables"] as? [String: String])?["PORTHOLE_COMMAND"], "watchdog")
    expect("the agent's own arguments parse as the watchdog",
           HostCommand.parse(arguments: Array(((p["ProgramArguments"] as? [String]) ?? []).dropFirst()), environment: [:]), .watchdog)
    expect("agent starts at login", p["RunAtLoad"] as? Bool, true)
    expect("launchd restarts the watchdog only if it fails", (p["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
    expect("agent only runs in a GUI login session", p["LimitLoadToSessionType"] as? String, "Aqua")
    expect("agent is associated with the host app", p["AssociatedBundleIdentifiers"] as? [String], ["io.github.muhammademanaftab.porthole"])
    check("the agent never runs the app's environment flag", (p["EnvironmentVariables"] as? [String: String])?[LaunchAgent.legacyLaunchedEnvKey] == nil)
    let data = LaunchAgent.plistData(executableName: "porthole-host")
    let back = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    expect("agent plist serialises and reads back", back?["Label"] as? String, LaunchAgent.label)
    expect("the new agent is not the old one", LaunchAgent.label == LaunchAgent.legacyLabel, false)

    expect("keep running defaults to on", HostSettings(lookup: { _ in nil }).keepRunning, true)
    expect("verbose logging defaults to off", HostSettings(lookup: { _ in nil }).verbose, false)
    let off = HostSettings(lookup: { ["keepRunning": false, "verboseLogging": true][$0] })
    expect("a remembered off switch stays off", off.keepRunning, false)
    expect("a remembered verbose switch stays on", off.verbose, true)
    expect("a junk stored value falls back to the default", HostSettings(lookup: { _ in "yes" }).keepRunning, true)
    expect("PORTHOLE_WATCHDOG=0 turns it off for this run", HostSettings.defaults.keepRunningThisRun(environment: ["PORTHOLE_WATCHDOG": "0"]), false)
    expect("PORTHOLE_WATCHDOG=1 turns it on for this run", off.keepRunningThisRun(environment: ["PORTHOLE_WATCHDOG": "1"]), true)
    expect("without the variable the switch decides", off.keepRunningThisRun(environment: [:]), false)

    expect("a viewer may restart a host that is kept running", restartDecision(from: "viewer-mbp", agentEnabled: true), .restart)
    check("a host without the watchdog refuses", { if case .refuse = restartDecision(from: "viewer-mbp", agentEnabled: false) { return true }; return false }())
    check("the host itself can't ask", { if case .refuse = restartDecision(from: "host", agentEnabled: true) { return true }; return false }())
    check("an anonymous sender can't ask", { if case .refuse = restartDecision(from: "", agentEnabled: true) { return true }; return false }())
    let restart = Message(.restart)
    expect("restart message round-trips", Message.decode(restart.encoded())?.t, .restart)
    expect("restart is sent as t=restart", json(restart.encoded())?["t"] as? String, "restart")

    var raw: [UInt8] = [2, 0, 0, 0]
    raw += Array("/Applications/Porthole Host.app/Contents/MacOS/porthole-host".utf8) + [0, 0, 0]
    raw += Array("Contents/MacOS/porthole-host".utf8) + [0] + Array("watchdog".utf8) + [0]
    raw += Array("PORTHOLE_COMMAND=watchdog".utf8) + [0]
    expect("process arguments are read from KERN_PROCARGS2", parseProcessArguments(raw), ["Contents/MacOS/porthole-host", "watchdog"])
    expect("the environment after argv is not an argument", parseProcessArguments(raw).count, 2)
    expect("a truncated buffer gives what it has", parseProcessArguments(Array(raw.prefix(raw.count - 36))), ["Contents/MacOS/porthole-host"])
    expect("an empty buffer gives no arguments", parseProcessArguments([]), [])
}
