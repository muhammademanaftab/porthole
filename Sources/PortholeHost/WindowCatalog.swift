import AppKit
import PortholeCore
import ScreenCaptureKit

/// Lists the windows a viewer may open. Hidden, tiny and password-manager windows never appear.
enum WindowCatalog {
    static let blockedBundles: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
    ]

    static func shareable() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = Bundle.main.bundleIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { w in
            guard w.windowLayer == 0, w.frame.width >= 60, w.frame.height >= 40,
                  let app = w.owningApplication else { return false }
            if app.processID == myPID || app.bundleIdentifier == me { return false }
            if blockedBundles.contains(app.bundleIdentifier) { return false }
            if app.bundleIdentifier == "com.apple.WindowManager" || app.bundleIdentifier == "com.apple.dock" { return false }
            return true
        }
    }

    static func list() async throws -> [WindowInfo] {
        try await shareable().map { w in
            WindowInfo(id: w.windowID, app: w.owningApplication?.applicationName ?? "",
                       title: w.title ?? "", bundle: w.owningApplication?.bundleIdentifier,
                       w: w.frame.width, h: w.frame.height)
        }.sorted { ($0.app, $0.title) < ($1.app, $1.title) }
    }

    static func window(id: UInt32) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == id }
    }
}

/// Live facts about a window from WindowServer: bounds in global points (top-left origin) and owner.
struct LiveWindow {
    var bounds: CGRect
    var pid: pid_t

    static func lookup(_ id: UInt32) -> LiveWindow? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
              let d = info.first,
              let b = d[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b),
              let pid = d[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return LiveWindow(bounds: rect, pid: pid)
    }

    /// Backing scale of the display the window sits on (2 on Retina, 1 otherwise).
    var scale: CGFloat {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Convert top-left global to AppKit's bottom-left global to find the screen.
        let appKitRect = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(appKitRect).area < b.frame.intersection(appKitRect).area
        }
        return screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
