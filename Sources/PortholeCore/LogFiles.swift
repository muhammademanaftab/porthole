import Foundation

public enum LogFiles {
    public static let maxBytes = 10 * 1024 * 1024
    public static let keep = 3
    public static let roles = ["host", "viewer"]

    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Logs/Porthole", isDirectory: true)
    }

    public static func url(role: String, in dir: URL) -> URL { dir.appendingPathComponent("\(role).log") }

    public static func generation(_ n: Int, role: String, in dir: URL) -> URL {
        n == 0 ? url(role: role, in: dir) : dir.appendingPathComponent("\(role).\(n).log")
    }

    public static func generations(role: String, in dir: URL) -> [URL] {
        (0...keep).reversed().map { generation($0, role: role, in: dir) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func lockURL(role: String, in dir: URL) -> URL { dir.appendingPathComponent("\(role).log.lock") }

    static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    public static func rotateIfNeeded(role: String, in dir: URL, maxBytes: Int = maxBytes) -> Bool {
        let live = url(role: role, in: dir)
        guard let size = size(of: live), size >= maxBytes else { return false }
        let fd = open(lockURL(role: role, in: dir).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        guard let locked = self.size(of: live), locked >= maxBytes else { return false }
        let fm = FileManager.default
        try? fm.removeItem(at: generation(keep, role: role, in: dir))
        for n in stride(from: keep - 1, through: 0, by: -1) {
            let from = generation(n, role: role, in: dir)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: generation(n + 1, role: role, in: dir)) }
        }
        return true
    }

    public static func parse(_ text: String, role: String) -> [LogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { LogLine.parse(String($0), defaultRole: role) }
    }

    public static func read(role: String, in dir: URL) -> [LogLine] {
        generations(role: role, in: dir).flatMap { url -> [LogLine] in
            guard let data = try? Data(contentsOf: url) else { return [] }
            return parse(String(decoding: data, as: UTF8.self), role: role)
        }
    }

    public static func readAll(in dir: URL, roles: [String] = roles) -> [LogLine] {
        merge(roles.map { read(role: $0, in: dir) })
    }

    public static func merge(_ streams: [[LogLine]]) -> [LogLine] {
        var tagged: [(Date, Int, Int, LogLine)] = []
        for (s, lines) in streams.enumerated() {
            var last = Date.distantPast
            for (i, line) in lines.enumerated() {
                if let t = line.time { last = t }
                tagged.append((last, s, i, line))
            }
        }
        tagged.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 != b.1 ? a.1 < b.1 : a.2 < b.2 }
        return tagged.map(\.3)
    }
}

public final class LogWriter: @unchecked Sendable {
    public let directory: URL
    public let role: String
    public var echo: Bool
    public var verbose: Bool
    private let queue: DispatchQueue
    private var writes = 0

    public init(role: String, directory: URL = LogFiles.directory(), echo: Bool = true, verbose: Bool = false) {
        self.role = role; self.directory = directory; self.echo = echo; self.verbose = verbose
        queue = DispatchQueue(label: "porthole.log.\(role)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = LogFiles.rotateIfNeeded(role: fileRole, in: directory)
    }

    public var fileRole: String { role == "watchdog" ? "host" : role }
    public var url: URL { LogFiles.url(role: fileRole, in: directory) }

    public func line(_ level: LogLevel, _ category: LogCategory, _ text: String, at time: Date = Date()) -> String {
        LogLine.format(time: time, level: level, category: category, role: role, pid: getpid(), text: text) + "\n"
    }

    public func write(_ level: LogLevel, _ category: LogCategory?, _ text: String) {
        if level == .debug && !verbose { return }
        let cat = category ?? LogCategory.infer(text, fallback: LogLine.fallback(role))
        let data = Data(line(level, cat, text).utf8)
        let echo = echo
        queue.async { [self] in
            if echo { FileHandle.standardError.write(data) }
            append(data)
            writes += 1
            if writes % 2000 == 0 { _ = LogFiles.rotateIfNeeded(role: fileRole, in: directory) }
        }
    }

    public func writeNow(_ level: LogLevel, _ category: LogCategory, _ text: String) {
        append(Data(line(level, category, text).utf8))
    }

    private func append(_ data: Data) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    public func flush() { queue.sync {} }
}

public func verboseFromEnvironment(_ env: [String: String]) -> Bool {
    LogLevel.parse(env["PORTHOLE_LOG"] ?? "") == .debug || env["PORTHOLE_VERBOSE"] == "1"
}
