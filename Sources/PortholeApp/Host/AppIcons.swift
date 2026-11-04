import AppKit
import PortholeCore

@MainActor
enum AppIcons {
    private static var cache: [String: Data] = [:]

    static func png(forWindow id: UInt32) async -> Data? {
        guard let w = try? await WindowCatalog.shareable(onScreenOnly: false).first(where: { $0.windowID == id }),
              let owner = w.owningApplication else { return nil }
        let url = NSRunningApplication(processIdentifier: owner.processID)?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner.bundleIdentifier)
        guard let url else { return nil }
        if let hit = cache[url.path] { return hit }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        var rect = CGRect(x: 0, y: 0, width: AppIcon.pixels, height: AppIcon.pixels)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = AppIcon.png(from: cg), AppIcon.isAcceptable(png) else { return nil }
        cache[url.path] = png
        return png
    }
}
