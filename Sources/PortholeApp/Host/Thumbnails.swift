import AppKit
import ImageIO
import PortholeCore
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum Thumbnails {
    private static var cache: [UInt32: (at: Date, jpeg: Data)] = [:]

    static func each(_ send: @escaping (UInt32, Data) async -> Void) async {
        guard let windows = try? await WindowCatalog.shareable(onScreenOnly: true) else { return }
        let infos = WindowFilter.sortedForPicker(windows.map {
            WindowInfo(id: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "",
                       bundle: nil, w: $0.frame.width, h: $0.frame.height)
        })
        let byID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        cache = cache.filter { Date().timeIntervalSince($0.value.at) < 60 }
        for id in WindowThumbnail.requests(for: infos) {
            if Task.isCancelled { return }
            guard let w = byID[id], let jpeg = await jpeg(for: w) else { continue }
            await send(id, jpeg)
        }
    }

    static func screens(_ targets: [(id: UInt32, display: CGDirectDisplayID)], _ send: @escaping (UInt32, Data) async -> Void) async {
        guard !targets.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == me }
        for t in targets {
            if Task.isCancelled { return }
            if let hit = cache[t.id], Date().timeIntervalSince(hit.at) < WindowThumbnail.cacheFresh { await send(t.id, hit.jpeg); continue }
            guard let d = content.displays.first(where: { $0.displayID == t.display }),
                  let px = WindowThumbnail.pixelSize(window: CGDisplayBounds(t.display).size) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(px.width)
            config.height = Int(px.height)
            config.showsCursor = false
            config.scalesToFit = true
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingApplications: mine, exceptingWindows: []),
                                                                          configuration: config),
                  let jpeg = await Task.detached(priority: .utility, operation: { encode(image) }).value,
                  WindowThumbnail.isAcceptable(jpeg) else { continue }
            cache[t.id] = (Date(), jpeg)
            await send(t.id, jpeg)
        }
    }

    private static func jpeg(for w: SCWindow) async -> Data? {
        if let hit = cache[w.windowID], Date().timeIntervalSince(hit.at) < WindowThumbnail.cacheFresh { return hit.jpeg }
        guard let px = WindowThumbnail.pixelSize(window: w.frame.size) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(px.width)
        config.height = Int(px.height)
        config.showsCursor = false
        config.scalesToFit = true
        config.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                      configuration: config),
              let jpeg = await Task.detached(priority: .utility, operation: { encode(image) }).value,
              WindowThumbnail.isAcceptable(jpeg) else { return nil }
        cache[w.windowID] = (Date(), jpeg)
        return jpeg
    }

    nonisolated private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: WindowThumbnail.quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
