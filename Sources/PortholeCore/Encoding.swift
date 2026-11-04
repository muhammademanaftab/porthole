import Foundation

public struct StreamPrefs: Equatable, Sendable {
    public var bitrate: Int
    public var fps: Int
    public var level: Double

    public static let defaultBitrate = 25_000_000
    public static let defaultFps = 60
    public static let allowedFps = [30, 60, 120]
    public static let levels: [Double] = [2, 1.5, 1.25, 1]
    public static let bitrateKbpsRange = 1_000...100_000
    public static let standard = StreamPrefs(bitrate: defaultBitrate, fps: defaultFps, level: levels[0])

    public init(bitrate: Int, fps: Int, level: Double) { self.bitrate = bitrate; self.fps = fps; self.level = level }

    public init(open m: Message) {
        self = .standard
        if let kbps = m.bitrate, Self.bitrateKbpsRange.contains(kbps) { bitrate = kbps * 1000 }
        if let f = m.fps, Self.allowedFps.contains(f) { fps = f }
        if let l = m.level, Self.levels.contains(l) { level = l }
    }
}

public struct EncoderCounters: Equatable, Sendable {
    public var at: Double
    public var framesEncoded: Int
    public var encodeSeconds: Double
    public var submitted: Int
    public var captured: Int

    public init(at: Double, framesEncoded: Int, encodeSeconds: Double, submitted: Int, captured: Int) {
        self.at = at; self.framesEncoded = framesEncoded; self.encodeSeconds = encodeSeconds
        self.submitted = submitted; self.captured = captured
    }
}

public struct EncoderSample: Equatable, Sendable {
    public var encodeMs: Double?
    public var encodedFps: Double
    public var submittedFps: Double
    public var capturedFps: Double

    public init(encodeMs: Double?, encodedFps: Double, submittedFps: Double, capturedFps: Double) {
        self.encodeMs = encodeMs; self.encodedFps = encodedFps; self.submittedFps = submittedFps; self.capturedFps = capturedFps
    }

    public init?(from a: EncoderCounters, to b: EncoderCounters) {
        let dt = b.at - a.at
        guard dt >= 0.25, b.framesEncoded >= a.framesEncoded, b.submitted >= a.submitted, b.captured >= a.captured else { return nil }
        let frames = b.framesEncoded - a.framesEncoded
        encodeMs = frames > 0 ? max(0, b.encodeSeconds - a.encodeSeconds) * 1000 / Double(frames) : nil
        encodedFps = Double(frames) / dt
        submittedFps = Double(b.submitted - a.submitted) / dt
        capturedFps = Double(b.captured - a.captured) / dt
    }
}

public struct ScaleLadder: Sendable {
    public struct Config: Equatable, Sendable {
        public var budgetMs: Double = 30
        public var upBudgetMs: Double = 22
        public var keepUpRatio: Double = 0.6
        public var motionFps: Double = 8
        public var overSamples = 2
        public var underSamples = 3
        public var inputHold: Double = 10
        public var quietDwell: Double = 6
        public var upCooldown: Double = 45

        public init() {}
    }

    public let levels: [Double]
    public let config: Config
    public private(set) var index = 0
    private var over = 0
    private var under = 0
    private var lastDownAt: Double?
    private var lastMotionAt: Double?

    public var level: Double { levels[index] }

    public init(top: Double = StreamPrefs.levels[0], native: Double, levels all: [Double] = StreamPrefs.levels, config: Config = Config()) {
        let cap = min(top, native)
        let usable = all.filter { $0 <= cap + 0.001 }.sorted(by: >)
        levels = usable.isEmpty ? [cap] : usable
        self.config = config
    }

    public func isOverBudget(_ s: EncoderSample) -> Bool {
        guard s.capturedFps >= config.motionFps else { return false }
        if let ms = s.encodeMs, ms > config.budgetMs { return true }
        return s.submittedFps >= config.motionFps && s.encodedFps < s.submittedFps * config.keepUpRatio
    }

    public func isUnderBudget(_ s: EncoderSample) -> Bool {
        guard s.capturedFps >= config.motionFps, let ms = s.encodeMs else { return false }
        return ms <= config.upBudgetMs && s.encodedFps >= s.submittedFps * config.keepUpRatio
    }

    public mutating func observe(_ s: EncoderSample, now: Double, lastInputAt: Double?) -> Double? {
        if s.capturedFps >= config.motionFps { lastMotionAt = now }
        over = isOverBudget(s) ? over + 1 : 0
        under = isUnderBudget(s) ? under + 1 : 0
        if let input = lastInputAt, now - input < config.inputHold { return nil }
        if over >= config.overSamples, index < levels.count - 1 {
            index += 1; over = 0; under = 0; lastDownAt = now
            return level
        }
        guard index > 0, now - (lastDownAt ?? -.infinity) >= config.upCooldown else { return nil }
        if now - (lastMotionAt ?? -.infinity) >= config.quietDwell {
            index = 0; under = 0
            return level
        }
        if under >= config.underSamples {
            index -= 1; under = 0
            return level
        }
        return nil
    }
}

public struct FramePacer: Sendable {
    public struct Config: Equatable, Sendable {
        public var padHz: Double = 60
        public var padGap: Double = 1.5
        public var padIdle: Double = 2
        public var burstGap: Double = 0.25
        public var keepalive: Double = CapturePacing.resendAfter
        public var sharpRefresh: Double = 3

        public init() {}
    }

    public enum Action: Equatable, Sendable { case pad, keepalive, sharpRefresh }

    public let config: Config
    private var lastRealAt: Double?
    private var lastInputAt: Double?
    private var lastSubmitAt: Double?
    private var lastWasReal = false
    private var burst = 0
    private var refreshPending = false

    public init(config: Config = Config()) { self.config = config }

    public var interval: Double { 1 / config.padHz }

    public mutating func realFrame(at now: Double) {
        if let last = lastRealAt, now - last <= config.burstGap { burst += 1 } else if let last = lastRealAt, now - last < config.padIdle, burst >= 2 { burst += 1 } else { burst = 1 }
        lastRealAt = now
        lastSubmitAt = now
        lastWasReal = true
        refreshPending = true
    }

    public mutating func input(at now: Double) { lastInputAt = now }

    public func isPadding(at now: Double) -> Bool {
        let recentInput = lastInputAt.map { now - $0 < config.padIdle } ?? false
        let moving = burst >= 2 && (lastRealAt.map { now - $0 < config.padIdle } ?? false)
        return lastSubmitAt != nil && (moving || recentInput)
    }

    public mutating func padTick(at now: Double) -> Action? {
        guard isPadding(at: now), let last = lastSubmitAt else { return nil }
        let gap = (lastWasReal ? config.padGap : 0.95) * interval
        guard now - last >= gap else { return nil }
        submitted(at: now)
        return .pad
    }

    public mutating func idleTick(at now: Double) -> Action? {
        guard let last = lastSubmitAt, !isPadding(at: now) else { return nil }
        if refreshPending, let real = lastRealAt, now - real >= config.sharpRefresh {
            refreshPending = false
            submitted(at: now)
            return .sharpRefresh
        }
        guard now - last > config.keepalive else { return nil }
        submitted(at: now)
        return .keepalive
    }

    private mutating func submitted(at now: Double) {
        lastSubmitAt = now
        lastWasReal = false
    }
}
