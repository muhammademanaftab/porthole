import AppKit
import PortholeCore

@MainActor
enum LaunchHandOff {
    final class Flag: @unchecked Sendable { var done = false; var error: String? }

    static func run() -> Never {
        let own = Bundle.main.bundleURL
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: OneApp.bundleID).filter {
            $0.processIdentifier != getpid() && $0.bundleURL.map { OneApp.isInstalledOneApp($0) } == true
        }
        let target = others.first?.bundleURL ?? own
        let say = others.isEmpty ? "opening \(target.path) through Launch Services" : "Porthole is already running (pid \(others[0].processIdentifier)); handing over to it"
        FileHandle.standardError.write(Data("porthole-host: \(say)\n".utf8))
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let flag = Flag()
        NSWorkspace.shared.openApplication(at: target, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                flag.error = error?.localizedDescription
                flag.done = true
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while !flag.done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if let error = flag.error {
            FileHandle.standardError.write(Data("porthole-host: could not open \(target.path): \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
