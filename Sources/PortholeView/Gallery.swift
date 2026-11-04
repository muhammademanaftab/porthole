import AppKit
import PortholeCore

@MainActor
enum Gallery {
    static var keep: [NSWindow] = []

    static let hosts: [DiscoveredHost] = [
        DiscoveredHost(name: "Studio Mac mini", tailscaleIP: "100.70.1.20", lanHost: "studio.local", status: .online, viaBonjour: true, viaTailscale: true),
        DiscoveredHost(name: "Office iMac", tailscaleIP: "100.70.1.31", status: .online, viaTailscale: true),
        DiscoveredHost(name: "Old MacBook Pro", lanHost: "old-mbp.local", status: .older, viaBonjour: true),
        DiscoveredHost(name: "MacBook Air", lanHost: "air.local", status: .notFound, saved: true),
    ]

    static let windows: [WindowInfo] = [
        WindowInfo(id: 1, app: "Safari", title: "Porthole — share single windows", bundle: "com.apple.Safari", w: 1440, h: 900),
        WindowInfo(id: 2, app: "Notes", title: "Groceries", bundle: "com.apple.Notes", w: 900, h: 640),
        WindowInfo(id: 3, app: "Terminal", title: "sam — zsh — 120×36", bundle: "com.apple.Terminal", w: 980, h: 620),
        WindowInfo(id: 4, app: "TextEdit", title: "Untitled", bundle: "com.apple.TextEdit", w: 700, h: 820),
        WindowInfo(id: 5, app: "Finder", title: "", bundle: "com.apple.finder", w: 1100, h: 700),
    ]

    static func show(_ screen: String) {
        switch screen {
        case "code":
            let w = connect()
            w.ask("Studio Mac mini is showing a pairing code for this Mac. Type it here; after that this Mac can view it without a password.")
        case "picker", "loading", "empty", "locked", "nomatch":
            picker(screen)
        case "settings":
            let w = ViewerSettingsWindow()
            keep.append(w)
            w.present(tab: 2)
        default:
            _ = connect()
        }
        NSApp.activate()
    }

    private static func connect() -> ConnectWindow {
        let w = ConnectWindow()
        w.show(hosts, scanning: false, preferTailscale: true, hasAccess: { $0.name == "Studio Mac mini" ? false : true })
        w.onCancel = { NSApp.terminate(nil) }
        w.makeKeyAndOrderFront(nil)
        keep.append(w)
        return w
    }

    private static func picker(_ screen: String) {
        let w = PickerWindow(hostName: "Studio Mac mini", onPick: { _ in }, refresh: {})
        switch screen {
        case "loading": break
        case "empty": w.show([])
        case "locked": w.showError(LockNotice.list)
        default:
            w.show(windows)
            for (i, info) in windows.enumerated() { if let jpeg = thumbnail(info, hue: CGFloat(i) / CGFloat(windows.count)) { w.setThumb(info.id, jpeg: jpeg) } }
            if screen == "nomatch" { w.search(for: "spreadsheet") }
        }
        w.makeKeyAndOrderFront(nil)
        keep.append(w)
    }

    static func thumbnail(_ info: WindowInfo, hue: CGFloat) -> Data? {
        guard let px = WindowThumbnail.pixelSize(window: CGSize(width: info.w, height: info.h)),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = CGRect(origin: .zero, size: px)
        NSColor(white: 0.97, alpha: 1).setFill()
        r.fill()
        let bar = CGRect(x: 0, y: r.height - 22, width: r.width, height: 22)
        NSColor(white: 0.9, alpha: 1).setFill()
        bar.fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: CGRect(x: 8 + CGFloat(i) * 14, y: r.height - 15, width: 8, height: 8)).fill()
        }
        let accent = NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1)
        accent.setFill()
        CGRect(x: 0, y: 0, width: r.width * 0.26, height: r.height - 22).fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        for row in 0..<8 {
            let y = r.height - 44 - CGFloat(row) * 22
            guard y > 8 else { break }
            CGRect(x: r.width * 0.31, y: y, width: r.width * (row % 3 == 0 ? 0.5 : 0.62), height: 7).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
