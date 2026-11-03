import AppKit
import PortholeCore
import ScreenCaptureKit

enum WindowCatalog {
    static func shareable(onScreenOnly: Bool = true) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenOnly)
        let me = Bundle.main.bundleIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { w in
            WindowFilter.isShareable(layer: w.windowLayer, size: w.frame.size,
                                     owner: w.owningApplication.map { WindowOwner(pid: $0.processID, bundle: $0.bundleIdentifier) },
                                     myPID: myPID, myBundle: me)
        }
    }

    static func list() async throws -> [WindowInfo] {
        WindowFilter.sortedForPicker(try await shareable().map { w in
            WindowInfo(id: w.windowID, app: w.owningApplication?.applicationName ?? "",
                       title: w.title ?? "", bundle: w.owningApplication?.bundleIdentifier,
                       w: w.frame.width, h: w.frame.height)
        })
    }

    static func window(id: UInt32) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == id }
    }
}

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

    var scale: CGFloat {
        if !Thread.isMainThread { return DispatchQueue.main.sync { scale } }
        let screens = NSScreen.screens.map { ScreenInfo(frame: $0.frame, scale: $0.backingScaleFactor) }
        return backingScale(forCGBounds: bounds, screens: screens) ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
