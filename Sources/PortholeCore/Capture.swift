import CoreGraphics
import Foundation
import ScreenCaptureKit

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
        list.sorted { a, b in
            let app = a.app.localizedStandardCompare(b.app)
            if app != .orderedSame { return app == .orderedAscending }
            let title = a.title.localizedStandardCompare(b.title)
            if title != .orderedSame { return title == .orderedAscending }
            return a.id < b.id
        }
    }
}

public enum CapturePacing {
    public static let resendAfter: TimeInterval = 1.0
    public static let followSizeDelays: [TimeInterval] = [0.15, 0.4, 0.8]

    public static func shouldResend(now: Date, lastFrameAt: Date, hasBuffer: Bool) -> Bool {
        hasBuffer && now.timeIntervalSince(lastFrameAt) > resendAfter
    }

    public static func acceptsFrame(status raw: Int?) -> Bool {
        raw.flatMap(SCFrameStatus.init(rawValue:)) == .complete
    }
}

public struct ScreenInfo: Sendable {
    public var frame: CGRect
    public var scale: CGFloat

    public init(frame: CGRect, scale: CGFloat) { self.frame = frame; self.scale = scale }
}

public func appKitRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

public func backingScale(forCGBounds bounds: CGRect, screens: [ScreenInfo]) -> CGFloat? {
    let rect = appKitRect(fromCG: bounds, primaryHeight: screens.first?.frame.height ?? 0)
    func area(_ s: ScreenInfo) -> CGFloat {
        let i = s.frame.intersection(rect)
        return i.isNull ? 0 : i.width * i.height
    }
    return screens.max { area($0) < area($1) }?.scale
}
