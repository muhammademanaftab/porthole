import AppKit
import CoreMedia
import LiveKit
import PortholeCore
import ScreenCaptureKit

final class WindowSession: NSObject, SCStreamOutput, SCStreamDelegate, TrackDelegate, @unchecked Sendable {
    let windowID: UInt32
    let prefs: StreamPrefs
    private(set) var track: LocalVideoTrack!
    private(set) var publication: LocalTrackPublication?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "porthole.capture", qos: .userInteractive)
    private var lastBuffer: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var padTimer: DispatchSourceTimer?
    private var pacer: FramePacer
    private var ladder = ScaleLadder(native: 2)
    private var lastInputAt: Double?
    private var submitted = 0
    private var captured = 0
    private var lastCounters: EncoderCounters?
    private var loggedEncoder = false
    private var pixelSize = CGSize.zero
    private(set) var pid: Int32?
    var onClosed: (() -> Void)?

    private var capturer: BufferCapturer { track.capturer as! BufferCapturer }

    init(windowID: UInt32, prefs: StreamPrefs = .standard) {
        self.windowID = windowID
        self.prefs = prefs
        var pc = FramePacer.Config()
        pc.padHz = Double(prefs.fps)
        pacer = FramePacer(config: pc)
        super.init()
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private static let logSamples = ProcessInfo.processInfo.environment["PORTHOLE_ENCODE_LOG"] == "1"

    static func pixelSize(points: CGSize, scale: CGFloat) -> CGSize {
        capturePixelSize(points: points, scale: scale)
    }

    func start(in room: Room) async throws {
        guard let window = try await WindowCatalog.window(id: windowID) else {
            throw NSError(domain: "Porthole", code: 2, userInfo: [NSLocalizedDescriptionKey: "Window \(windowID) is gone"])
        }
        pid = window.owningApplication?.processID
        let scale = LiveWindow.lookup(windowID)?.scale ?? 2
        var lc = ScaleLadder.Config()
        if let ms = ProcessInfo.processInfo.environment["PORTHOLE_ENCODE_BUDGET_MS"].flatMap(Double.init), ms > 0 { lc.budgetMs = ms; lc.upBudgetMs = ms * 0.7 }
        ladder = ScaleLadder(top: prefs.level, native: Double(scale), config: lc)
        pixelSize = Self.pixelSize(points: window.frame.size, scale: min(scale, CGFloat(ladder.level)))
        track = await LocalVideoTrack.createBufferTrack(
            name: Message.trackName(for: windowID), source: .screenShareVideo,
            options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(pixelSize.width), height: Int32(pixelSize.height)), fps: prefs.fps),
            reportStatistics: true)
        track.add(delegate: self)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let s = SCStream(filter: filter, configuration: makeConfig(), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s

        let opts = VideoPublishOptions(
            name: Message.trackName(for: windowID),
            screenShareEncoding: VideoEncoding(maxBitrate: prefs.bitrate, maxFps: prefs.fps),
            simulcast: false,
            preferredCodec: .h265,
            preferredBackupCodec: .h264,
            degradationPreference: .maintainResolution)
        publication = try await room.localParticipant.publish(videoTrack: track, options: opts)
        startTimer()
    }

    private func makeConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(pixelSize.width)
        c.height = Int(pixelSize.height)
        c.scalesToFit = true
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(prefs.fps))
        c.queueDepth = 5
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { c.includeChildWindows = true }
        return c
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func followSizeSoon() {
        for delay in CapturePacing.followSizeDelays {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.followSize() }
        }
    }

    private func followSize() {
        guard let live = LiveWindow.lookup(windowID) else { return }
        let want = Self.pixelSize(points: live.bounds.size, scale: min(live.scale, CGFloat(ladder.level)))
        guard want != pixelSize else { return }
        pixelSize = want
        stream?.updateConfiguration(makeConfig()) { err in
            if let err { Log.info("resize capture failed: \(err.localizedDescription)") }
        }
    }

    private func tick() {
        guard LiveWindow.lookup(windowID) != nil else {
            DispatchQueue.main.async { self.onClosed?() }
            return
        }
        followSize()
        if pacer.idleTick(at: Self.now) != nil { resubmit() }
    }

    private func resubmit() {
        guard let buf = lastBuffer else { return }
        submitted += 1
        capturer.capture(buf)
    }

    func noteInput() {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Self.now
            lastInputAt = now
            pacer.input(at: now)
            ensurePadTimer()
        }
    }

    private func ensurePadTimer() {
        guard padTimer == nil, pacer.isPadding(at: Self.now) else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = pacer.interval
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.padTick() }
        t.resume()
        padTimer = t
    }

    private func padTick() {
        let now = Self.now
        if pacer.padTick(at: now) != nil { resubmit() }
        if !pacer.isPadding(at: now) { padTimer?.cancel(); padTimer = nil }
    }

    func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics: [VideoCodec: TrackStatistics]) {
        let outbound = ([statistics] + simulcastStatistics.values).flatMap(\.outboundRtpStream)
        let frames = outbound.compactMap(\.framesEncoded).reduce(0) { $0 + Int($1) }
        let seconds = outbound.compactMap(\.totalEncodeTime).reduce(0, +)
        let codecs = ([statistics] + simulcastStatistics.values).flatMap(\.codec).compactMap(\.mimeType)
        let encoders = Set(outbound.compactMap(\.encoderImplementation)).sorted()
        queue.async { [weak self] in self?.encoderStats(frames: frames, seconds: seconds, codecs: codecs, encoders: encoders) }
    }

    private func encoderStats(frames: Int, seconds: Double, codecs: [String], encoders: [String]) {
        let now = Self.now
        let counters = EncoderCounters(at: now, framesEncoded: frames, encodeSeconds: seconds, submitted: submitted, captured: captured)
        defer { lastCounters = counters }
        if !loggedEncoder, frames > 0 {
            loggedEncoder = true
            Log.info("window \(windowID): encoding \(Set(codecs).sorted().joined(separator: ", ")) with \(encoders.joined(separator: ", ")) at \(Int(pixelSize.width))x\(Int(pixelSize.height)), \(prefs.fps) fps, \(prefs.bitrate / 1000) kbps max")
        }
        guard let last = lastCounters, let sample = EncoderSample(from: last, to: counters) else { return }
        if Self.logSamples {
            Log.info(String(format: "window %u: encode %.1f ms, %.0f encoded / %.0f submitted / %.0f captured fps at scale %.2f",
                            windowID, sample.encodeMs ?? 0, sample.encodedFps, sample.submittedFps, sample.capturedFps, ladder.level))
        }
        let before = ladder.level
        guard let level = ladder.observe(sample, now: now, lastInputAt: lastInputAt) else { return }
        Log.info(String(format: "window %u: capture scale %.2f -> %.2f (encode %.1f ms, %.0f encoded / %.0f submitted / %.0f captured fps)",
                        windowID, before, level, sample.encodeMs ?? 0, sample.encodedFps, sample.submittedFps, sample.capturedFps))
        followSize()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              CapturePacing.acceptsFrame(status: attachments.first?[.status] as? Int),
              let pb = sampleBuffer.imageBuffer else { return }
        lastBuffer = pb
        captured += 1
        submitted += 1
        pacer.realFrame(at: Self.now)
        capturer.capture(pb)
        ensurePadTimer()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture of \(windowID) stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { self.onClosed?() }
    }

    func stop(in room: Room) async {
        timer?.cancel(); timer = nil
        queue.sync { padTimer?.cancel(); padTimer = nil }
        try? await stream?.stopCapture()
        stream = nil
        if let publication { try? await room.localParticipant.unpublish(publication: publication) }
        publication = nil
    }
}
