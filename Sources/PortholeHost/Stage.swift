import AppKit
import PortholeCore
import VirtualDisplayBridge

@MainActor
final class Stage {
    private var display: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID?
    private var parked: [UInt32: (pid: pid_t, home: CGPoint)] = [:]
    private var nextSlot = 0

    var bounds: CGRect? { displayID.map { CGDisplayBounds($0) } }
    var isReady: Bool { displayID != nil }

    func start() async {
        for attempt in 1... {
            await createOnce()
            if isReady { return }
            Power.wakeDisplay()
            Log.info("stage: attempt \(attempt) failed, retrying in 5 s")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func createOnce() async {
        let others = onlineDisplays().map { CGDisplayBounds($0) }
        let d = CGVirtualDisplayDescriptor()
        d.queue = .main
        d.name = "Porthole Stage"
        d.maxPixelsWide = UInt32(StageLayout.pixels.width)
        d.maxPixelsHigh = UInt32(StageLayout.pixels.height)
        d.sizeInMillimeters = StageLayout.sizeInMillimeters
        d.vendorID = 0x504F
        d.productID = 0x5448
        d.serialNum = 1
        d.terminationHandler = { _, _ in Log.info("stage display was terminated") }
        guard let v = CGVirtualDisplay(descriptor: d) else { Log.info("stage: could not create the virtual display"); return }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1
        s.modes = [
            CGVirtualDisplayMode(width: UInt(StageLayout.pixels.width), height: UInt(StageLayout.pixels.height), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt(StageLayout.points.width), height: UInt(StageLayout.points.height), refreshRate: 60),
        ]
        guard v.apply(s) else { Log.info("stage: applySettings failed, sharing windows in place"); return }
        let id = v.displayID
        for _ in 0..<30 where !onlineDisplays().contains(id) { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard onlineDisplays().contains(id) else { Log.info("stage: display \(id) never came online"); return }
        display = v
        displayID = id
        configure(id, besides: others)
        for _ in 0..<20 where !isHiDPI(id) { try? await Task.sleep(nanoseconds: 100_000_000) }
        Log.info("stage ready: display \(id) at \(CGDisplayBounds(id)), \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) px, scale \(scale(of: id))")
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    private func configure(_ id: CGDirectDisplayID, besides others: [CGRect]) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        let best = StageLayout.bestMode(modes.map { ($0.width, $0.height, $0.pixelWidth, $0.pixelHeight) }).map { modes[$0] }
        Log.info("stage modes: \(modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth)" }.joined(separator: " ")); picked \(best.map { "\($0.width)x\($0.height)" } ?? "none")")
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        if let best { CGConfigureDisplayWithDisplayMode(cfg, id, best, nil) }
        let origin = StageLayout.origin(besides: others)
        CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
        CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
        if CGCompleteDisplayConfiguration(cfg, .forSession) != .success { Log.info("stage: display configuration failed") }
    }

    private func isHiDPI(_ id: CGDirectDisplayID) -> Bool { scale(of: id) >= 2 }

    private func scale(of id: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }?.backingScaleFactor ?? 1
    }

    func park(_ id: UInt32) async {
        guard let stage = bounds, parked[id] == nil, let live = LiveWindow.lookup(id),
              let w = AXWindows.window(id: id, pid: live.pid), let home = AXWindows.position(w) else { return }
        if stage.intersects(live.bounds) { return }
        let target = StageLayout.slot(nextSlot, stage: stage, window: live.bounds.size)
        nextSlot += 1
        guard AXWindows.setPosition(w, target) else { Log.info("stage: could not move window \(id)"); return }
        parked[id] = (live.pid, home)
        for _ in 0..<20 {
            if let now = LiveWindow.lookup(id), stage.intersects(now.bounds), now.scale >= 2 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        Log.info("stage: parked window \(id) at \(target), scale \(LiveWindow.lookup(id)?.scale ?? 0)")
    }

    func unpark(_ id: UInt32) {
        guard let entry = parked.removeValue(forKey: id) else { return }
        if let w = AXWindows.window(id: id, pid: entry.pid) { AXWindows.setPosition(w, entry.home) }
        if parked.isEmpty { nextSlot = 0 }
    }

    func unparkAll() {
        for id in Array(parked.keys) { unpark(id) }
    }
}
