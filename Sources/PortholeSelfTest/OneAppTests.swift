import Foundation
import PortholeCore

func oneAppTests() {
    expect("hosting: a saved switch decides", HostingSwitch.saved(stored: true), true)
    expect("hosting: a new install doesn't share", HostingSwitch.saved(stored: nil), false)
    expect("hosting: a junk stored value counts as off", HostingSwitch.saved(stored: "yes"), false)
    expect("hosting: PORTHOLE_HOSTING=1 shares this run", HostingSwitch.thisRun(saved: false, environment: ["PORTHOLE_HOSTING": "1"]), true)
    expect("hosting: PORTHOLE_HOSTING=0 doesn't", HostingSwitch.thisRun(saved: true, environment: ["PORTHOLE_HOSTING": "0"]), false)
    expect("hosting: otherwise the saved switch decides", HostingSwitch.thisRun(saved: true, environment: ["PORTHOLE_HOSTING": "maybe"]), true)
    check("hosting: only 0 and 1 count as an override", HostingSwitch.overridden(["PORTHOLE_HOSTING": "0"]) && !HostingSwitch.overridden(["PORTHOLE_HOSTING": "yes"]) && !HostingSwitch.overridden([:]))
    check("env flags: PORTHOLE_HOSTING is documented", EnvFlags.all.contains { $0.name == HostingSwitch.envKey })

    expect("one app: bundle id", OneApp.bundleID, "io.github.muhammademanaftab.porthole")

    let own = "/Applications/Porthole.app"

    let stamp = "/Applications/Porthole.app 42 1700000000"
    expect("watchdog stamp: unchanged needs nothing", WatchdogStamp.registerAgain(saved: stamp, current: stamp, bundlePath: own), false)
    expect("watchdog stamp: an update in place registers again", WatchdogStamp.registerAgain(saved: "/Applications/Porthole.app 42 1600000000", current: stamp, bundlePath: own), true)
    expect("watchdog stamp: a development build elsewhere leaves it alone", WatchdogStamp.registerAgain(saved: "/Applications/Porthole.app 42 1600000000", current: "/tmp/dist/Porthole.app 9 1", bundlePath: "/tmp/dist/Porthole.app"), false)
    expect("watchdog stamp: no stamp in /Applications registers again", WatchdogStamp.registerAgain(saved: nil, current: stamp, bundlePath: own), true)
    expect("watchdog stamp: no stamp elsewhere doesn't", WatchdogStamp.registerAgain(saved: nil, current: "/tmp/x.app 1 1", bundlePath: "/tmp/x.app"), false)

    expect("command: no arguments run the app", AppCommand.route([], invokedAs: "porthole-host"), .host)
    expect("command: paircode is a host command", AppCommand.route(["paircode"], invokedAs: "porthole-host"), .host)
    expect("command: the watchdog is a host command", AppCommand.route(["watchdog"], invokedAs: "porthole-host"), .host)
    for word in ["request", "pair", "machines", "ls", "list", "open", "recent"] {
        expect("command: \(word) goes to the viewer", AppCommand.route([word, "x"], invokedAs: "porthole-host"), .viewer)
    }
    expect("command: anything run as porthole-view is a viewer command", AppCommand.route(["help"], invokedAs: "porthole-view"), .viewer)
    expect("command: help lists both", AppCommand.route(["--help"], invokedAs: "porthole-host"), .help)
    expect("command: a host to connect to runs the app", AppCommand.route(["mini.local", "pw"], invokedAs: "porthole-host"), .host)
    expect("command: gallery runs the app", AppCommand.route(["gallery", "menu"], invokedAs: "porthole-host"), .host)
    check("command: no viewer command name is also a host command", ["request", "pair", "machines", "ls", "list", "open", "recent"].allSatisfy { hostPairCommand([$0]) == .app })

    check("gallery: every viewer and host screen can be shown", (galleryScreens + hostGalleryScreens).allSatisfy { appGalleryScreens.contains($0) })
    check("gallery: no screen is listed twice", Set(appGalleryScreens).count == appGalleryScreens.count)
    expect("gallery: bare gallery shows the first viewer screen", galleryScreen(["gallery"], screens: appGalleryScreens), galleryScreens.first)
    expect("gallery: the host menu", galleryScreen(["gallery", "menu"], screens: appGalleryScreens), "menu")

    let me = DiscoveredHost(name: "This Mac", lanHost: "me.local", status: .online, viaBonjour: true, hostID: "aaaa-bbbb")
    let mini = DiscoveredHost(name: "Mac mini", lanHost: "mini.local", status: .online, viaBonjour: true, hostID: "cccc-dddd")
    let old = DiscoveredHost(name: "Old host", lanHost: "old.local", status: .online, viaBonjour: true)
    expect("discovery: a Mac sharing itself isn't offered to its own viewer", otherMacs([me, mini, old], thisMac: "aaaa-bbbb").map(\.name), ["Mac mini", "Old host"])
    let tsMe = DiscoveredHost(name: "This Mac", tailscaleIP: "100.64.0.1", status: .online, viaTailscale: true, hostID: "aaaa-bbbb")
    expect("discovery: a Tailscale scan doesn't offer this Mac either", otherMacs([tsMe, mini], thisMac: "aaaa-bbbb").map(\.name), ["Mac mini"])
    expect("discovery: without an identity nothing is dropped", otherMacs([me, mini], thisMac: nil).count, 2)

    check("doctor: Porthole.app is the one app", OneApp.isInstalledOneApp(URL(fileURLWithPath: "/Applications/Porthole.app/")))
    check("doctor: a program inside the app", OneApp.isInside("/Applications/Porthole.app/Contents/MacOS/porthole-host", app: "/Applications/Porthole.app"))
    check("doctor: a program in Porthole.app.old is not inside Porthole.app", !OneApp.isInside("/Applications/Porthole.app.old/Contents/MacOS/porthole-host", app: "/Applications/Porthole.app"))

    let printed = "gui/501/io.github.muhammademanaftab.porthole.watchdog = {\n\tactive count = 1\n\tpath = (submitted by smd.328)\n\tstate = running\n\tprogram identifier = Contents/MacOS/porthole-host (mode: 2)\n\truns = 3\n\tpid = 19322\n\tlast exit code = 0\n}\n"
    expect("launchctl print: the running agent's pid", LaunchctlPrint.pid(printed), 19322)
    expect("launchctl print: a stopped agent has no pid", LaunchctlPrint.pid("gui/501/x = {\n\tstate = not running\n\truns = 0\n}\n"), nil)

    expect("launch: Launch Services may share this Mac", LaunchOrigin.decide(bundled: true, parentIsLaunchd: true, watchdogLaunched: false, arguments: [], environment: [:]), .run(mayHost: true))
    expect("launch: the watchdog may share this Mac", LaunchOrigin.decide(bundled: true, parentIsLaunchd: false, watchdogLaunched: true, arguments: [], environment: [:]), .run(mayHost: true))
    expect("launch: the app run from a shell hands over", LaunchOrigin.decide(bundled: true, parentIsLaunchd: false, watchdogLaunched: false, arguments: [], environment: [:]), .handOff)
    expect("launch: a -psn style argument still hands over", LaunchOrigin.decide(bundled: true, parentIsLaunchd: false, watchdogLaunched: false, arguments: ["-psn_0_1"], environment: [:]), .handOff)
    expect("launch: a viewer run with a host from a shell only views", LaunchOrigin.decide(bundled: true, parentIsLaunchd: false, watchdogLaunched: false, arguments: ["mini.local", "pw"], environment: ["PORTHOLE_HOSTING": "1"]), .run(mayHost: false))
    expect("launch: a bare development binary only views", LaunchOrigin.decide(bundled: false, parentIsLaunchd: false, watchdogLaunched: false, arguments: [], environment: [:]), .run(mayHost: false))
    expect("launch: a bare development binary shares with PORTHOLE_HOSTING=1", LaunchOrigin.decide(bundled: false, parentIsLaunchd: false, watchdogLaunched: false, arguments: [], environment: ["PORTHOLE_HOSTING": "1"]), .run(mayHost: true))

    let app = "/Applications/Porthole.app/Contents/MacOS/porthole-host"
    check("hosts: the app launched by Launch Services is a host", ProcessArguments(arguments: [app], environment: [:]).isHostApp)
    check("hosts: the app launched by the watchdog is a host", ProcessArguments(arguments: [app], environment: ["PORTHOLE_COMMAND": "app"]).isHostApp)
    check("hosts: an old -psn argument still is", ProcessArguments(arguments: [app, "-psn_0_42"], environment: [:]).isHostApp)
    check("hosts: the watchdog is not", !ProcessArguments(arguments: ["Contents/MacOS/porthole-host", "watchdog"], environment: ["PORTHOLE_COMMAND": "watchdog"]).isHostApp)
    check("hosts: porthole-view is not", !ProcessArguments(arguments: ["/Applications/Porthole.app/Contents/MacOS/porthole-view"], environment: [:]).isHostApp)
    check("hosts: a CLI subcommand is not", !ProcessArguments(arguments: [app, "paircode"], environment: [:]).isHostApp)
    check("hosts: a viewer run with a host is not", !ProcessArguments(arguments: [app, "mini.local", "pw"], environment: [:]).isHostApp)
    check("hosts: unreadable arguments count as a host", ProcessArguments(arguments: [], environment: [:]).isHostApp)

    expect("quit: a user quit while sharing tells the watchdog not to relaunch", ExitMarker.onTerminate(sessionEnding: false), .quit)
    expect("quit: log out or power off marks the session end", ExitMarker.onTerminate(sessionEnding: true), .session)

    expect("dock: a viewer-only Mac always has its Dock icon", Presence.dockIcon(hosting: false, viewerWindows: 0), true)
    expect("dock: a Mac that only shares stays in the menu bar", Presence.dockIcon(hosting: true, viewerWindows: 0), false)
    expect("dock: it gets a Dock icon while a viewer window is open", Presence.dockIcon(hosting: true, viewerWindows: 1), true)
}
