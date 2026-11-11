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
    expect("a logout or shutdown is not relaunched at once", ExitMarker.session.relaunch, nil)
    expect("a remote restart relaunches", ExitMarker.remote.relaunch, .remote)
    expect("a migration relaunches", ExitMarker.migrate.relaunch, .migrate)
    expect("marker text with a newline parses", ExitMarker(text: "remote\n"), .remote)
    expect("junk marker text is no marker", ExitMarker(text: "bogus"), nil)

    let hb = Heartbeat(pid: 4242, time: 1_700_000_000.25)
    expect("heartbeat round-trips", Heartbeat(text: hb.text), hb)
    expect("an empty heartbeat file is no heartbeat", Heartbeat(text: ""), nil)
    expect("a torn heartbeat write is no heartbeat", Heartbeat(text: "4242"), nil)
    expect("a zero pid is no heartbeat", Heartbeat(text: "0 12.5"), nil)
    let quiet = Heartbeat(pid: 4242, time: 5, watched: false)
    expect("an unwatched heartbeat round-trips", Heartbeat(text: quiet.text), quiet)
    expect("an unwatched heartbeat says so", quiet.text, "4242 5.000 unwatched\n")
    expect("a plain heartbeat is watched", Heartbeat(text: "4242 5")?.watched, true)
    expect("a junk third word is no heartbeat", Heartbeat(text: "4242 5 maybe"), nil)

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

    expect("hang limit defaults to 60 s", WatchdogMonitor.hangLimit(from: nil), 60)
    expect("the monitor's default hang limit is 60 s", WatchdogMonitor().hangLimit, 60)
    expect("hang limit reads the environment", WatchdogMonitor.hangLimit(from: "90"), 90)
    expect("hang limit never drops below 15 s", WatchdogMonitor.hangLimit(from: "3"), 15)
    expect("a junk hang limit falls back to the default", WatchdogMonitor.hangLimit(from: "soon"), 60)
    expect("the monitor clamps its hang limit too", WatchdogMonitor(hangLimit: 1).hangLimit, 15)

    expect("the host with the heartbeat is the one watched", WatchdogMonitor.pickHost([10, 20], heartbeat: Heartbeat(pid: 10, time: 0)), 10)
    expect("without a matching heartbeat the newest pid is watched", WatchdogMonitor.pickHost([10, 20], heartbeat: Heartbeat(pid: 5, time: 0)), 20)
    expect("no host processes means nothing to watch", WatchdogMonitor.pickHost([], heartbeat: nil), nil)

    var m = WatchdogMonitor(hangLimit: 30)
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
    expect("a logout or shutdown is not relaunched at once", m.step(now: 114, host: nil, heartbeat: nil, marker: .session), .none)
    var ended = WatchdogMonitor(hangLimit: 30)
    _ = ended.step(now: 100, host: 50, heartbeat: nil, marker: nil)
    expect("an outside quit or cancelled logout is not relaunched at once", ended.step(now: 114, host: nil, heartbeat: nil, marker: .session), .none)
    let waiting = [124.0, 136, 148, 160].map { ended.step(now: $0, host: nil, heartbeat: nil, marker: .session) }
    expect("a host still missing 45 s after a logout that never happened is relaunched", waiting, [.none, .none, .none, .launch(.missingAfterQuit)])
    _ = ended.step(now: 162, host: 105, heartbeat: nil, marker: nil)
    expect("an external quit is not relaunched at once", ended.step(now: 164, host: nil, heartbeat: nil, marker: .session), .none)
    expect("the host coming back by itself cancels the wait", ended.step(now: 174, host: 106, heartbeat: nil, marker: nil), .none)
    expect("and nothing is launched later", [182.0, 194, 206, 218].map { ended.step(now: $0, host: 106, heartbeat: Heartbeat(pid: 106, time: $0), marker: nil) }, [.none, .none, .none, .none])
    expect("Quit from the menu never turns into missingAfterQuit",
           [220.0, 232, 244, 256, 268, 280].map { ended.step(now: $0, host: nil, heartbeat: nil, marker: .quit) }, [.none, .none, .none, .none, .none, .none])

    var optOut = WatchdogMonitor(hangLimit: 30)
    _ = optOut.step(now: 0, host: 7, heartbeat: Heartbeat(pid: 7, time: 0, watched: false), marker: nil)
    expect("a host run with PORTHOLE_WATCHDOG=0 is never killed for a hang",
           [12.0, 24, 36, 48].map { optOut.step(now: $0, host: 7, heartbeat: Heartbeat(pid: 7, time: 0, watched: false), marker: nil) }, [.none, .none, .none, .none])
    expect("nor relaunched when it goes", optOut.step(now: 50, host: nil, heartbeat: Heartbeat(pid: 7, time: 0, watched: false), marker: nil), .none)
    expect("the next normal host is watched again", optOut.step(now: 52, host: 8, heartbeat: Heartbeat(pid: 8, time: 52), marker: nil), .none)
    expect("and relaunched after a crash", optOut.step(now: 54, host: nil, heartbeat: Heartbeat(pid: 8, time: 52), marker: nil), .launch(.crash))
    var optedOutPredecessor = WatchdogMonitor(hangLimit: 30)
    _ = optedOutPredecessor.step(now: 0, host: 7, heartbeat: Heartbeat(pid: 6, time: 0, watched: false), marker: nil)
    expect("another process's unwatched heartbeat does not opt this host out", optedOutPredecessor.step(now: 2, host: nil, heartbeat: nil, marker: nil), .launch(.crash))

    var w = WatchdogMonitor(hangLimit: 30)
    _ = w.step(now: 0, host: 9, heartbeat: Heartbeat(pid: 9, time: 0), marker: nil)
    expect("after sleep the stale heartbeat is not a hang", w.step(now: 3600, host: 9, heartbeat: Heartbeat(pid: 9, time: 0), marker: nil), .none)
    let afterWake = [3610.0, 3620, 3630, 3640].map { w.step(now: $0, host: 9, heartbeat: Heartbeat(pid: 9, time: 0), marker: nil) }
    expect("but a host that stays silent for the limit after waking is killed", afterWake, [.none, .none, .none, .kill(9)])

    var started = WatchdogMonitor()
    expect("a watchdog started beside a running host just watches it", started.step(now: 0, host: 5, heartbeat: nil, marker: nil), .none)
    var quitBefore = WatchdogMonitor()
    expect("at login after a restart a quit marker does not keep it stopped",
           quitBefore.step(now: 0, host: nil, heartbeat: nil, marker: .quit, uptime: 60), .launch(.login))
    var watchdogRestarted = WatchdogMonitor()
    expect("a watchdog restarted long after boot honours a deliberate Quit",
           watchdogRestarted.step(now: 0, host: nil, heartbeat: nil, marker: .quit, uptime: 3600), .none)
    expect("and keeps honouring it", watchdogRestarted.step(now: 2, host: nil, heartbeat: nil, marker: .quit, uptime: 3602), .none)
    var afterLogout = WatchdogMonitor()
    expect("a watchdog started long after boot with a logout marker launches the host",
           afterLogout.step(now: 0, host: nil, heartbeat: nil, marker: .session, uptime: 3600), .launch(.login))

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
    let data = LaunchAgent.plistData(executableName: "porthole-host")
    let back = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    expect("agent plist serialises and reads back", back?["Label"] as? String, LaunchAgent.label)

    expect("keep running defaults to on", HostSettings(lookup: { _ in nil }).keepRunning, true)
    expect("verbose logging defaults to off", HostSettings(lookup: { _ in nil }).verbose, false)
    let off = HostSettings(lookup: { ["keepRunning": false, "verboseLogging": true][$0] })
    expect("a remembered off switch stays off", off.keepRunning, false)
    expect("a remembered verbose switch stays on", off.verbose, true)
    expect("a junk stored value falls back to the default", HostSettings(lookup: { _ in "yes" }).keepRunning, true)
    expect("PORTHOLE_WATCHDOG=0 turns it off for this run", HostSettings.defaults.keepRunningThisRun(environment: ["PORTHOLE_WATCHDOG": "0"]), false)
    expect("PORTHOLE_WATCHDOG=1 turns it on for this run", off.keepRunningThisRun(environment: ["PORTHOLE_WATCHDOG": "1"]), true)
    expect("without the variable the switch decides", off.keepRunningThisRun(environment: [:]), false)

    expect("a viewer with a window open may restart a host that is kept running", restartDecision(hasOpenWindow: true, agentEnabled: true), .restart)
    check("a host without the watchdog refuses", { if case .refuse = restartDecision(hasOpenWindow: true, agentEnabled: false) { return true }; return false }())
    check("a viewer with no window open can't restart it", { if case .refuse = restartDecision(hasOpenWindow: false, agentEnabled: true) { return true }; return false }())
    let restart = Message(.restart)
    expect("restart message round-trips", Message.decode(restart.encoded())?.t, .restart)
    expect("restart is sent as t=restart", json(restart.encoded())?["t"] as? String, "restart")

    var raw: [UInt8] = [2, 0, 0, 0]
    raw += Array("/Applications/Porthole.app/Contents/MacOS/porthole-host".utf8) + [0, 0, 0]
    raw += Array("Contents/MacOS/porthole-host".utf8) + [0] + Array("watchdog".utf8) + [0]
    raw += Array("PORTHOLE_COMMAND=watchdog".utf8) + [0]
    let parsed = ProcessArguments(procargs: raw)
    expect("process arguments are read from KERN_PROCARGS2", parsed.arguments, ["Contents/MacOS/porthole-host", "watchdog"])
    expect("the environment after argv is read too", parsed.environment, ["PORTHOLE_COMMAND": "watchdog"])
    check("the agent process is recognised as the watchdog", parsed.isWatchdog)
    var bare: [UInt8] = [1, 0, 0, 0]
    bare += Array("/x/porthole-host".utf8) + [0, 0]
    bare += Array("Contents/MacOS/porthole-host".utf8) + [0]
    bare += Array("PORTHOLE_COMMAND=watchdog".utf8) + [0] + Array("HOME=/Users/e".utf8) + [0, 0, 0]
    bare += Array("executable_path=/x/porthole-host".utf8) + [0]
    let bareArgs = ProcessArguments(procargs: bare)
    check("a job whose argv lacks `watchdog` is still the watchdog by its environment", bareArgs.isWatchdog)
    expect("apple strings after the padding are not environment", bareArgs.environment["executable_path"], nil)
    expect("other environment variables are read", bareArgs.environment["HOME"], "/Users/e")
    var app: [UInt8] = [1, 0, 0, 0]
    app += Array("/x/porthole-host".utf8) + [0, 0] + Array("/x/porthole-host".utf8) + [0]
    app += Array("PORTHOLE_COMMAND=app".utf8) + [0]
    check("a host launched by the watchdog is not the watchdog", !ProcessArguments(procargs: app).isWatchdog)
    expect("a truncated buffer gives what it has", ProcessArguments(procargs: Array(raw.prefix(raw.count - 36))).arguments, ["Contents/MacOS/porthole-host"])
    expect("an empty buffer gives no arguments", ProcessArguments(procargs: []), ProcessArguments(arguments: [], environment: [:]))
}
