import Foundation

public struct ViewerSettings: Equatable, Sendable {
    public static let bitrateKey = "stream.bitrateKbps"
    public static let fpsKey = "stream.fps"
    public static let levelKey = "stream.level"
    public static let hideTitleBarKey = "windows.autoHideTitleBar"
    public static let playSoundKey = "general.playSound"

    public static let bitrateChoices: [Int?] = [nil, 10_000, 25_000, 50_000, 100_000]
    public static let fpsChoices: [Int?] = [nil, 30, 60, 120]
    public static let levelChoices: [Double?] = [nil, 2, 1.5, 1.25, 1]

    public var bitrateKbps: Int?
    public var fps: Int?
    public var level: Double?
    public var hideTitleBar: Bool
    public var playSound: Bool
    public var soundEffects: Bool
    public var route: RouteMode

    public init(bitrateKbps: Int? = nil, fps: Int? = nil, level: Double? = nil, hideTitleBar: Bool = false, playSound: Bool = true,
                soundEffects: Bool = true, route: RouteMode = .auto) {
        self.bitrateKbps = bitrateKbps; self.fps = fps; self.level = level
        self.hideTitleBar = hideTitleBar; self.playSound = playSound; self.soundEffects = soundEffects
        self.route = route
    }

    public init(lookup: (String) -> Any?) {
        self.init()
        if let n = (lookup(Self.bitrateKey) as? NSNumber)?.intValue, StreamPrefs.bitrateKbpsRange.contains(n) { bitrateKbps = n }
        if let n = (lookup(Self.fpsKey) as? NSNumber)?.intValue, StreamPrefs.allowedFps.contains(n) { fps = n }
        if let n = (lookup(Self.levelKey) as? NSNumber)?.doubleValue, StreamPrefs.levels.contains(n) { level = n }
        if let b = lookup(Self.hideTitleBarKey) as? Bool { hideTitleBar = b }
        if let b = lookup(Self.playSoundKey) as? Bool { playSound = b }
        soundEffects = SoundEffects.setting(lookup(SoundEffects.settingKey))
        route = RouteMode.setting(lookup(RouteMode.settingKey))
    }

    public var stored: [String: Any?] {
        [Self.bitrateKey: bitrateKbps, Self.fpsKey: fps, Self.levelKey: level,
         Self.hideTitleBarKey: hideTitleBar, Self.playSoundKey: playSound,
         SoundEffects.settingKey: soundEffects, RouteMode.settingKey: route.rawValue]
    }

    public func apply(to m: inout Message) {
        m.bitrate = bitrateKbps
        m.fps = fps
        m.level = level
    }

    public static func bitrateLabel(_ kbps: Int?) -> String {
        guard let kbps else { return "Automatic (\(StreamPrefs.defaultBitrate / 1_000_000) Mbps)" }
        return kbps % 1000 == 0 ? "\(kbps / 1000) Mbps" : String(format: "%.1f Mbps", Double(kbps) / 1000)
    }

    public static func fpsLabel(_ fps: Int?) -> String {
        guard let fps else { return "Automatic (\(StreamPrefs.defaultFps) fps)" }
        return "\(fps) fps"
    }

    public static func levelLabel(_ level: Double?) -> String {
        guard let level else { return "Automatic (up to Retina)" }
        let x = level == level.rounded() ? String(Int(level)) : String(format: "%g", level)
        return level >= 2 ? "Retina (\(x)×)" : "\(x)×"
    }
}
