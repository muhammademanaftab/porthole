import Foundation
import PortholeCore

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Porthole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("host.log")
    }()
    private static let queue = DispatchQueue(label: "porthole.log")
    private static let formatter = ISO8601DateFormatter()
    nonisolated(unsafe) static var verbose = UserDefaults.standard.bool(forKey: HostSettings.verboseKey)

    static func info(_ s: String) {
        let line = Data("\(formatter.string(from: Date())) \(s)\n".utf8)
        queue.async {
            FileHandle.standardError.write(line)
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }

    static func debug(_ s: @autoclosure () -> String) {
        if verbose { info(s()) }
    }

    static func flush() { queue.sync {} }
}
