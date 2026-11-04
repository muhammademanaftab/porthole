import Darwin
import Foundation
import PortholeCore

final class LiveKitServer {
    private var process: Process?
    let config: HostConfig

    init(config: HostConfig) { self.config = config }

    static func locateBinary() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PORTHOLE_LIVEKIT_SERVER"] { candidates.append(env) }
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent("livekit-server").path) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("livekit-server").path) }
        candidates += ["/opt/homebrew/bin/livekit-server", "/usr/local/bin/livekit-server"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() throws {
        guard let bin = Self.locateBinary() else {
            throw NSError(domain: "Porthole", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "livekit-server not found. Install it with `brew install livekit` or bundle it in the app."])
        }
        Self.stopLeftovers(of: bin)
        let yaml = liveKitConfigYAML(port: config.livekitPort, apiKey: config.apiKey, apiSecret: config.apiSecret)
        let url = HostConfig.directory.appendingPathComponent("livekit.yaml")
        guard writePrivately(Data(yaml.utf8), to: url) else {
            throw NSError(domain: "Porthole", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't write \(url.path)"])
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--config", url.path]
        let logURL = HostConfig.directory.appendingPathComponent("livekit.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) { p.standardOutput = fh; p.standardError = fh }
        let startedAt = Date()
        p.terminationHandler = { [weak self] proc in
            Log.info("livekit-server exited with status \(proc.terminationStatus)", .net)
            guard let self, !self.stopping else { return }
            let delay = restartDelay(after: self.lastRestartDelay, uptime: Date().timeIntervalSince(startedAt))
            self.lastRestartDelay = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(delay))) { try? self.start() }
        }
        try p.run()
        process = p
        atexit { LiveKitServer.shared?.process?.terminate() }
        LiveKitServer.shared = self
    }

    static func stopLeftovers(of bin: String) {
        let stale = Processes.running(executable: bin)
        guard !stale.isEmpty else { return }
        for pid in stale { Log.info("stopping leftover livekit-server \(pid)", .net) }
        Processes.stop(stale)
    }

    private var stopping = false
    private var lastRestartDelay: UInt64?

    func stop() { stopping = true; process?.terminate() }

    nonisolated(unsafe) static var shared: LiveKitServer?

    func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "http://127.0.0.1:\(config.livekitPort)/")!
        while Date() < deadline {
            if let (_, resp) = try? await URLSession.shared.data(from: url), (resp as? HTTPURLResponse) != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}
