import Foundation

public enum HostingSwitch {
    public static let settingKey = "hosting"
    public static let envKey = "PORTHOLE_HOSTING"

    public static func firstRunDefault(hasHostConfig: Bool, oldHostInstalled: Bool, watchdogLoaded: Bool, watchdogRunning: Bool) -> Bool {
        hasHostConfig && (oldHostInstalled || watchdogLoaded || watchdogRunning)
    }

    public static func saved(stored: Any?, firstRun: () -> Bool) -> (on: Bool, decided: Bool) {
        if let on = stored as? Bool { return (on, false) }
        return (firstRun(), true)
    }

    public static func thisRun(saved: Bool, environment: [String: String]) -> Bool {
        switch environment[envKey] {
        case "1": return true
        case "0": return false
        default: return saved
        }
    }

    public static func overridden(_ environment: [String: String]) -> Bool {
        ["0", "1"].contains(environment[envKey] ?? "")
    }
}

public enum OneApp {
    public static let bundleID = LaunchAgent.hostBundleID
    public static let oldViewerBundleID = "io.github.muhammademanaftab.porthole.view"
    public static let appName = "Porthole"
    public static let oldHostAppName = "Porthole Host"
    public static let migratedKey = "migratedViewerDefaults"
    public static let quitOldAppsKey = "migratedOldApps"
    public static let keychainMigratedKey = "migratedKeychainItems"

    public static var viewerKeys: [String] {
        [ViewerSettings.bitrateKey, ViewerSettings.fpsKey, ViewerSettings.levelKey, ViewerSettings.hideTitleBarKey,
         ViewerSettings.playSoundKey, SoundEffects.settingKey, RouteMode.settingKey, "host", "password"]
    }

    public static func viewerDefaultsToCopy(old: [String: Any], current: (String) -> Any?) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in viewerKeys where current(key) == nil {
            if let value = old[key] { out[key] = value }
        }
        return out
    }

    public static func oldHostApps(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications/\(oldHostAppName).app"), home.appendingPathComponent("Applications/\(oldHostAppName).app")]
    }

    public static func isOldApp(bundleID: String?, bundlePath: String?, ownBundlePath: String) -> Bool {
        guard let bundleID, let bundlePath else { return false }
        let path = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        guard path != URL(fileURLWithPath: ownBundlePath).standardizedFileURL.path else { return false }
        if bundleID == oldViewerBundleID { return true }
        return bundleID == self.bundleID && URL(fileURLWithPath: path).lastPathComponent == "\(oldHostAppName).app"
    }

    public static func isOldWatchdog(executable: String?) -> Bool {
        executable?.contains("/\(oldHostAppName).app/") == true
    }

    public static func isInstalledOneApp(_ url: URL) -> Bool {
        url.standardizedFileURL.lastPathComponent == "\(appName).app"
    }

    public static func isInside(_ path: String, app: String) -> Bool {
        let a = URL(fileURLWithPath: app).standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(a + "/")
    }
}

public enum LaunchOrigin: Equatable, Sendable {
    case run(mayHost: Bool)
    case handOff

    public static func decide(bundled: Bool, parentIsLaunchd: Bool, watchdogLaunched: Bool, arguments: [String], environment: [String: String]) -> LaunchOrigin {
        if parentIsLaunchd || watchdogLaunched { return .run(mayHost: true) }
        if bundled { return arguments.contains { !$0.hasPrefix("-") } ? .run(mayHost: false) : .handOff }
        return .run(mayHost: environment[HostingSwitch.envKey] == "1")
    }
}

public extension ExitMarker {
    static func onTerminate(sessionEnding: Bool) -> ExitMarker { sessionEnding ? .session : .quit }
}

public enum LaunchctlPrint {
    public static func pid(_ text: String) -> Int32? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 3, parts[0].trimmingCharacters(in: .whitespaces) == "pid", parts[1] == "=", let n = Int32(parts[2]), n > 0 { return n }
        }
        return nil
    }
}

public enum AppCommand: Equatable, Sendable {
    case host
    case viewer
    case help

    public static func route(_ args: [String], invokedAs name: String) -> AppCommand {
        if name == CLITool.viewer.rawValue { return .viewer }
        guard let first = args.first else { return .host }
        if ["help", "-h", "--help"].contains(first) { return .help }
        if ["request", "pair", "machines", "ls", "list", "open", "recent"].contains(first) { return .viewer }
        return .host
    }
}

public enum Presence {
    public static func dockIcon(hosting: Bool, viewerWindows: Int) -> Bool {
        !hosting || viewerWindows > 0
    }
}

public enum WatchdogStamp {
    public static func registerAgain(saved: String?, current: String, bundlePath: String) -> Bool {
        let installed = bundlePath.hasPrefix("/Applications/")
        guard let saved else { return installed }
        if saved == current { return false }
        if saved.hasPrefix(bundlePath + " ") { return true }
        return installed && saved.contains("/\(OneApp.oldHostAppName).app ")
    }
}

public func otherMacs(_ hosts: [DiscoveredHost], thisMac id: String?) -> [DiscoveredHost] {
    guard let id else { return hosts }
    return hosts.filter { $0.hostID != id }
}
