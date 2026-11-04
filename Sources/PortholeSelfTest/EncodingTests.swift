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
}

func scaleLadderTests() {
    expect("ladder: a Retina window uses 2, 1.5, 1.25, 1", ScaleLadder(native: 2).levels, [2, 1.5, 1.25, 1])
    expect("ladder: a 1x window has only 1", ScaleLadder(native: 1).levels, [1])
    expect("ladder: the viewer's level caps the top", ScaleLadder(top: 1.5, native: 2).levels, [1.5, 1.25, 1])
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
    expect("ladder: no step down within 10 s of input", held.observe(moving(40), now: 101, lastInputAt: 95), nil)
    expect("ladder: held level stays at 2", held.level, 2)
    expect("ladder: the over-budget evidence steps down once the hold ends", held.observe(moving(40), now: 105, lastInputAt: 95), 1.5)

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
