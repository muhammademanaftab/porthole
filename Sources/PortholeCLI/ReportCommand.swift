import Foundation
import PortholeCore

enum ReportCommand {
    static func stamp(_ d: Date) -> String {
        LogTime.format(d, milliseconds: false).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "-").replacingOccurrences(of: "Z", with: "")
    }

    static func run(_ o: ReportOptions) -> Int32 {
        let now = Date()
        let fm = FileManager.default
        let name = "Porthole-Report-\(stamp(now))"
        let stage = fm.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))").appendingPathComponent(name)
        do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) } catch {
            fail("couldn't make a folder for the report: \(error.localizedDescription)"); return 1
        }
        defer { try? fm.removeItem(at: stage.deletingLastPathComponent()) }
        let scrub = Scrubber(secrets: knownSecrets())
        var manifest: [String] = []
        func put(_ path: String, _ text: String) {
            let url = stage.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(scrub.scrub(text).utf8).write(to: url)
            manifest.append(path)
        }
        let since = o.since.map { now.addingTimeInterval(-$0) }
        say("Collecting the doctor readout…")
        put("doctor.txt", DoctorCommand.text(quick: true))
        put("why-quit.txt", WhyQuitCommand.text(10))
        put("trail.txt", TrailCommand.text({ var t = TrailOptions(); t.window = o.since ?? 3600; return t }(), now: now))
        if o.logs {
            for role in LogFiles.roles {
                for url in LogFiles.generations(role: role, in: Paths.logs) {
                    guard let text = readText(url) else { continue }
                    let kept = since.map { s in LogFiles.parse(text, role: role).filter { ($0.time ?? .distantPast) >= s }.map(\.formatted).joined(separator: "\n") } ?? text
                    put("logs/\(url.lastPathComponent)", kept)
                }
            }
            let samples = ((try? fm.contentsOfDirectory(atPath: Paths.logs.path)) ?? []).filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }
            for s in samples.sorted().suffix(5) {
                let url = Paths.logs.appendingPathComponent(s)
                if let since, let mod = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, mod < since { continue }
                if let text = readText(url) { put("hangs/\(s)", text) }
            }
            for c in WhyQuitCommand.crashReports(since: now.addingTimeInterval(-86400)) {
                if let text = readText(URL(fileURLWithPath: c.path)) { put("crashes/\(URL(fileURLWithPath: c.path).lastPathComponent)", text) }
            }
            for url in [Paths.support.appendingPathComponent("livekit.log")] where fm.fileExists(atPath: url.path) {
                if let text = readText(url) { put("logs/livekit.log", String(text.suffix(200_000))) }
            }
        }
        if o.system {
            var sys = ["date \(LogTime.format(now))", "computer \(SystemFacts.computerName)", "model \(SystemFacts.model)", SystemFacts.macOS,
                       "porthole \(SystemFacts.bundleVersion ?? portholeVersion) (protocol \(portholeProtocolVersion))",
                       "uptime \(formatDuration(ProcessInfo.processInfo.systemUptime))",
                       "memory \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))",
                       "cpus \(ProcessInfo.processInfo.activeProcessorCount)"]
            if let cpu = SystemFacts.sysctlString("machdep.cpu.brand_string") { sys.append("cpu \(cpu)") }
            let rows = EnvFlags.rows(environment: ProcessInfo.processInfo.environment, setOnly: true)
            sys.append("\nPORTHOLE_* flags set for this command:\n" + EnvFlags.render(rows))
            if let status = LocalHost.status(), let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
                sys.append("\nrunning host status:\n" + String(decoding: data, as: UTF8.self))
            }
            put("system.txt", sys.joined(separator: "\n"))
        }
        if o.trust {
            var lines = ["This Mac: \(savedIdentity().map(shortID) ?? "no device ID yet")"]
            let paired = TrustStore(directory: Paths.support).devices()
            lines.append("\nMacs that may view this one (\(paired.count)):")
            lines += paired.map { "  \(shortID($0.id))  \($0.name)  paired \(LogTime.format($0.pairedAt, milliseconds: false))" }
            let viewer = ViewerTrust.decode(viewerDefaults()?.data(forKey: "pairedHosts"))
            lines.append("\nHosts this Mac may view (\(viewer.hosts.count)):")
            lines += viewer.hosts.map { "  \(shortID($0.id))  \($0.name)  at \($0.addresses.joined(separator: ", "))" }
            let recents = RecentPortals.load(in: Paths.support)
            lines.append("\nRecent portals:\n" + RecentPortals.render(recents, now: now))
            put("paired.txt", lines.joined(separator: "\n"))
        }
        if let d = o.description { put("description.txt", d) }
        put("README.txt", "Porthole problem report made \(LogTime.format(now)) by `porthole report`.\nNothing was uploaded. Passwords, tokens, pairing codes and secrets are replaced with \(Scrubber.mask); device IDs are shortened.\n\nFiles:\n" + manifest.map { "  \($0)" }.joined(separator: "\n"))

        let out: URL
        if let p = o.out {
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            out = fm.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue ? u.appendingPathComponent("\(name).zip") : u
        } else {
            out = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(name).zip")
        }
        try? fm.removeItem(at: out)
        guard let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", stage.path, out.path], timeout: 120), r.status == 0 else {
            fail("couldn't write \(out.path)"); return 1
        }
        print(out.path)
        say("\(manifest.count) file(s); nothing was uploaded.")
        return 0
    }
}
