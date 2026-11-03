import Foundation

final class LiveKitServer {
    private var process: Process?
    let config: HostConfig

    init(config: HostConfig) { self.config = config }

    static func locateBinary() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PORTHOLE_LIVEKIT_SERVER"] { candidates.append(env) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("livekit-server").path) }
        candidates += ["/opt/homebrew/bin/livekit-server", "/usr/local/bin/livekit-server"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() throws {
        guard let bin = Self.locateBinary() else {
            throw NSError(domain: "Porthole", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "livekit-server not found. Install it with `brew install livekit` or bundle it in the app."])
        }
        let yaml = """
        port: \(config.livekitPort)
        bind_addresses:
          - ""
        rtc:
          tcp_port: \(config.livekitPort + 1)
          udp_port: \(config.livekitPort + 2)
          use_external_ip: false
          enable_loopback_candidate: true
        keys:
          \(config.apiKey): \(config.apiSecret)
        logging:
          level: warn
        """
        let url = HostConfig.directory.appendingPathComponent("livekit.yaml")
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--config", url.path]
        let logURL = HostConfig.directory.appendingPathComponent("livekit.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) { p.standardOutput = fh; p.standardError = fh }
        p.terminationHandler = { proc in
            NSLog("Porthole: livekit-server exited with status \(proc.terminationStatus)")
        }
        try p.run()
        process = p
        atexit { LiveKitServer.shared?.process?.terminate() }
        LiveKitServer.shared = self
    }

    func stop() { process?.terminate() }

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
