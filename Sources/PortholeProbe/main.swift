import AVFoundation
import CoreGraphics
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

final class StatsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(at: Date, bytes: UInt64, codec: String, decoder: String, w: UInt, h: UInt)] = []
    func add(_ s: TrackStatistics?) {
        guard let s, let inbound = s.inboundRtpStream.first, let bytes = inbound.bytesReceived else { return }
        let codec = s.codec.first { $0.id == inbound.codecId }?.mimeType ?? s.codec.first?.mimeType ?? "?"
        lock.lock(); defer { lock.unlock() }
        if samples.last?.bytes == bytes { return }
        samples.append((Date(), bytes, codec, inbound.decoderImplementation ?? "?", inbound.frameWidth ?? 0, inbound.frameHeight ?? 0))
    }
    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let last = samples.last else { return "no inbound stats" }
        var rates: [String] = []
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.at.timeIntervalSince(a.at)
            if dt > 0 { rates.append(String(format: "%.1f", Double(b.bytes - a.bytes) * 8 / dt / 1_000_000)) }
        }
        return "codec \(last.codec) (decoder \(last.decoder)), \(last.w)×\(last.h), Mbps per second: [\(rates.joined(separator: ", "))]"
    }
}

let args = CommandLine.arguments
let titleMatch = args.count > 1 ? args[1] : "porthole-probe"
let env = ProcessInfo.processInfo.environment
let targetApp = env["PORTHOLE_APP"] ?? "TextEdit"
let audioCheck = env["PORTHOLE_AUDIO"] != nil
let typed = args.count > 2 ? args[2] : "hello from porthole"
let hostAddress = env["PORTHOLE_HOST"] ?? "127.0.0.1"
let cfgURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Porthole/config.json")
guard let pw = env["PORTHOLE_PW"] ?? ((try? JSONSerialization.jsonObject(with: Data(contentsOf: cfgURL))) as? [String: Any])?["password"] as? String
else { fail("no host config") }

