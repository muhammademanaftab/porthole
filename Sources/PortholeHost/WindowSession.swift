import AppKit
import CoreMedia
import LiveKit
import PortholeCore
import ScreenCaptureKit

final class WindowSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: UInt32
    private(set) var track: LocalVideoTrack!
    private(set) var publication: LocalTrackPublication?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "porthole.capture", qos: .userInteractive)
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameAt = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var pixelSize = CGSize.zero
    var onClosed: (() -> Void)?

    static let maxPixels = CGSize(width: 3840, height: 2400)

    private var capturer: BufferCapturer { track.capturer as! BufferCapturer }

    init(windowID: UInt32) {
        self.windowID = windowID
        super.init()
    }

    static func pixelSize(points: CGSize, scale: CGFloat) -> CGSize {
        var w = points.width * scale, h = points.height * scale
        let f = min(1, maxPixels.width / w, maxPixels.height / h)
        w = (w * f).rounded(.down); h = (h * f).rounded(.down)
        return CGSize(width: max(2, Int(w) & ~1), height: max(2, Int(h) & ~1))
    }

    func start(in room: Room) async throws {
        guard let window = try await WindowCatalog.window(id: windowID) else {
            throw NSError(domain: "Porthole", code: 2, userInfo: [NSLocalizedDescriptionKey: "Window \(windowID) is gone"])
        }
        let scale = LiveWindow.lookup(windowID)?.scale ?? 2
        pixelSize = Self.pixelSize(points: window.frame.size, scale: scale)
        track = await LocalVideoTrack.createBufferTrack(
            name: Message.trackName(for: windowID), source: .screenShareVideo,
            options: BufferCaptureOptions(dimensions: Dimensions(width: Int32(pixelSize.width), height: Int32(pixelSize.height)), fps: 60))

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let s = SCStream(filter: filter, configuration: makeConfig(), delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s

        let opts = VideoPublishOptions(
            name: Message.trackName(for: windowID),
            screenShareEncoding: VideoEncoding(maxBitrate: 15_000_000, maxFps: 60),
            simulcast: false,
            preferredCodec: .h264,
            degradationPreference: .maintainResolution)
        publication = try await room.localParticipant.publish(videoTrack: track, options: opts)
        startTimer()
    }

    private func makeConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(pixelSize.width)
        c.height = Int(pixelSize.height)
        c.scalesToFit = true
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
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
        for delay in [0.15, 0.4, 0.8] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.followSize() }
        }
    }

    private func followSize() {
        guard let live = LiveWindow.lookup(windowID) else { return }
        let want = Self.pixelSize(points: live.bounds.size, scale: live.scale)
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
        if Date().timeIntervalSince(lastFrameAt) > 1.0, let buf = lastBuffer {
            capturer.capture(buf)
            lastFrameAt = Date()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = sampleBuffer.imageBuffer else { return }
        lastBuffer = pb
        lastFrameAt = Date()
        capturer.capture(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture of \(windowID) stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { self.onClosed?() }
    }

    func stop(in room: Room) async {
        timer?.cancel(); timer = nil
        try? await stream?.stopCapture()
        stream = nil
        if let publication { try? await room.localParticipant.unpublish(publication: publication) }
        publication = nil
    }
}
