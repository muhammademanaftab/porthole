import Foundation
import PortholeCore

enum LogCommand {
    static func emit(_ lines: [LogLine], json: Bool) {
        var out = ""
        for l in lines {
            if json {
                if let data = try? JSONSerialization.data(withJSONObject: l.jsonObject(), options: [.sortedKeys, .withoutEscapingSlashes]) {
                    out += String(decoding: data, as: UTF8.self) + "\n"
                }
            } else {
                out += l.formatted + "\n"
            }
            if out.utf8.count > 1 << 16 { FileHandle.standardOutput.write(Data(out.utf8)); out = "" }
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    static func run(_ o: LogOptions) -> Int32 {
        let dir = Paths.logs
        switch o.mode {
        case .path:
            print(dir.path)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for f in files {
                let size = ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f).path))?[.size] as? Int) ?? 0
                print("  \(f)  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            }
            return 0
        case .stats:
            let lines = LogQuery(o).select(readLogs())
            if o.json { for b in logStats(lines) { printJSON(b.jsonObject(), pretty: false) } }
            else { print(renderStats(logStats(lines))) }
            return 0
        case .tail, .grep:
            let lines = LogQuery(o).select(readLogs())
            if lines.isEmpty && !o.json { say("No matching lines in \(dir.path).") }
            emit(lines, json: o.json)
            return 0
        case .follow:
            emit(LogQuery(o).select(readLogs()), json: o.json)
            follow(o)
        }
    }

    static func follow(_ o: LogOptions) -> Never {
        var q = LogQuery(o)
        q.limit = nil
        q.since = nil
        say("Following \(Paths.logs.path) (Ctrl-C to stop)…")
        var offsets: [String: UInt64] = [:]
        for role in LogFiles.roles {
            let url = LogFiles.url(role: role, in: Paths.logs)
            offsets[role] = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
        }
        var partial: [String: String] = [:]
        while true {
            for role in LogFiles.roles {
                let url = LogFiles.url(role: role, in: Paths.logs)
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
                var offset = offsets[role] ?? 0
                if size < offset { offset = 0; partial[role] = "" }
                guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { continue }
                try? h.seek(toOffset: offset)
                let data = (try? h.readToEnd()) ?? Data()
                try? h.close()
                offsets[role] = offset + UInt64(data.count)
                var text = (partial[role] ?? "") + String(decoding: data, as: UTF8.self)
                var tail = ""
                if !text.hasSuffix("\n"), let nl = text.lastIndex(of: "\n") {
                    tail = String(text[text.index(after: nl)...]); text = String(text[...nl])
                } else if !text.hasSuffix("\n") { tail = text; text = "" }
                partial[role] = tail
                emit(LogFiles.parse(text, role: role).filter(q.matches), json: o.json)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

enum TrailCommand {
    static func text(_ o: TrailOptions, now: Date = Date()) -> String {
        let lines = Trail.select(readLogs(), since: now.addingTimeInterval(-o.window), all: o.all)
        return "Trail since \(LogTime.format(now.addingTimeInterval(-o.window), milliseconds: false)) (UTC), \(lines.count) event(s)\n" + Trail.render(lines)
    }

    static func run(_ o: TrailOptions) -> Int32 {
        if o.json {
            let lines = Trail.select(readLogs(), since: Date().addingTimeInterval(-o.window), all: o.all)
            LogCommand.emit(lines, json: true)
        } else {
            print(text(o))
        }
        return 0
    }
}

enum WhyQuitCommand {
    static func crashReports(since: Date) -> [CrashReport] {
        let dir = Paths.crashReports
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("porthole-host") && $0.hasSuffix(".ips") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, mod >= since else { return nil }
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { h -> String? in
                defer { try? h.close() }
                return (try? h.read(upToCount: 8192)).map { String(decoding: $0, as: UTF8.self) }
            } ?? ""
            let pid = head.range(of: #""pid"\s*:\s*(\d+)"#, options: .regularExpression).flatMap { r -> Int32? in
                Int32(head[r].split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
            }
            return CrashReport(path: url.path, time: mod, pid: pid)
        }
    }

    static func runs() -> [HostRun] {
        let lines = LogFiles.read(role: "host", in: Paths.logs)
        let alive = Set(Procs.hosts())
        let marker = readText(Paths.marker)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = lines.first(where: { $0.time != nil })?.time ?? Date().addingTimeInterval(-30 * 86400)
        return deriveRuns(lines, alive: alive, hostRunning: !alive.isEmpty, crashes: crashReports(since: first), lastMarker: marker)
    }

    static func text(_ n: Int) -> String {
        let all = runs()
        guard !all.isEmpty else { return "No Porthole Host runs in \(Paths.logs.path)." }
        let shown = all.suffix(n).reversed()
        var out = ["Last \(shown.count) of \(all.count) run(s) of Porthole Host, newest first (UTC):"]
        for r in shown { out.append(r.render()) }
        return out.joined(separator: "\n")
    }

    static func run(_ n: Int) -> Int32 {
        print(text(n))
        return 0
    }
}

enum EnvCommand {
    static func run(setOnly: Bool, json: Bool) -> Int32 {
        let rows = EnvFlags.rows(environment: ProcessInfo.processInfo.environment, setOnly: setOnly)
        if json { printJSON(EnvFlags.json(rows)) } else { print(EnvFlags.render(rows)) }
        return 0
    }
}

enum VersionCommand {
    static func run() -> Int32 {
        print("porthole \(SystemFacts.bundleVersion ?? portholeVersion) (protocol \(portholeProtocolVersion))")
        print("  binary \(Paths.executable.path)")
        if let host = Procs.hosts().isEmpty ? nil : LocalHost.status(timeout: 2) {
            print("  running Porthole Host \(host["version"] as? String ?? "?") (pid \(host["pid"] as? Int ?? 0))")
        }
        return 0
    }
}
