import Foundation
import PortholeCore

enum Log {
    nonisolated(unsafe) static var writer = LogWriter(role: "host",
                                                     verbose: UserDefaults.standard.bool(forKey: HostSettings.verboseKey)
                                                        || verboseFromEnvironment(ProcessInfo.processInfo.environment))
    static var url: URL { writer.url }

    static var verbose: Bool {
        get { writer.verbose }
        set { writer.verbose = newValue || verboseFromEnvironment(ProcessInfo.processInfo.environment) }
    }

    static func becomeWatchdog() {
        writer = LogWriter(role: "watchdog", echo: writer.echo, verbose: writer.verbose)
    }

    static func info(_ s: String, _ category: LogCategory? = nil) {
        writer.write(LogLevel.infer(s), category, s)
    }

    static func warn(_ s: String, _ category: LogCategory? = nil) { writer.write(.warn, category, s) }

    static func error(_ s: String, _ category: LogCategory? = nil) { writer.write(.error, category, s) }

    static func debug(_ s: @autoclosure () -> String, _ category: LogCategory? = nil) {
        if writer.verbose { writer.write(.debug, category, s()) }
    }

    static func signalled(_ name: String) {
        writer.flush()
        writer.writeNow(.warn, .host, "caught \(name); stopping")
    }

    static func flush() { writer.flush() }
}
