import Foundation

final class ShellOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    let closed = DispatchSemaphore(value: 0)

    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum Shell {
    public static let killedStatus: Int32 = 128 + SIGKILL

    public static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 10, grace: TimeInterval = 1) -> (status: Int32, out: String)? {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let output = ShellOutput()
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; output.closed.signal() } else { output.append(d) }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { reader.readabilityHandler = nil; return nil }
        var finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished {
            kill(p.processIdentifier, SIGTERM)
            finished = exited.wait(timeout: .now() + grace) == .success
            if !finished {
                kill(p.processIdentifier, SIGKILL)
                finished = exited.wait(timeout: .now() + 2) == .success
            }
        }
        _ = output.closed.wait(timeout: .now() + 0.3)
        reader.readabilityHandler = nil
        return (finished && !p.isRunning ? p.terminationStatus : killedStatus, output.text)
    }
}
