import Foundation

public enum SoundCue: String, CaseIterable, Sendable {
    case portalOpened, portalClosed, paired, pairingFailed

    public var systemSound: String {
        switch self {
        case .portalOpened: return "Pop"
        case .portalClosed: return "Bottle"
        case .paired: return "Glass"
        case .pairingFailed: return "Basso"
        }
    }

    public var volume: Float {
        switch self {
        case .portalOpened, .portalClosed: return 0.25
        case .paired, .pairingFailed: return 0.35
        }
    }
}

public enum SoundEffects {
    public static let envKey = "PORTHOLE_SOUNDS"
    public static let settingKey = "general.soundEffects"

    public static func enabled(setting: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch environment[envKey] {
        case "0": return false
        case "1": return true
        default: return setting
        }
    }

    public static func setting(_ stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    public static func systemAllows(_ stored: Any?) -> Bool {
        guard let n = stored as? NSNumber else { return true }
        return n.intValue != 0
    }

    public static func soundPath(_ cue: SoundCue) -> String {
        "/System/Library/Sounds/\(cue.systemSound).aiff"
    }
}

public struct SoundGate: Sendable {
    public var minimumGap: TimeInterval
    private var last: [String: Date] = [:]

    public init(minimumGap: TimeInterval = 0.15) { self.minimumGap = minimumGap }

    public mutating func shouldPlay(_ cue: SoundCue, now: Date) -> Bool {
        if let at = last[cue.rawValue], now.timeIntervalSince(at) < minimumGap { return false }
        last[cue.rawValue] = now
        return true
    }
}
