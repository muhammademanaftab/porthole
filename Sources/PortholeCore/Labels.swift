import CoreGraphics

public extension WindowInfo {
    var pickerLabel: String { title.isEmpty ? app : "\(app) — \(title)" }

    var portalTitle: String { pickerLabel }
}

public func hostMenuTitle(state: String, openWindows n: Int) -> String {
    "Porthole: \(state)\(n > 0 ? " · \(n) window\(n == 1 ? "" : "s") open" : "")"
}

public enum PortalPhase: Equatable, Sendable {
    case opening(String)
    case reconnecting
    case disconnected(String)
    case failed(String)
    case locked

    public var busy: Bool {
        switch self {
        case .opening, .reconnecting: return true
        case .disconnected, .failed, .locked: return false
        }
    }

    public var clearsOnPicture: Bool {
        switch self {
        case .opening, .failed: return true
        case .reconnecting, .disconnected, .locked: return false
        }
    }

    public var title: String {
        switch self {
        case .opening(let app): return app.isEmpty ? "Opening window…" : "Opening \(app)…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .failed: return "Can't Open This Window"
        case .locked: return "Screen Is Locked"
        }
    }

    public var detail: String {
        switch self {
        case .opening: return "Waiting for the first picture from the host."
        case .reconnecting: return "The connection to the host dropped. The picture comes back when it reconnects."
        case .disconnected(let why), .failed(let why): return why
        case .locked: return "This Mac's screen is locked, so typing and clicks go to the lock screen."
        }
    }

    public var symbol: String {
        switch self {
        case .opening, .reconnecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "wifi.exclamationmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .locked: return "lock.fill"
        }
    }

    public var canRetry: Bool {
        if case .failed = self { return true }
        return false
    }

    public var canUnlock: Bool { self == .locked }

    public var closeTitle: String { self == .locked ? "Not Now" : "Close Window" }
}

public func hostStatusLine(state: String, openWindows n: Int) -> String {
    n > 0 && state == "Sharing" ? "Sharing \(n) window\(n == 1 ? "" : "s")" : state == "Sharing" ? "Ready to share" : state
}

public func viewerCountLabel(_ n: Int) -> String {
    n <= 1 ? "" : "\(n) viewers"
}

public func portalContentSize(remote size: CGSize, screen: CGSize) -> CGSize {
    CGSize(width: min(max(size.width, 320), screen.width), height: min(max(size.height, 200), screen.height))
}

public func pickerStatus(_ n: Int) -> String {
    n == 0 ? "No windows to share on the host." : "\(n) window\(n == 1 ? "" : "s"). Click one to open it."
}
