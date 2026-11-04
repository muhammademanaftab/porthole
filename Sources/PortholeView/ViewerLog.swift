import Foundation
import PortholeCore

enum VLog {
    static let writer = LogWriter(role: "viewer", echo: false, verbose: verboseFromEnvironment(ProcessInfo.processInfo.environment))

    static func info(_ s: String) { writer.write(LogLevel.infer(s), .viewer, s) }
    static func warn(_ s: String) { writer.write(.warn, .viewer, s) }
    static func flush() { writer.flush() }
}

enum ViewerRecents {
    static func opened(_ info: WindowInfo, host: String, name: String) {
        let entry = RecentPortal(host: host, hostName: name, windowID: info.id, title: info.title, app: info.app, bundle: info.bundle, time: Date())
        RecentPortals.record(entry, in: portholeSupportDirectory())
        VLog.info("portal opened: window \(info.id) of \(info.app) on \(name) (\(host))")
    }
}
