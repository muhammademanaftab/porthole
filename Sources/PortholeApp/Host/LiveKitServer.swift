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
        let url = HostConfig.directory.appendingPathComponent("livekit.yaml")
        Self.stopLeftovers(of: bin, config: url.path)
        let yaml = liveKitConfigYAML(port: config.livekitPort, apiKey: config.apiKey, apiSecret: config.apiSecret)
        guard writePrivately(Data(yaml.utf8), to: url) else {
            throw NSError(domain: "Porthole", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't write \(url.path)"])
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--config", url.path]
        let logURL = HostConfig.directory.appendingPathComponent("livekit.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > Self.maxLogBytes {
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
            try? FileManager.default.moveItem(at: logURL, to: logURL.appendingPathExtension("1"))
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? logHandle?.close()
        logHandle = try? FileHandle(forWritingTo: logURL)
        if let fh = logHandle { _ = try? fh.seekToEnd(); p.standardOutput = fh; p.standardError = fh }
        let startedAt = Date()
        p.terminationHandler = { [weak self] proc in
            Log.info("livekit-server exited with status \(proc.terminationStatus)", .net)
            guard let self, !self.stopping else { return }
            let delay = restartDelay(after: self.lastRestartDelay, uptime: Date().timeIntervalSince(startedAt))
            self.lastRestartDelay = delay
            self.restart(after: delay)
        }
        try p.run()
        process = p
        if LiveKitServer.shared == nil { atexit { LiveKitServer.shared?.process?.terminate() } }
        LiveKitServer.shared = self
    }

    static func stopLeftovers(of bin: String, config: String) {
        let stale = Array(Set(Processes.running(executable: bin) + Processes.running(named: "livekit-server", argument: config)))
        guard !stale.isEmpty else { return }
        for pid in stale { Log.info("stopping leftover livekit-server \(pid)", .net) }
        Processes.stop(stale)
    }

    static let maxLogBytes = 5_000_000
    private var logHandle: FileHandle?

    private func restart(after delay: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(delay))) { [weak self] in
            guard let self, !self.stopping else { return }
            do { try self.start() } catch {
                Log.error("livekit-server could not be restarted: \(error.localizedDescription); trying again", .net)
                let next = restartDelay(after: self.lastRestartDelay, uptime: 0)
                self.lastRestartDelay = next
                self.restart(after: next)
            }
        }
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
