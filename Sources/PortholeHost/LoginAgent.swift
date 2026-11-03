import Foundation
import PortholeCore

enum LoginAgent {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(LaunchAgent.label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static var launchedByAgent: Bool { ProcessInfo.processInfo.environment[LaunchAgent.launchedEnvKey] == "1" }

    private static var offeredMarker: URL { HostConfig.directory.appendingPathComponent("login-agent-offered") }

    static func installOnFirstRun() {
        guard !FileManager.default.fileExists(atPath: offeredMarker.path) else { return }
        FileManager.default.createFile(atPath: offeredMarker.path, contents: nil)
        if !isInstalled { install() }
    }

    @discardableResult
    static func install() -> Bool {
        guard let exe = Bundle.main.executableURL?.path,
              let data = LaunchAgent.plistData(executable: exe, logDirectory: Log.url.deletingLastPathComponent().path) else { return false }
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            Log.info("login agent: could not write \(plistURL.path): \(error.localizedDescription)")
            return false
        }
        let status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        Log.info("login agent installed (bootstrap status \(status))")
        return true
    }

    static func handOver() {
        let target = "gui/\(getuid())/\(LaunchAgent.label)"
        if launchctl(["print", target]) != 0 { launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) }
        launchctl(["kickstart", target])
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
        Log.info("login agent removed; it stays active until logout")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
