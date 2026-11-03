import AVFoundation
import Foundation
import LiveKit
import PortholeCore

final class FrameCounter: NSObject, VideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var size = CGSize.zero
    var isAdaptiveStreamEnabled: Bool { false }
    var adaptiveStreamSize: CGSize { .zero }
    func set(size: CGSize) {}
    func render(frame: VideoFrame) {
        lock.lock(); count += 1
        size = CGSize(width: Int(frame.dimensions.width), height: Int(frame.dimensions.height)); lock.unlock()
    }
    func snapshot() -> (Int, CGSize) { lock.lock(); defer { lock.unlock() }; return (count, size) }
}

final class AudioMeter: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var frames = 0
    private var peak: Float = 0
    private var rate = 0.0
    private var channels = 0
    func render(pcmBuffer: AVAudioPCMBuffer) {
        let n = Int(pcmBuffer.frameLength) * Int(pcmBuffer.format.channelCount)
        var p: Float = 0
        if let f = pcmBuffer.floatChannelData {
            for c in 0..<Int(pcmBuffer.format.channelCount) { for i in 0..<Int(pcmBuffer.frameLength) { p = max(p, abs(f[c][i])) } }
        } else if let d = pcmBuffer.int16ChannelData, pcmBuffer.format.isInterleaved {
            for i in 0..<n { p = max(p, abs(Float(d[0][i]) / 32768)) }
        } else if let d = pcmBuffer.int16ChannelData {
            for c in 0..<Int(pcmBuffer.format.channelCount) { for i in 0..<Int(pcmBuffer.frameLength) { p = max(p, abs(Float(d[c][i]) / 32768)) } }
        }
        lock.lock()
        buffers += 1; frames += Int(pcmBuffer.frameLength); peak = max(peak, p)
        rate = pcmBuffer.format.sampleRate; channels = Int(pcmBuffer.format.channelCount)
        lock.unlock()
    }
    func snapshot() -> (buffers: Int, frames: Int, peak: Float, rate: Double, channels: Int) {
        lock.lock(); defer { lock.unlock() }; return (buffers, frames, peak, rate, channels)
    }
}

final class Probe: NSObject, RoomDelegate, @unchecked Sendable {
    let room = Room()
    var inbox: [Message] = []
    let lock = NSLock()

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard let m = Message.decode(data) else { return }
        lock.lock(); inbox.append(m); lock.unlock()
    }

    func wait(for kind: Message.Kind, timeout: TimeInterval = 10) async -> Message? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            lock.lock(); let hit = inbox.firstIndex { $0.t == kind || $0.t == .error }.map { inbox.remove(at: $0) }; lock.unlock()
            if let hit { return hit }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func send(_ m: Message) async throws {
        try await room.localParticipant.publish(data: m.encoded(), options: DataPublishOptions(
            destinationIdentities: [Participant.Identity(from: "host")], topic: portholeTopic, reliable: true))
    }
}

func fail(_ s: String) -> Never { print("FAIL  \(s)"); exit(1) }

let args = CommandLine.arguments
let titleMatch = args.count > 1 ? args[1] : "porthole-probe"
let env0 = ProcessInfo.processInfo.environment
let targetApp = env0["PORTHOLE_APP"] ?? "TextEdit"
let audioCheck = env0["PORTHOLE_AUDIO"] != nil
let typed = args.count > 2 ? args[2] : "hello from porthole"
let env = ProcessInfo.processInfo.environment
let hostAddress = env["PORTHOLE_HOST"] ?? "127.0.0.1"
let cfgURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Porthole/config.json")
guard let pw = env["PORTHOLE_PW"] ?? ((try? JSONSerialization.jsonObject(with: Data(contentsOf: cfgURL))) as? [String: Any])?["password"] as? String
else { fail("no host config") }

let (data, _) = try await URLSession.shared.data(from: tokenURL(hostAddress: hostAddress, password: pw, name: "probe")!)
guard let tok = try JSONSerialization.jsonObject(with: data) as? [String: String], let url = tok["url"], let token = tok["token"] else { fail("token endpoint") }
print("PASS  token issued (\(url))")

let probe = Probe()
probe.room.add(delegate: probe)
final class ClipBox: @unchecked Sendable { let lock = NSLock(); var text: String?
    func set(_ t: String) { lock.lock(); text = t; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return text } }
let fromHost = ClipBox()
try await probe.room.registerTextStreamHandler(for: clipboardTopic) { reader, _ in fromHost.set(try await reader.readAll()) }
try await probe.room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false))
print("PASS  joined LiveKit room")
var hostP: RemoteParticipant?
for _ in 0..<50 { hostP = probe.room.remoteParticipants[Participant.Identity(from: "host")]; if hostP != nil { break }; try await Task.sleep(nanoseconds: 100_000_000) }
guard let hostP else { fail("host not in room") }
print("PASS  host is in the room")

var listReply: Message?
for _ in 0..<10 where listReply == nil {
    try await probe.send(Message(.list))
    listReply = await probe.wait(for: .windows, timeout: 1)
}
guard let list = listReply, list.t == .windows else { fail("window list (\(String(describing: probe.inbox)))") }
let windows = list.list ?? []
print("PASS  host listed \(windows.count) windows")
guard let target = windows.first(where: { $0.app == targetApp && $0.title.contains(titleMatch) }) else {
    fail("no \(targetApp) window titled *\(titleMatch)*; got: \(windows.map { "\($0.app): \($0.title)" })")
}
print("PASS  found \(target.app) — \(target.title) (\(Int(target.w))×\(Int(target.h)) pt)")

