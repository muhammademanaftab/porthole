import AVFoundation
import CoreMedia
import LiveKit
import PortholeCore
import ScreenCaptureKit

final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pcm = sampleBuffer.toAVAudioPCMBuffer() else { return }
        AudioManager.shared.mixer.capture(appAudio: pcm)
        lock.lock(); let first = !heard; heard = true; lock.unlock()
        if first { Log.info("audio: first buffer, \(pcm.format.sampleRate) Hz, \(pcm.format.channelCount) ch") }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("audio capture stopped: \(error.localizedDescription)")
    }

    func rearm() { lock.lock(); heard = false; lock.unlock() }
}

@MainActor
final class AppAudio {
    private var apps = SharedUse<Int32, UInt32>()
    private var running: Set<Int32>?
    private var stream: SCStream?
    private var track: LocalAudioTrack?
    private var publication: LocalTrackPublication?
    private let tap = AudioTap()
    private let queue = DispatchQueue(label: "porthole.audio", qos: .userInteractive)
    private var chain: Task<Void, Never>?

    static func prepare() {
        do { try AudioManager.shared.setManualRenderingMode(true) } catch {
            Log.info("audio: manual rendering mode failed: \(error.localizedDescription)")
        }
    }

    var isLive: Bool { publication != nil }

    func settled() async { await chain?.value }

    func add(window: UInt32, pid: Int32, in room: Room) async {
        if apps.add(window, to: pid) { await apply(in: room) } else { await chain?.value }
    }

    func remove(window: UInt32, in room: Room) async {
        if apps.remove(window) { await apply(in: room) }
    }

    func removeAll(in room: Room) async {
        apps.removeAll()
        await apply(in: room)
    }

    private func apply(in room: Room) async {
        let prev = chain
        let task = Task { await prev?.value; await self.reconcile(in: room) }
        chain = task
        await task.value
    }

    private func reconcile(in room: Room) async {
        switch AudioMixStep.next(running: running, want: apps.keys) {
        case .none: break
        case .start(let pids): await start(pids, in: room)
        case .update(let pids): await update(pids)
        case .stop: await stop(in: room)
        }
    }

    private func filter(for pids: Set<Int32>) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "Porthole", code: 3, userInfo: [NSLocalizedDescriptionKey: "No display to anchor audio capture"])
        }
        let picked = content.applications.filter { pids.contains($0.processID) }
        return SCContentFilter(display: display, including: picked, exceptingWindows: [])
    }

    private func config() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.capturesAudio = true
        c.excludesCurrentProcessAudio = true
        c.sampleRate = AudioFormat.sampleRate
        c.channelCount = AudioFormat.channels
        c.width = 2
        c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        c.queueDepth = 3
        c.showsCursor = false
        return c
    }

    private func start(_ pids: Set<Int32>, in room: Room) async {
        do {
            let t = await LocalAudioTrack.createTrack(name: Message.audioTrackName, options: .noProcessing)
            let opts = AudioPublishOptions(name: Message.audioTrackName, encoding: AudioEncoding(maxBitrate: AudioFormat.maxBitrate),
                                           dtx: false, red: false)
            publication = try await room.localParticipant.publish(audioTrack: t, options: opts)
            track = t
            tap.rearm()
            let s = SCStream(filter: try await filter(for: pids), configuration: config(), delegate: tap)
            try s.addStreamOutput(tap, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(tap, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            running = pids
            Log.info("audio: capturing apps \(pids.sorted())")
        } catch {
            Log.info("audio: start failed: \(error.localizedDescription)")
            await teardown(in: room)
        }
    }

    private func update(_ pids: Set<Int32>) async {
        do {
            try await stream?.updateContentFilter(try await filter(for: pids))
            running = pids
            Log.info("audio: capturing apps \(pids.sorted())")
        } catch {
            Log.info("audio: filter update failed: \(error.localizedDescription)")
        }
    }

    private func stop(in room: Room) async {
        await teardown(in: room)
        Log.info("audio: stopped")
    }

    private func teardown(in room: Room) async {
        try? await stream?.stopCapture()
        stream = nil
        if let publication { try? await room.localParticipant.unpublish(publication: publication) }
        publication = nil
        track = nil
        running = nil
    }
}
