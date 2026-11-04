import AppKit
import PortholeCore

@MainActor
enum OneAppMigration {
    static func run() {
        copyViewerDefaults()
        quitOldApps()
    }

    static func copyViewerDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: OneApp.migratedKey) else { return }
        let old = d.persistentDomain(forName: OneApp.oldViewerBundleID) ?? [:]
        let copies = OneApp.viewerDefaultsToCopy(old: old, current: { d.object(forKey: $0) })
        for (key, value) in copies { d.set(value, forKey: key) }
        d.set(true, forKey: OneApp.migratedKey)
        if !copies.isEmpty { VLog.info("migration: copied \(copies.count) viewer setting(s) from \(OneApp.oldViewerBundleID)") }
    }

    static func quitOldApps() {
        let own = Bundle.main.bundlePath
        let old = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != getpid() && OneApp.isOldApp(bundleID: $0.bundleIdentifier, bundlePath: $0.bundleURL?.path, ownBundlePath: own)
        }
        let ownExe = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        let dogs = Processes.running(named: CLITool.host.rawValue, argument: "watchdog").filter { Processes.path($0) != ownExe }
        if !dogs.isEmpty {
            Log.info("migration: stopping the old app's watchdog \(dogs)", .watchdog)
            LegacyAgent.launchctl(["bootout", "gui/\(getuid())/\(LaunchAgent.label)"])
            Processes.stop(dogs)
        }
        guard !old.isEmpty else { return }
        let hosts = old.filter { $0.bundleIdentifier == OneApp.bundleID }
        let viewers = old.filter { $0.bundleIdentifier != OneApp.bundleID }
        for app in old { VLog.info("migration: quitting the old \(app.bundleURL?.lastPathComponent ?? "app") (pid \(app.processIdentifier))") }
        if !hosts.isEmpty {
            HostFiles.writeMarker(.quit)
            Processes.stop(hosts.map(\.processIdentifier), timeout: 5)
        }
        for app in viewers { app.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, viewers.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in viewers where !app.isTerminated { app.forceTerminate() }
    }
}
