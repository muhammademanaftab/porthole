import Foundation

public let portholeTopic = "porthole"

public struct WindowInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var app: String
    public var title: String
    public var bundle: String?
    public var w: Double
    public var h: Double
    public var screen: Bool?

    public init(id: UInt32, app: String, title: String, bundle: String?, w: Double, h: Double, screen: Bool? = nil) {
        self.id = id; self.app = app; self.title = title; self.bundle = bundle; self.w = w; self.h = h; self.screen = screen
    }
}

public struct Message: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case list, open, close, key, text, mouse, scroll, resize
        case windows, opened, closed, error
        case icon, thumb
        case restart
        case sized
        case companion
    }

    public enum MouseKind: String, Codable, Sendable {
        case down, up, move, drag
    }

    public var t: Kind
    public var win: UInt32?
    public var track: String?
    public var audio: String?
    public var list: [WindowInfo]?
    public var code: UInt16?
    public var down: Bool?
    public var mods: UInt32?
    public var s: String?
    public var kind: MouseKind?
    public var btn: Int?
    public var clicks: Int?
    public var x: Double?
    public var y: Double?
    public var dx: Double?
    public var dy: Double?
    public var w: Double?
    public var h: Double?
    public var msg: String?
    public var sw: Double?
    public var sh: Double?
    public var ss: Double?
    public var bitrate: Int?
    public var fps: Int?
    public var level: Double?
    public var aw: Double?
    public var ah: Double?
    public var of: UInt32?
    public var pw: Double?
    public var ph: Double?

    public init(_ t: Kind) { self.t = t }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: data)
    }
}

public struct Modifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
}

public extension Message {
    static func trackName(for window: UInt32) -> String { "win-\(window)" }

    static func windowID(fromTrackName name: String) -> UInt32? {
        guard name.hasPrefix("win-"), let id = UInt32(name.dropFirst(4)), trackName(for: id) == name else { return nil }
        return id
    }

    static let audioTrackName = "aud-mix"

    static func isAudioTrackName(_ name: String) -> Bool { name == audioTrackName }
}
