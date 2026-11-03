import Foundation

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Porthole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("host.log")
    }()
    private static let queue = DispatchQueue(label: "porthole.log")
    private static let formatter = ISO8601DateFormatter()

    static func info(_ s: String) {
        let line = "\(formatter.string(from: Date())) \(s)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: url) }
        }
    }
}
