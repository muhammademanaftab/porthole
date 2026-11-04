import AppKit
import PortholeCore
import VirtualDisplayBridge

@MainActor
final class Stage {
    private var display: CGVirtualDisplay?
    private(set) var displayID: CGDirectDisplayID?
    private var parked: [UInt32: (pid: pid_t, home: CGPoint)] = [:]
    private var nextSlot = 0
    private var emptySince: Date?
    private var idleTimer: Timer?
    private let idleSeconds = ProcessInfo.processInfo.environment["PORTHOLE_STAGE_IDLE_SECS"].flatMap(Double.init).map { max($0, 5) } ?? StageLayout.idleSeconds

    var bounds: CGRect? { displayID.map { CGDisplayBounds($0) } }
    var isReady: Bool { displayID != nil }

    func ensure(screenPoints: CGSize?) async {
        emptySince = nil
        guard display == nil else { return }
        Power.keepAwake()
        for attempt in 1...3 {
            await createOnce(screenPoints: screenPoints)
            if isReady { startIdleTimer(); return }
            Power.wakeDisplay()
            Log.info("stage: attempt \(attempt) failed")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        Log.info("stage: unavailable, sharing windows where they are")
    }

    func becameEmpty() {
        guard display != nil, emptySince == nil else { return }
        emptySince = Date()
        Log.info("stage: empty, released after \(Int(idleSeconds)) s unless a window is shared again")
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if StageLayout.shouldRelease(emptySince: self.emptySince?.timeIntervalSince1970, now: Date().timeIntervalSince1970, idle: self.idleSeconds) { self.release() }
            }
        }
    }

    func release() {
        guard display != nil else { return }
        unparkAll()
        idleTimer?.invalidate(); idleTimer = nil
        display = nil
        displayID = nil
        emptySince = nil
        Power.allowSleep()
        Log.info("stage: released")
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

    private func createOnce(screenPoints: CGSize?) async {
        let others = onlineDisplays().map { CGDisplayBounds($0) }
        let mode = StageLayout.viewerMode(screenPoints: screenPoints)
        guard let (v, id) = await makeDisplay(name: "Porthole Stage", serial: 1, pixels: mode.pixels,
                                              modes: [mode.pixels, mode.points]) else { return }
        display = v
        displayID = id
        configure(id, besides: others)
        for _ in 0..<20 where !isHiDPI(id) { try? await Task.sleep(nanoseconds: 100_000_000) }
        Log.info("stage ready for a \(Int(mode.points.width))x\(Int(mode.points.height)) viewer: display \(id) at \(CGDisplayBounds(id)), scale \(scale(of: id)), main \(CGDisplayIsMain(id) != 0)")
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

    static let fullscreenPolicy = FullscreenPolicy(environment: ProcessInfo.processInfo.environment)

    func leaveFullscreen(_ id: UInt32) async {
        guard let live = LiveWindow.lookup(id) else { return }
        guard let w = AXWindows.window(id: id, pid: live.pid) else {
            Log.info("fullscreen: window \(id) of pid \(live.pid) has no accessibility element")
            return
        }
        guard Self.fullscreenPolicy.shouldExit(isFullscreen: AXWindows.isFullscreen(w) == true) else { return }
        guard AXWindows.setFullscreen(w, false) else { Log.info("fullscreen: could not take window \(id) out of full screen"); return }
        let deadline = Date().addingTimeInterval(FullscreenPolicy.exitTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if FullscreenPolicy.exitDone(stillFullscreen: AXWindows.isFullscreen(w), before: live.bounds, now: LiveWindow.lookup(id)?.bounds) { break }
        }
        try? await Task.sleep(nanoseconds: UInt64(FullscreenPolicy.settleSeconds * 1_000_000_000))
        Log.info("fullscreen: window \(id) left full screen, now \(LiveWindow.lookup(id)?.bounds ?? .zero)")
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
