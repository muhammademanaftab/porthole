import Darwin
import Foundation
import PortholeCore

enum Processes {
    static func running(executable path: String) -> [pid_t] {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let own = ProcessInfo.processInfo.processIdentifier
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        return pids.prefix(Int(max(n, 0))).filter { pid in
            guard pid > 0, pid != own, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path == target
        }
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return parseProcessArguments(Array(buf.prefix(size)))
    }

    static func isWatchdog(_ pid: pid_t) -> Bool {
        HostCommand.parse(arguments: Array(arguments(pid).dropFirst()), environment: [:]) == .watchdog
    }

    static func hosts(executable path: String) -> [pid_t] {
        running(executable: path).filter { !isWatchdog($0) }
    }

    static func stop(_ pids: [pid_t], timeout: TimeInterval = 3) {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        usleep(300_000)
    }
}
