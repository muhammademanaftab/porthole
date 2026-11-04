import Foundation
import PortholeCore

private func moving(_ ms: Double?, encoded: Double = 60, submitted: Double = 60, captured: Double = 60) -> EncoderSample {
    EncoderSample(encodeMs: ms, encodedFps: encoded, submittedFps: submitted, capturedFps: captured)
}

private let still = EncoderSample(encodeMs: nil, encodedFps: 1, submittedFps: 1, capturedFps: 0)

func streamPrefsTests() {
    expect("stream prefs: an open without preferences keeps 25 Mbps, 60 fps, 2x", StreamPrefs(open: Message(.open)), .standard)
    expect("stream prefs: the standard values", [Double(StreamPrefs.standard.bitrate), Double(StreamPrefs.standard.fps), StreamPrefs.standard.level],
           [25_000_000, 60, 2])
    var m = Message(.open); m.bitrate = 40_000; m.fps = 120; m.level = 1.5
    expect("stream prefs: bitrate kbps, fps and level are taken from the open message", StreamPrefs(open: m),
           StreamPrefs(bitrate: 40_000_000, fps: 120, level: 1.5))
    var bad = Message(.open); bad.bitrate = 50; bad.fps = 45; bad.level = 3
    expect("stream prefs: out-of-range values fall back to the defaults", StreamPrefs(open: bad), .standard)
    var edge = Message(.open); edge.bitrate = 100_000; edge.fps = 30; edge.level = 1
    expect("stream prefs: range edges are accepted", StreamPrefs(open: edge), StreamPrefs(bitrate: 100_000_000, fps: 30, level: 1))
    edge.bitrate = 100_001
    expect("stream prefs: just over 100 Mbps is rejected", StreamPrefs(open: edge).bitrate, StreamPrefs.defaultBitrate)
    let wire = json(m.encoded())
    check("stream prefs: wire names are bitrate, fps and level",
          wire?["bitrate"] as? Int == 40_000 && wire?["fps"] as? Int == 120 && wire?["level"] as? Double == 1.5)
    let decoded = Message.decode(Data(#"{"t":"open","win":3,"bitrate":8000,"fps":30,"level":1.25}"#.utf8))
    expect("stream prefs: a browser open message decodes", decoded.map(StreamPrefs.init(open:)), StreamPrefs(bitrate: 8_000_000, fps: 30, level: 1.25))

    let browser = StreamPrefs(bitrate: 8_000_000, fps: 30, level: 1.25)
    let mac = StreamPrefs(bitrate: 40_000_000, fps: 120, level: 2)
    let mid = StreamPrefs(bitrate: 50_000_000, fps: 60, level: 1.5)
    expect("shared prefs: no viewers is the standard", StreamPrefs.combined([], onlySharedWindow: true), .standard)
    expect("shared prefs: one viewer gets its own prefs", StreamPrefs.combined([browser], onlySharedWindow: true), browser)
    expect("shared prefs: two viewers get the most of each", StreamPrefs.combined([browser, mac, mid], onlySharedWindow: true),
           StreamPrefs(bitrate: 50_000_000, fps: 120, level: 2))
    expect("shared prefs: the order of viewers does not matter", StreamPrefs.combined([mid, browser, mac], onlySharedWindow: true),
           StreamPrefs.combined([mac, mid, browser], onlySharedWindow: true))
    expect("shared prefs: 120 fps only when it is the only shared window", StreamPrefs.combined([mac], onlySharedWindow: false).fps, 60)
    expect("shared prefs: lower rates are kept with other windows", StreamPrefs.combined([browser], onlySharedWindow: false).fps, 30)
    expect("shared prefs: when the 120 fps viewer leaves the rate drops back", StreamPrefs.combined([browser, mid], onlySharedWindow: true).fps, 60)
}

func encoderSampleTests() {
    let a = EncoderCounters(at: 10, framesEncoded: 100, encodeSeconds: 2.5, submitted: 120, captured: 90)
    let b = EncoderCounters(at: 11, framesEncoded: 150, encodeSeconds: 3.75, submitted: 180, captured: 150)
    expect("encoder sample: per-frame encode time and rates from two counter snapshots", EncoderSample(from: a, to: b),
           EncoderSample(encodeMs: 25, encodedFps: 50, submittedFps: 60, capturedFps: 60))
    let idle = EncoderCounters(at: 12, framesEncoded: 150, encodeSeconds: 3.75, submitted: 181, captured: 150)
    expect("encoder sample: no encoded frames gives no encode time", EncoderSample(from: b, to: idle)?.encodeMs, nil)
    check("encoder sample: too short an interval is no sample", EncoderSample(from: a, to: EncoderCounters(at: 10.1, framesEncoded: 101, encodeSeconds: 2, submitted: 121, captured: 91)) == nil)
    check("encoder sample: counters that went backwards (a new sender) are no sample",
          EncoderSample(from: b, to: EncoderCounters(at: 12, framesEncoded: 5, encodeSeconds: 0.1, submitted: 200, captured: 160)) == nil)

    let both0 = EncoderCounters(at: 20, senders: [SenderCount(frames: 100, seconds: 1.0), SenderCount(frames: 100, seconds: 2.0)], submitted: 100, captured: 100)
    let both1 = EncoderCounters(at: 21, senders: [SenderCount(frames: 164, seconds: 1.5), SenderCount(frames: 164, seconds: 3.0)], submitted: 164, captured: 164)
    expect("encoder sample: H.265 and H.264 both encoding count 64 fps, not 128, with the primary's encode time",
           EncoderSample(from: both0, to: both1), EncoderSample(encodeMs: 7.8125, encodedFps: 64, submittedFps: 64, capturedFps: 64))
    let paused0 = EncoderCounters(at: 30, senders: [SenderCount(frames: 500, seconds: 5), SenderCount(frames: 50, seconds: 1)], submitted: 100, captured: 100)
    let paused1 = EncoderCounters(at: 31, senders: [SenderCount(frames: 500, seconds: 5), SenderCount(frames: 114, seconds: 2)], submitted: 164, captured: 164)
    expect("encoder sample: with the primary paused by dynacast the backup's frames and time are used",
           EncoderSample(from: paused0, to: paused1), EncoderSample(encodeMs: 15.625, encodedFps: 64, submittedFps: 64, capturedFps: 64))
    check("encoder sample: a sender appearing (a browser joined) is no sample",
          EncoderSample(from: b, to: EncoderCounters(at: 12, senders: [SenderCount(frames: 200, seconds: 4), SenderCount(frames: 1, seconds: 0)],
                                                     submitted: 240, captured: 210)) == nil)
    check("encoder sample: one sender going backwards is no sample",
          EncoderSample(from: both0, to: EncoderCounters(at: 21, senders: [SenderCount(frames: 160, seconds: 1.6), SenderCount(frames: 5, seconds: 0)],
                                                         submitted: 160, captured: 160)) == nil)
}

func scaleLadderTests() {
    expect("ladder: a Retina window uses 2, 1.5, 1.25, 1", ScaleLadder(native: 2).levels, [2, 1.5, 1.25, 1])
    expect("ladder: a 1x window has only 1", ScaleLadder(native: 1).levels, [1])
    expect("ladder: the viewer's level caps the top", ScaleLadder(top: 1.5, native: 2).levels, [1.5, 1.25, 1])
    expect("ladder: a capture capped below its scale steps down from the cap", ScaleLadder(native: 2, limit: 0.9375).levels, [0.9375, 0.703125, 0.5859375, 0.46875])
    expect("ladder: a cap above the scale changes nothing", ScaleLadder(native: 2, limit: 3).levels, [2, 1.5, 1.25, 1])
    expect("ladder: the cap survives a new top", ScaleLadder(native: 2, limit: 0.9375).retopped(1.5).levels.first, 0.9375)
    expect("capture: a 4096-point screen is limited to 0.9375", captureScaleLimit(points: CGSize(width: 4096, height: 2304), max: CGSize(width: 3840, height: 2160)), 0.9375)
    expect("ladder: starts at the top", ScaleLadder(native: 2).level, 2)

    var l = ScaleLadder(native: 2)
    expect("ladder: one over-budget sample does not step down", l.observe(moving(40), now: 1, lastInputAt: nil), nil)
    expect("ladder: two over-budget samples in a row step down to 1.5", l.observe(moving(40), now: 2, lastInputAt: nil), 1.5)
    expect("ladder: the over count restarts after a step", l.observe(moving(40), now: 3, lastInputAt: nil), nil)
    expect("ladder: then steps to 1.25", l.observe(moving(40), now: 4, lastInputAt: nil), 1.25)
    _ = l.observe(moving(40), now: 5, lastInputAt: nil)
    expect("ladder: then to 1", l.observe(moving(40), now: 6, lastInputAt: nil), 1)
    _ = l.observe(moving(40), now: 7, lastInputAt: nil)
    expect("ladder: never below the bottom rung", l.observe(moving(40), now: 8, lastInputAt: nil), nil)
    expect("ladder: bottom level is 1", l.level, 1)

    var gap = ScaleLadder(native: 2)
    _ = gap.observe(moving(40), now: 1, lastInputAt: nil)
    _ = gap.observe(moving(10), now: 2, lastInputAt: nil)
    expect("ladder: an in-budget sample between resets the over count", gap.observe(moving(40), now: 3, lastInputAt: nil), nil)

    var drop = ScaleLadder(native: 2)
    _ = drop.observe(moving(10, encoded: 20, submitted: 60), now: 1, lastInputAt: nil)
    expect("ladder: an encoder that falls behind the submitted rate counts as over budget",
           drop.observe(moving(10, encoded: 20, submitted: 60), now: 2, lastInputAt: nil), 1.5)

    var calm = ScaleLadder(native: 2)
    _ = calm.observe(EncoderSample(encodeMs: 80, encodedFps: 2, submittedFps: 2, capturedFps: 2), now: 1, lastInputAt: nil)
    expect("ladder: a slow encode of a still window (below 8 fps) is not over budget",
           calm.observe(EncoderSample(encodeMs: 80, encodedFps: 2, submittedFps: 2, capturedFps: 2), now: 2, lastInputAt: nil), nil)

    var held = ScaleLadder(native: 2)
    _ = held.observe(moving(40), now: 100, lastInputAt: 95)
    expect("ladder: during input two over-budget samples are not yet enough", held.observe(moving(40), now: 101, lastInputAt: 95), nil)
    expect("ladder: still at 2 after two samples during input", held.level, 2)
    expect("ladder: during input a third over-budget sample steps down", held.observe(moving(40), now: 102, lastInputAt: 101), 1.5)
    _ = held.observe(moving(40), now: 103, lastInputAt: 102)
    _ = held.observe(moving(40), now: 104, lastInputAt: 103)
    expect("ladder: sustained overload during typing keeps stepping down", held.observe(moving(40), now: 105, lastInputAt: 104), 1.25)

    var after = ScaleLadder(native: 2)
    _ = after.observe(moving(40), now: 100, lastInputAt: 95)
    _ = after.observe(moving(40), now: 101, lastInputAt: 95)
    expect("ladder: the over-budget evidence steps down once the input is 10 s old", after.observe(moving(40), now: 105, lastInputAt: 95), 1.5)

    var typingUp = ScaleLadder(native: 2)
    _ = typingUp.observe(moving(40), now: 0, lastInputAt: nil)
    _ = typingUp.observe(moving(40), now: 1, lastInputAt: nil)
    for t in 46...50 { _ = typingUp.observe(moving(10), now: Double(t), lastInputAt: Double(t)) }
    expect("ladder: during input it never steps up", typingUp.level, 1.5)
    expect("ladder: the step up waits until the input is 10 s old", typingUp.observe(moving(10), now: 61, lastInputAt: 50), 2)

    var paused = ScaleLadder(native: 2)
    let pausedLayer = moving(nil, encoded: 0, submitted: 60, captured: 60)
    check("ladder: zero encoded with frames submitted is a paused layer", paused.isPausedLayer(pausedLayer))
    var steps: [Double?] = []
    for t in 1...10 { steps.append(paused.observe(pausedLayer, now: Double(t), lastInputAt: nil)) }
    expect("ladder: a run of zero-encoded samples (a paused layer) never steps down", steps.compactMap { $0 }, [])
    expect("ladder: still at the top after the run", paused.level, 2)
    expect("ladder: after the run one slow sample is not enough", paused.observe(moving(40), now: 11, lastInputAt: nil), nil)
    expect("ladder: a second slow sample steps down", paused.observe(moving(40), now: 12, lastInputAt: nil), 1.5)

    var unsubscribed = ScaleLadder(native: 2)
    _ = unsubscribed.observe(moving(40), now: 3, lastInputAt: nil)
    _ = unsubscribed.observe(pausedLayer, now: 4, lastInputAt: nil, subscribed: false)
    expect("ladder: a zero sample with no subscribers neither counts nor resets the over count",
           unsubscribed.observe(moving(40), now: 5, lastInputAt: nil), 1.5)

    var stall = ScaleLadder(native: 2)
    _ = stall.observe(moving(40), now: 1, lastInputAt: nil)
    expect("ladder: a single zero-encoded sample while subscribed counts as overload and steps down",
           stall.observe(pausedLayer, now: 2, lastInputAt: nil), 1.5)
    check("ladder: a still window with nothing submitted is not a paused layer", !paused.isPausedLayer(still))

    let dropper = ScaleLadder(native: 2)
    check("ladder: fast encodes with many frames dropped look like the bitrate frame dropper",
          dropper.looksLikeFrameDropper(moving(10, encoded: 20, submitted: 60)))
    check("ladder: slow encodes with frames dropped are real overload", !dropper.looksLikeFrameDropper(moving(40, encoded: 20, submitted: 60)))
    check("ladder: an encoder keeping up is not the frame dropper", !dropper.looksLikeFrameDropper(moving(10)))
    check("ladder: a paused layer is not the frame dropper", !dropper.looksLikeFrameDropper(pausedLayer))

    var top = ScaleLadder(top: 1.25, native: 2)
    expect("ladder retop: a viewer asking for 2 opens the top rungs", top.retopped(2).levels, [2, 1.5, 1.25, 1])
    expect("ladder retop: the current level is kept", top.retopped(2).level, 1.25)
    _ = top.observe(moving(40), now: 0, lastInputAt: nil)
    _ = top.observe(moving(40), now: 1, lastInputAt: nil)
    expect("ladder retop: a stepped-down level is kept", top.retopped(2).level, 1)
    let low = ScaleLadder(native: 2).retopped(1.5)
    expect("ladder retop: lowering the top moves a higher level down to it", low.level, 1.5)
    expect("ladder retop: lowering the top drops the higher rungs", low.levels, [1.5, 1.25, 1])
    expect("ladder retop: never above the window's own scale", ScaleLadder(native: 1).retopped(2).levels, [1])

    var up = ScaleLadder(native: 2)
    _ = up.observe(moving(40), now: 0, lastInputAt: nil)
    _ = up.observe(moving(40), now: 1, lastInputAt: nil)
    for t in 2...30 { _ = up.observe(still, now: Double(t), lastInputAt: nil) }
    expect("ladder: stillness inside the 45 s cooldown keeps the lower level", up.level, 1.5)
    expect("ladder: once the cooldown passes, a still window returns to the top", up.observe(still, now: 46, lastInputAt: nil), 2)

    var busy = ScaleLadder(native: 2)
    _ = busy.observe(moving(40), now: 0, lastInputAt: nil)
    _ = busy.observe(moving(40), now: 1, lastInputAt: nil)
    _ = busy.observe(moving(10), now: 46, lastInputAt: nil)
    _ = busy.observe(moving(10), now: 47, lastInputAt: nil)
    expect("ladder: a moving window climbs one rung after three samples under 22 ms", busy.observe(moving(10), now: 48, lastInputAt: nil), 2)

    var mid = ScaleLadder(native: 2)
    _ = mid.observe(moving(40), now: 0, lastInputAt: nil)
    _ = mid.observe(moving(40), now: 1, lastInputAt: nil)
    for t in 46...50 { _ = mid.observe(moving(25), now: Double(t), lastInputAt: nil) }
    expect("ladder: between 22 and 30 ms the level holds", mid.level, 1.5)

    var recent = ScaleLadder(native: 2)
    _ = recent.observe(moving(40), now: 0, lastInputAt: nil)
    _ = recent.observe(moving(40), now: 1, lastInputAt: nil)
    _ = recent.observe(moving(10), now: 50, lastInputAt: nil)
    expect("ladder: motion less than 6 s ago is not quiet enough to jump to the top", recent.observe(still, now: 53, lastInputAt: nil), nil)
    expect("ladder: input keeps the stepped-down level after the cooldown", recent.observe(still, now: 60, lastInputAt: 58), nil)
    expect("ladder: quiet and no recent input returns to the top", recent.observe(still, now: 70, lastInputAt: 58), 2)

    var one = ScaleLadder(native: 1)
    _ = one.observe(moving(90), now: 1, lastInputAt: nil)
    expect("ladder: a single-rung ladder never changes", one.observe(moving(90), now: 2, lastInputAt: nil), nil)
}

func framePacerTests() {
    var p = FramePacer()
    expect("pacer: nothing to do before the first frame", [p.padTick(at: 1), p.idleTick(at: 5)], [nil, nil])
    p.realFrame(at: 10)
    check("pacer: one real frame alone does not pad", !p.isPadding(at: 10.01))
    expect("pacer: exactly 1 s without a frame does not resend", p.idleTick(at: 11.0), nil)
    expect("pacer: keepalive resends after just over 1 s", p.idleTick(at: 11.01), .keepalive)
    expect("pacer: not again right away", p.idleTick(at: 11.5), nil)
    expect("pacer: again after another second", p.idleTick(at: 12.02), .keepalive)
    expect("pacer: one sharp refresh 3 s after the last real frame", p.idleTick(at: 13.0), .sharpRefresh)
    expect("pacer: then plain keepalives", [p.idleTick(at: 13.5), p.idleTick(at: 14.1)], [nil, .keepalive])
    expect("pacer: the sharp refresh happens only once per quiet period", p.idleTick(at: 20), .keepalive)

    var blink = FramePacer()
    blink.realFrame(at: 0); blink.realFrame(at: 0.5); blink.realFrame(at: 1.0)
    check("pacer: a caret blinking every 0.5 s does not start padding", !blink.isPadding(at: 1.01))

    var scroll = FramePacer()
    for i in 0..<30 { scroll.realFrame(at: Double(i) / 60) }
    check("pacer: a scroll pads", scroll.isPadding(at: 0.5))
    let stop = 29.0 / 60
    scroll.realFrame(at: stop + 0.5)
    check("pacer: one blink after the scroll may keep padding", scroll.isPadding(at: stop + 0.51))
    scroll.realFrame(at: stop + 1.0)
    check("pacer: the second blink after the scroll ends padding", !scroll.isPadding(at: stop + 1.01))
    var padsDuringBlinks = 0
    for k in 3...20 {
        let t = stop + Double(k) * 0.5
        scroll.realFrame(at: t)
        if scroll.isPadding(at: t + 0.01) { padsDuringBlinks += 1 }
    }
    expect("pacer: a caret blinking for 10 s after a scroll never pads", padsDuringBlinks, 0)
    for i in 0..<5 { scroll.realFrame(at: 20 + Double(i) / 60) }
    check("pacer: a new scroll after the blinking pads again", scroll.isPadding(at: 20.1))

    var rate = FramePacer()
    rate.retime(padHz: 120)
    expect("pacer: retime changes the pad interval", rate.interval, 1.0 / 120)

    var m = FramePacer()
    m.realFrame(at: 0); m.realFrame(at: 0.016)
    check("pacer: two close real frames start padding", m.isPadding(at: 0.02))
    let i = m.interval
    expect("pacer: pad interval is 60 Hz", i, 1.0 / 60)
    expect("pacer: a real frame keeps the next pad away for 1.5 intervals", m.padTick(at: 0.016 + 1.4 * i), nil)
    expect("pacer: pad after 1.5 intervals without a real frame", m.padTick(at: 0.016 + 1.51 * i), .pad)
    expect("pacer: pads then keep the cadence", m.padTick(at: 0.016 + 2.51 * i), .pad)
    expect("pacer: no double pad inside one interval", m.padTick(at: 0.016 + 2.9 * i), nil)
    expect("pacer: no keepalive or refresh while padding", m.idleTick(at: 1.5), nil)
    m.realFrame(at: 1.0)
    check("pacer: later frames within 2 s keep the burst going", m.isPadding(at: 2.9))
    check("pacer: padding stops 2 s after the last real frame", !m.isPadding(at: 3.0))
    expect("pacer: pad ticks after the idle cut do nothing", m.padTick(at: 3.1), nil)
    expect("pacer: the sharp refresh still follows after quiet", m.idleTick(at: 4.0), .sharpRefresh)

    var typing = FramePacer()
    typing.realFrame(at: 0)
    typing.input(at: 5)
    check("pacer: input starts padding even without motion", typing.isPadding(at: 5.1))
    expect("pacer: and pads come at the cadence", typing.padTick(at: 5.1), .pad)
    check("pacer: padding stops 2 s after the last input", !typing.isPadding(at: 7.0))

    var fresh = FramePacer()
    fresh.input(at: 1)
    check("pacer: input before any frame has nothing to pad", !fresh.isPadding(at: 1.1))
}
