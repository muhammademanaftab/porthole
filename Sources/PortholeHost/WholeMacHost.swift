import AppKit
import PortholeCore

enum ScreenCatalog {
    static func active() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func online() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    static func isActive(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0 }

    static func scale(_ id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    static func facts(stage: CGDirectDisplayID?) -> [ScreenFacts] {
        online().filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay || $0 == stage }.map { id in
            ScreenFacts(id: id, frame: CGDisplayBounds(id), scale: scale(id), isMain: CGDisplayIsMain(id) != 0,
                        isBuiltin: CGDisplayIsBuiltin(id) != 0, vendor: CGDisplayVendorNumber(id), isStage: id == stage)
        }
    }

    static func describe(_ facts: [ScreenFacts]) -> String {
        facts.map { f in
            "\(f.id)\(f.isStage ? " stage" : "")\(f.isMain ? " main" : "")\(f.isBuiltin ? " builtin" : "") vendor \(String(f.vendor, radix: 16)) \(Int(f.frame.width))x\(Int(f.frame.height))@\(f.scale)"
        }.joined(separator: "; ")
    }
}

extension Stage {
    func matchScreens() {
        guard let stage = displayID else { return }
        let others = ScreenCatalog.online().filter { $0 != stage && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        guard !others.isEmpty else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for id in others { CGConfigureDisplayMirrorOfDisplay(cfg, id, stage) }
        if CGCompleteDisplayConfiguration(cfg, .forSession) == .success {
            matched = others
            Log.info("stage: screen match, displays \(others) mirror the Stage \(stage)", .stage)
        } else {
            Log.info("stage: screen match failed", .stage)
        }
    }

    func unmatchScreens() {
        guard !matched.isEmpty else { return }
        let ids = matched
        matched = []
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for id in ids { CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay) }
        let ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        Log.info(ok ? "stage: screen match ended for displays \(ids)" : "stage: could not end the screen match", .stage)
    }
}

@MainActor
final class WholeMacPrompt {
    private var panels: [String: NSPanel] = [:]

    func ask(key: String, viewer: String, host: String, answer: @escaping (Bool) -> Void) {
        close(key)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "Whole Mac"
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let text = NSTextField(wrappingLabelWithString: "\(viewer) wants to see and control this whole Mac (\(host)).")
        text.preferredMaxLayoutWidth = 320
        let deny = ClosureButton(title: "Don't Allow") { [weak self] in answer(false); self?.close(key) }
        let allow = ClosureButton(title: "Allow") { [weak self] in answer(true); self?.close(key) }
        allow.keyEquivalent = "\r"
        let buttons = NSStackView(views: [deny, allow])
        let stack = NSStackView(views: [text, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        p.contentView = stack
        if let s = NSScreen.main?.visibleFrame {
            p.setFrameTopLeftPoint(NSPoint(x: s.maxX - p.frame.width - 12, y: s.maxY - 8))
        }
        Power.wakeDisplay()
        p.orderFrontRegardless()
        panels[key] = p
    }

    func close(_ key: String) {
        panels.removeValue(forKey: key)?.close()
    }
}

final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler() }
}
