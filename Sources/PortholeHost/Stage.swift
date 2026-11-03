import AppKit
import PortholeCore
import VirtualDisplayBridge

@MainActor
final class Stage {
    private var display: CGVirtualDisplay?
    private var desktop: CGVirtualDisplay?
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

    private func makeDisplay(name: String, serial: UInt32, pixels: CGSize, modes: [CGSize]) async -> (CGVirtualDisplay, CGDirectDisplayID)? {
        let d = CGVirtualDisplayDescriptor()
        d.queue = .main
        d.name = name
        d.maxPixelsWide = UInt32(pixels.width)
        d.maxPixelsHigh = UInt32(pixels.height)
        d.sizeInMillimeters = CGSize(width: (pixels.width / StageLayout.pixelsPerInch * 25.4).rounded(),
                                     height: (pixels.height / StageLayout.pixelsPerInch * 25.4).rounded())
        d.vendorID = 0x504F
        d.productID = 0x5448
        d.serialNum = serial
        d.terminationHandler = { _, _ in Log.info("\(name) display was terminated") }
        guard let v = CGVirtualDisplay(descriptor: d) else { Log.info("\(name): could not create the virtual display"); return nil }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 1
        s.modes = modes.map { CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: 60) }
        guard v.apply(s) else { Log.info("\(name): applySettings failed"); return nil }
        let id = v.displayID
        for _ in 0..<30 where !onlineDisplays().contains(id) { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard onlineDisplays().contains(id) else { Log.info("\(name): display \(id) never came online"); return nil }
        return (v, id)
    }

    private func createOnce() async {
        let others = onlineDisplays().map { CGDisplayBounds($0) }
        guard let (v, id) = await makeDisplay(name: "Porthole Stage", serial: 1, pixels: StageLayout.pixels,
                                              modes: [StageLayout.pixels, StageLayout.points]) else { return }
        display = v
        displayID = id
        configure(id, besides: others)
        if CGDisplayIsMain(id) != 0 { await addDesktop(beside: id) }
        for _ in 0..<20 where !isHiDPI(id) { try? await Task.sleep(nanoseconds: 100_000_000) }
        Log.info("stage ready: display \(id) at \(CGDisplayBounds(id)), \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) px, scale \(scale(of: id))")
    }

    private func addDesktop(beside stage: CGDirectDisplayID) async {
        let pts = StageLayout.headlessPoints
        let px = CGSize(width: pts.width * 2, height: pts.height * 2)
        guard let (v, id) = await makeDisplay(name: "Porthole Desktop", serial: 2, pixels: px, modes: [px, pts]) else { return }
        desktop = v
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        let mode = StageLayout.headlessMode(modes.map { ($0.width, $0.height, $0.pixelWidth, $0.pixelHeight) }).map { modes[$0] }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        if let mode { CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil) }
        CGConfigureDisplayOrigin(cfg, id, 0, 0)
        let origin = StageLayout.origin(besides: [CGRect(origin: .zero, size: pts)])
        CGConfigureDisplayOrigin(cfg, stage, Int32(origin.x), Int32(origin.y))
        CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
        let ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        Log.info("no monitor attached: added a \(Int(pts.width))x\(Int(pts.height)) Retina desktop as the main screen (\(ok ? "ok" : "failed")); desktop main \(CGDisplayIsMain(id) != 0), stage at \(CGDisplayBounds(stage))")
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
