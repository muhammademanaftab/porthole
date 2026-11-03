import CoreGraphics

public let maxCapturePixels = CGSize(width: 3840, height: 2400)

public func capturePixelSize(points: CGSize, scale: CGFloat, max limit: CGSize = maxCapturePixels) -> CGSize {
    var w = points.width * scale, h = points.height * scale
    let f = min(1, limit.width / w, limit.height / h)
    w = (w * f).rounded(.down); h = (h * f).rounded(.down)
    return CGSize(width: max(2, Int(w) & ~1), height: max(2, Int(h) & ~1))
}

public struct WindowOwner: Sendable {
    public var pid: Int32
    public var bundle: String

    public init(pid: Int32, bundle: String) { self.pid = pid; self.bundle = bundle }
}

public enum WindowFilter {
    public static let blockedBundles: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
    ]

    public static let systemBundles: Set<String> = ["com.apple.WindowManager", "com.apple.dock"]

    public static func isShareable(layer: Int, size: CGSize, owner: WindowOwner?, myPID: Int32, myBundle: String?) -> Bool {
        guard layer == 0, size.width >= 60, size.height >= 40, let app = owner else { return false }
        if app.pid == myPID || app.bundle == myBundle { return false }
        if blockedBundles.contains(app.bundle) { return false }
        if systemBundles.contains(app.bundle) { return false }
        return true
    }

    public static func sortedForPicker(_ list: [WindowInfo]) -> [WindowInfo] {
        list.sorted { ($0.app, $0.title) < ($1.app, $1.title) }
    }
}