var open = Message(.open); open.win = target.id
let t0 = Date()
var openReply: Message?
for _ in 0..<5 where openReply == nil {
    try await probe.send(open)
    openReply = await probe.wait(for: .opened, timeout: 3)
}
guard let opened = openReply, opened.t == .opened, let trackName = opened.track else {
    fail("open reply: \(String(describing: probe.inbox))")
}
print("PASS  host opened window, track \(trackName)")

var pub: RemoteTrackPublication?
for _ in 0..<100 {
    pub = hostP.trackPublications.values.first { $0.name == trackName } as? RemoteTrackPublication
    if pub != nil { break }
    try await Task.sleep(nanoseconds: 50_000_000)
}
guard let pub else { fail("track never published") }
try await pub.set(subscribed: true)
var track: VideoTrack?
for _ in 0..<100 { track = pub.track as? VideoTrack; if track != nil { break }; try await Task.sleep(nanoseconds: 50_000_000) }
guard let track else { fail("track never subscribed") }
let counter = FrameCounter()
track.add(videoRenderer: counter)
var firstFrameAt: Date?
for _ in 0..<200 { if counter.snapshot().0 > 0 { firstFrameAt = Date(); break }; try await Task.sleep(nanoseconds: 25_000_000) }
guard let firstFrameAt else { fail("no video frames arrived") }
print(String(format: "PASS  first frame %.2f s after open", firstFrameAt.timeIntervalSince(t0)))

if audioCheck {
    guard let audioName = opened.audio else { fail("opened reply has no audio track") }
    print("PASS  opened reply names audio track \(audioName)")
    var apub: RemoteTrackPublication?
    for _ in 0..<100 {
        apub = hostP.trackPublications.values.first { $0.name == audioName } as? RemoteTrackPublication
        if apub != nil { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let apub else { fail("audio track never published") }
    print("PASS  audio track published (\(apub.kind), source \(apub.source))")
    try await apub.set(subscribed: true)
    var atrack: RemoteAudioTrack?
    for _ in 0..<100 { atrack = apub.track as? RemoteAudioTrack; if atrack != nil { break }; try await Task.sleep(nanoseconds: 50_000_000) }
    guard let atrack else { fail("audio track never subscribed") }
    let meter = AudioMeter()
    atrack.add(audioRenderer: meter)
    try await Task.sleep(nanoseconds: 5_000_000_000)
    let a = meter.snapshot()
    print(a.buffers > 0 ? "PASS  \(a.buffers) audio buffers, \(a.frames) frames in 5 s at \(Int(a.rate)) Hz × \(a.channels) ch" : "FAIL  no audio buffers arrived")
    print(a.peak > 0.01 ? String(format: "PASS  audio peak level %.3f (sound is coming through)", a.peak) : String(format: "FAIL  audio is silent (peak %.4f)", a.peak))
    var close = Message(.close); close.win = target.id
    try await probe.send(close)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let gone = !hostP.trackPublications.values.contains { $0.name == audioName }
    print(gone ? "PASS  audio track unpublished after the last window closed" : "WARN  audio track still published after close (expected while another window of the app is shared)")
    await probe.room.disconnect()
    print("DONE")
    exit(0)
}

var click = Message(.mouse); click.win = target.id; click.x = 0.5; click.y = 0.6; click.btn = 0; click.clicks = 1
click.kind = .down; try await probe.send(click)
click.kind = .up; try await probe.send(click)
try await Task.sleep(nanoseconds: 400_000_000)
var text = Message(.text); text.win = target.id; text.s = typed
try await probe.send(text)
let cmd = Modifiers.command.rawValue
for (code, down, mods) in [(UInt16(49), true, UInt32(0)), (49, false, 0), (7, true, 0), (7, false, 0),
                           (55, true, cmd), (1, true, cmd), (1, false, cmd), (55, false, 0)] {
    var k = Message(.key); k.win = target.id; k.code = code; k.down = down; k.mods = mods
    try await probe.send(k)
}
try await Task.sleep(nanoseconds: 2_500_000_000)
let (n, size) = counter.snapshot()
let secs = Date().timeIntervalSince(firstFrameAt)
print(String(format: "PASS  received %d frames in %.1f s (%.0f fps while typing), %d×%d px", n, secs, Double(n) / secs, Int(size.width), Int(size.height)))
let ratio = size.width / max(target.w, 1)
print(ratio >= 1.9 ? "PASS  Retina capture (\(String(format: "%.2f", ratio))× points)" : "WARN  capture scale \(String(format: "%.2f", ratio))× points")

var resize = Message(.resize); resize.win = target.id; resize.w = target.w + 120; resize.h = target.h + 60
try await probe.send(resize)
try await Task.sleep(nanoseconds: 2_000_000_000)
let (_, size2) = counter.snapshot()
print(size2.width > size.width ? "PASS  resize followed: \(Int(size2.width))×\(Int(size2.height)) px" : "FAIL  resize: still \(Int(size2.width))×\(Int(size2.height)) px")

if let marker = env["PORTHOLE_CLIP_SEND"] {
    _ = try await probe.room.localParticipant.sendText(marker, options: StreamTextOptions(topic: clipboardTopic, destinationIdentities: [Participant.Identity(from: "host")]))
    print("SENT  clipboard text to host: \(marker)")
    try await Task.sleep(nanoseconds: 2_000_000_000)
}
if let expected = env["PORTHOLE_CLIP_EXPECT"] {
    for _ in 0..<100 where fromHost.get() != expected { try await Task.sleep(nanoseconds: 100_000_000) }
    print(fromHost.get() == expected ? "PASS  clipboard from host arrived: \(expected)" : "FAIL  clipboard from host: got \(fromHost.get() ?? "nothing")")
}

var close = Message(.close); close.win = target.id
try await probe.send(close)
try await Task.sleep(nanoseconds: 500_000_000)
await probe.room.disconnect()
print("DONE")
exit(0)
