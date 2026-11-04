import AppKit
import CoreGraphics
import PortholeCore

final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any] = [:]

    func set(_ v: [String: Any]) { lock.lock(); value = v; lock.unlock() }

    func get() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@MainActor
enum LocalStatus {
    static let started = Date()
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? portholeVersion
    }

    static func snapshot(_ app: HostApp, watched: Bool) -> [String: Any] {
        let stage = app.host.stage
        var stageInfo: [String: Any] = ["ready": stage.isReady, "parked": stage.parkedCount, "idleLimit": Int(stage.idleLimit)]
        if let id = stage.displayID { stageInfo["display"] = Int(id) }
        if let b = stage.bounds { stageInfo["bounds"] = [b.origin.x, b.origin.y, b.width, b.height] }
        if let since = stage.idleSince { stageInfo["idleSince"] = LogTime.format(since) }
        let shared = app.host.sharedWindows.map { w -> [String: Any] in
            ["id": Int(w.info.id), "app": w.info.app, "title": w.info.title, "viewers": w.viewers]
        }
        var out: [String: Any] = [
            "pid": Int(getpid()),
            "version": version,
            "started": LogTime.format(started),
            "updated": LogTime.format(Date()),
            "state": app.state,
            "connected": app.host.isConnected,
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "accessibility": InputInjector.isTrusted,
            "watched": watched,
            "watchdog": KeepRunning.describe(KeepRunning.status),
            "screenLocked": Session.isScreenLocked,
            "paired": app.trust.store.devices().count,
            "httpPort": Int(app.config.httpPort),
            "livekitPort": app.config.livekitPort,
            "stage": stageInfo,
            "shared": shared,
        ]
        if let ip = tailscaleAddress() { out["tailscaleIP"] = ip }
        if let name = app.http?.advertised { out["bonjour"] = name }
        return out
    }
}