let credential: ViewerCredential = env["PORTHOLE_DEVICE"].flatMap { id in env["PORTHOLE_SECRET"].map { .device(id: id, secret: $0) } } ?? .password(pw)
let (data, _) = try await URLSession.shared.data(from: tokenURL(hostAddress: hostAddress, credential: credential, name: "probe")!)
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
if let attempts = env["PORTHOLE_UNLOCK"] {
    for (i, pw) in attempts.split(separator: "|", omittingEmptySubsequences: false).enumerated() {
        if i > 0 { try await Task.sleep(nanoseconds: UInt64((Double(env["PORTHOLE_UNLOCK_GAP"] ?? "6") ?? 6) * 1_000_000_000)) }
        var m = Message(.unlock); m.s = String(pw)
        let t = Date()
        try await probe.send(m)
        let reply = await probe.wait(for: .unlock, timeout: 30)
        print("UNLOCK attempt \(i + 1): on=\(reply?.on.map(String.init) ?? "nil") msg=\(reply?.msg ?? "no answer") after \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
        fflush(stdout)
    }
    exit(0)
}
if env["PORTHOLE_EXPECT_UNPAIR"] != nil {
    print("WAIT  joined as \(probe.room.localParticipant.identity?.stringValue ?? "?"); unpair this Mac on the host now")
    fflush(stdout)
    for _ in 0..<600 where probe.room.connectionState != .disconnected { try await Task.sleep(nanoseconds: 100_000_000) }
    guard probe.room.connectionState == .disconnected else { fail("still connected 60 s after waiting for the unpair") }
    print("PASS  the host disconnected this viewer after unpairing")
    exit(0)
}

var listReply: Message?
for _ in 0..<10 where listReply == nil {
    try await probe.send(Message(.list))
    listReply = await probe.wait(for: .windows, timeout: 1)
}
guard let list = listReply, list.t == .windows else { fail("window list (\(String(describing: probe.inbox)))") }
let windows = list.list ?? []
print("PASS  host listed \(windows.count) windows")
func offScreenWindow() -> WindowInfo? {
    let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in all where (w[kCGWindowOwnerName as String] as? String) == targetApp && (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let title = w[kCGWindowName as String] as? String, title.contains(titleMatch), let id = w[kCGWindowNumber as String] as? UInt32,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        return WindowInfo(id: id, app: targetApp, title: title, bundle: nil, w: b["Width"] ?? 0, h: b["Height"] ?? 0)
    }
    return nil
}
let screenProbe = env["PORTHOLE_SCREEN"] != nil
if screenProbe {
    let cards = windows.filter { $0.screen == true }
    guard !cards.isEmpty else { fail("no Whole Mac card in the list (is Whole Mac off, or is this viewer not allowed?)") }
    print("PASS  host offered \(cards.count) Whole Mac card(s): \(cards.map { "\($0.title) \(Int($0.w))x\(Int($0.h))" })")
}
guard let target = screenProbe ? windows.first(where: { $0.screen == true }) : windows.first(where: { $0.app == targetApp && $0.title.contains(titleMatch) }) ?? offScreenWindow() else {
    fail("no \(targetApp) window titled *\(titleMatch)*; got: \(windows.map { "\($0.app): \($0.title)" })")
}
print("PASS  found \(target.app) — \(target.title) (\(Int(target.w))×\(Int(target.h)) pt)")

var open = Message(.open); open.win = target.id
for pair in (env["PORTHOLE_STREAM"] ?? "").split(separator: ",") {
    let kv = pair.split(separator: "=").map(String.init)
    guard kv.count == 2 else { continue }
    switch kv[0] {
    case "bitrate": open.bitrate = Int(kv[1])
    case "fps": open.fps = Int(kv[1])
    case "level": open.level = Double(kv[1])
    default: break
    }
}
let t0 = Date()
var openReply: Message?
for _ in 0..<(screenProbe ? 1 : 5) where openReply == nil {
    try await probe.send(open)
    openReply = await probe.wait(for: .opened, timeout: screenProbe ? 25 : 3)
}
guard let opened = openReply, opened.t == .opened, let trackName = opened.track else {
    fail("open reply: \(String(describing: probe.inbox))")
}
print("PASS  host opened window, track \(trackName)")

var pub: RemoteTrackPublication?
for _ in 0..<600 {
    pub = hostP.trackPublications.values.first { $0.name == trackName } as? RemoteTrackPublication
    if pub != nil { break }
    try await Task.sleep(nanoseconds: 50_000_000)
}
guard let pub else { fail("track never published") }
let publishedAt = Date()
try await pub.set(subscribed: true)
var track: VideoTrack?
for _ in 0..<100 { track = pub.track as? VideoTrack; if track != nil { break }; try await Task.sleep(nanoseconds: 50_000_000) }
guard let track else { fail("track never subscribed") }
let counter = FrameCounter()
track.add(videoRenderer: counter)
var firstFrameAt: Date?
for _ in 0..<200 { if counter.snapshot().0 > 0 { firstFrameAt = Date(); break }; try await Task.sleep(nanoseconds: 25_000_000) }
guard let firstFrameAt else { fail("no video frames arrived") }
print(String(format: "PASS  first frame %.2f s after open, %.2f s after the track was published", firstFrameAt.timeIntervalSince(t0), firstFrameAt.timeIntervalSince(publishedAt)))
let stats = StatsLog()
if let remote = track as? RemoteVideoTrack {
    await remote.set(reportStatistics: true)
    Task { while true { try? await Task.sleep(nanoseconds: 500_000_000); stats.add(remote.statistics) } }
}

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

if env["PORTHOLE_P3"] != nil {
    func take(_ kind: Message.Kind) -> [Message] {
        probe.lock.lock(); defer { probe.lock.unlock() }
        let hit = probe.inbox.filter { $0.t == kind }
        probe.inbox.removeAll { $0.t == kind }
        return hit
    }
    print("P3    opened at \(Int(opened.w ?? 0))x\(Int(opened.h ?? 0)) pt (picker said \(Int(target.w))x\(Int(target.h)))")
    let startPx = counter.snapshot().1
    var sent = 0
    let dragStart = Date()
    var throttle = LiveResizeThrottle()
    while Date().timeIntervalSince(dragStart) < 1.5 {
        let t = Date().timeIntervalSince(dragStart)
        let size = CGSize(width: 700 + t * 300, height: 460 + t * 150)
        if let s = throttle.during(size, now: t) {
            var r = Message(.resize); r.win = target.id; r.w = s.width; r.h = s.height
            try await probe.send(r); sent += 1
        }
        try await Task.sleep(nanoseconds: 1_000_000_000 / 120)
        if Int(t * 10) % 5 == 0 { let px = counter.snapshot().1; print("DRAG  t=\(String(format: "%.2f", t)) frame \(Int(px.width))x\(Int(px.height)) px") }
    }
    let final = throttle.finish(CGSize(width: 1150, height: 685), now: 2)
    var r = Message(.resize); r.win = target.id; r.w = final.width; r.h = final.height
    try await probe.send(r); sent += 1
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let endPx = counter.snapshot().1
    print("P3    live drag sent \(sent) resizes in 1.5 s; picture \(Int(startPx.width))x\(Int(startPx.height)) -> \(Int(endPx.width))x\(Int(endPx.height)) px; sized replies \(take(.sized).count)")
    var small = Message(.resize); small.win = target.id; small.w = 200; small.h = 120
    try await probe.send(small)
    try await Task.sleep(nanoseconds: 800_000_000)
    let s1 = take(.sized)
    print("P3    too-small resize: replies \(s1.map { "\(Int($0.w ?? 0))x\(Int($0.h ?? 0)) for \(Int($0.aw ?? 0))x\(Int($0.ah ?? 0))" })")
    var big = Message(.resize); big.win = target.id; big.w = 3000; big.h = 2000
    try await probe.send(big)
    try await Task.sleep(nanoseconds: 800_000_000)
    let s2 = take(.sized)
    print("P3    too-big resize: replies \(s2.map { "\(Int($0.w ?? 0))x\(Int($0.h ?? 0)) for \(Int($0.aw ?? 0))x\(Int($0.ah ?? 0))" })")
    var back = Message(.resize); back.win = target.id; back.w = 700; back.h = 460
    try await probe.send(back)
    let watchUntil = Date().addingTimeInterval(Double(env["PORTHOLE_P3_WATCH"] ?? "30") ?? 30)
    var opened: Set<UInt32> = []
    while Date() < watchUntil {
        for c in take(.companion) {
            print("P3    companion offered: window \(c.win ?? 0) over \(c.of ?? 0) at \(Int(c.x ?? 0)),\(Int(c.y ?? 0)) \(Int(c.w ?? 0))x\(Int(c.h ?? 0)) (parent \(Int(c.pw ?? 0))x\(Int(c.ph ?? 0)))")
            guard let id = c.win, !opened.contains(id) else { continue }
            opened.insert(id)
            var o = Message(.open); o.win = id
            try await probe.send(o)
            let id2 = id
            Task {
                for _ in 0..<100 {
                    if let cp = hostP.trackPublications.values.first(where: { $0.name == Message.trackName(for: id2) }) as? RemoteTrackPublication {
                        try? await cp.set(subscribed: true)
                        for _ in 0..<60 {
                            if let vt = cp.track as? VideoTrack {
                                let cc = FrameCounter(); vt.add(videoRenderer: cc)
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                let (n, sz) = cc.snapshot()
                                print("P3    companion \(id2) picture: \(n) frames in 1 s at \(Int(sz.width))x\(Int(sz.height)) px")
                                return
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                print("P3    companion \(id2): no track")
            }
        }
        for c in take(.closed) { print("P3    closed: window \(c.win ?? 0)") }
        for o in take(.opened) { print("P3    opened reply: window \(o.win ?? 0)") }
        for e in take(.error) { print("P3    error: \(e.msg ?? "")") }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    var close = Message(.close); close.win = target.id
    try await probe.send(close)
    try await Task.sleep(nanoseconds: 500_000_000)
    await probe.room.disconnect()
    print("DONE")
    exit(0)
}

let sendsInput = targetApp == "TextEdit" && !screenProbe
if sendsInput {
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
} else {
    print("SKIP  input and resize: only sent to TextEdit")
}
try await Task.sleep(nanoseconds: 2_500_000_000)
let (n, size) = counter.snapshot()
let secs = Date().timeIntervalSince(firstFrameAt)
print(String(format: "PASS  received %d frames in %.1f s (%.0f fps while typing), %d×%d px", n, secs, Double(n) / secs, Int(size.width), Int(size.height)))
let ratio = size.width / max(target.w, 1)
print(ratio >= 1.9 ? "PASS  Retina capture (\(String(format: "%.2f", ratio))× points)" : "WARN  capture scale \(String(format: "%.2f", ratio))× points")

if sendsInput {
    var resize = Message(.resize); resize.win = target.id; resize.w = target.w + 120; resize.h = target.h + 60
    try await probe.send(resize)
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let (_, size2) = counter.snapshot()
    print(size2.width > size.width ? "PASS  resize followed: \(Int(size2.width))×\(Int(size2.height)) px" : "FAIL  resize: still \(Int(size2.width))×\(Int(size2.height)) px")
}

if let marker = env["PORTHOLE_CLIP_SEND"] {
    _ = try await probe.room.localParticipant.sendText(marker, options: StreamTextOptions(topic: clipboardTopic, destinationIdentities: [Participant.Identity(from: "host")]))
    print("SENT  clipboard text to host: \(marker)")
    try await Task.sleep(nanoseconds: 2_000_000_000)
}
if let expected = env["PORTHOLE_CLIP_EXPECT"] {
    for _ in 0..<100 where fromHost.get() != expected { try await Task.sleep(nanoseconds: 100_000_000) }
    print(fromHost.get() == expected ? "PASS  clipboard from host arrived: \(expected)" : "FAIL  clipboard from host: got \(fromHost.get() ?? "nothing")")
}

print("STATS \(stats.report())")
if let hold = env["PORTHOLE_HOLD"].flatMap(Double.init), let remote = track as? RemoteVideoTrack {
    let end = Date().addingTimeInterval(hold)
    var last = counter.snapshot().0
    while Date() < end {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let s = remote.statistics, inbound = s?.inboundRtpStream.first
        let codec = s?.codec.first { $0.id == inbound?.codecId }?.mimeType ?? "?"
        let n = counter.snapshot().0
        print(String(format: "HOLD  %@ %d×%d, %.0f fps", codec, Int(inbound?.frameWidth ?? 0), Int(inbound?.frameHeight ?? 0), Double(n - last) / 2))
        last = n
    }
}
var close = Message(.close); close.win = target.id
try await probe.send(close)
try await Task.sleep(nanoseconds: 500_000_000)
await probe.room.disconnect()
print("DONE")
exit(0)
