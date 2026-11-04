import Foundation
import PortholeCore

func oneAppTests() {
    expect("hosting: an upgrade from Porthole Host shares by default", HostingSwitch.firstRunDefault(hasHostConfig: true, oldHostInstalled: true, watchdogStamp: false), true)
    expect("hosting: a host whose watchdog was registered shares by default", HostingSwitch.firstRunDefault(hasHostConfig: true, oldHostInstalled: false, watchdogStamp: true), true)
    expect("hosting: a leftover config.json from a development run alone doesn't share", HostingSwitch.firstRunDefault(hasHostConfig: true, oldHostInstalled: false, watchdogStamp: false), false)
    expect("hosting: a fresh install doesn't share", HostingSwitch.firstRunDefault(hasHostConfig: false, oldHostInstalled: true, watchdogStamp: true), false)
    var asked = 0
    let saved = HostingSwitch.saved(stored: false) { asked += 1; return true }
    check("hosting: a saved switch wins and the first-run rule isn't asked", saved == (false, false) && asked == 0)
    let first = HostingSwitch.saved(stored: nil) { true }
    check("hosting: with nothing saved the first-run rule decides and is saved", first == (true, true))
    check("hosting: a junk stored value counts as nothing saved", HostingSwitch.saved(stored: "yes") { false } == (false, true))
    expect("hosting: PORTHOLE_HOSTING=1 shares this run", HostingSwitch.thisRun(saved: false, environment: ["PORTHOLE_HOSTING": "1"]), true)
    expect("hosting: PORTHOLE_HOSTING=0 doesn't", HostingSwitch.thisRun(saved: true, environment: ["PORTHOLE_HOSTING": "0"]), false)
    expect("hosting: otherwise the saved switch decides", HostingSwitch.thisRun(saved: true, environment: ["PORTHOLE_HOSTING": "maybe"]), true)
    check("hosting: only 0 and 1 count as an override", HostingSwitch.overridden(["PORTHOLE_HOSTING": "0"]) && !HostingSwitch.overridden(["PORTHOLE_HOSTING": "yes"]) && !HostingSwitch.overridden([:]))
    check("env flags: PORTHOLE_HOSTING is documented", EnvFlags.all.contains { $0.name == HostingSwitch.envKey })

    expect("one app: keeps the host's bundle id", OneApp.bundleID, "io.github.muhammademanaftab.porthole")
    let copies = OneApp.viewerDefaultsToCopy(old: ["host": "mini", "stream.fps": 60, "general.playSound": false, "other": 1],
                                             current: { ["stream.fps": 30][$0] })
    expect("migration: copies the viewer's settings it doesn't have yet", Set(copies.keys), ["host", "general.playSound"])
    expect("migration: never overwrites a setting already there", copies["stream.fps"] == nil, true)
    expect("migration: copies the values", copies["host"] as? String, "mini")
    check("migration: every viewer setting key is copied", ViewerSettings().stored.keys.allSatisfy { OneApp.viewerKeys.contains($0) })

    let own = "/Applications/Porthole.app"
    check("migration: the old viewer is an old app", OneApp.isOldApp(bundleID: "io.github.muhammademanaftab.porthole.view", bundlePath: "/Applications/Porthole.app", ownBundlePath: "/x/Porthole.app"))
    check("migration: the old Porthole Host is an old app", OneApp.isOldApp(bundleID: OneApp.bundleID, bundlePath: "/Applications/Porthole Host.app", ownBundlePath: own))
    check("migration: this app is not", !OneApp.isOldApp(bundleID: OneApp.bundleID, bundlePath: own + "/", ownBundlePath: own))
    check("migration: another copy of this app is not quit", !OneApp.isOldApp(bundleID: OneApp.bundleID, bundlePath: "/tmp/dist/Porthole.app", ownBundlePath: own))
    check("migration: unrelated apps are not", !OneApp.isOldApp(bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app", ownBundlePath: own))
    check("migration: an app without a bundle is not", !OneApp.isOldApp(bundleID: nil, bundlePath: "/x", ownBundlePath: own))
    check("migration: the old host apps are looked for in both Applications folders", OneApp.oldHostApps(home: URL(fileURLWithPath: "/Users/e")).map(\.path) == ["/Applications/Porthole Host.app", "/Users/e/Applications/Porthole Host.app"])

    let stamp = "/Applications/Porthole.app 42 1700000000"
    expect("watchdog stamp: unchanged needs nothing", WatchdogStamp.registerAgain(saved: stamp, current: stamp, bundlePath: own), false)
    expect("watchdog stamp: an update in place registers again", WatchdogStamp.registerAgain(saved: "/Applications/Porthole.app 42 1600000000", current: stamp, bundlePath: own), true)
    expect("watchdog stamp: moving over from Porthole Host.app registers again", WatchdogStamp.registerAgain(saved: "/Applications/Porthole Host.app 7 1600000000", current: stamp, bundlePath: own), true)
    expect("watchdog stamp: a development build elsewhere leaves it alone", WatchdogStamp.registerAgain(saved: "/Applications/Porthole.app 42 1600000000", current: "/tmp/dist/Porthole.app 9 1", bundlePath: "/tmp/dist/Porthole.app"), false)
    expect("watchdog stamp: a development build doesn't take over from Porthole Host.app", WatchdogStamp.registerAgain(saved: "/Applications/Porthole Host.app 7 1", current: "/tmp/dist/Porthole.app 9 1", bundlePath: "/tmp/dist/Porthole.app"), false)
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

    expect("dock: a viewer-only Mac always has its Dock icon", Presence.dockIcon(hosting: false, viewerWindows: 0), true)
    expect("dock: a Mac that only shares stays in the menu bar", Presence.dockIcon(hosting: true, viewerWindows: 0), false)
    expect("dock: it gets a Dock icon while a viewer window is open", Presence.dockIcon(hosting: true, viewerWindows: 1), true)
}
