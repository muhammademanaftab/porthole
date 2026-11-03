import Foundation

/// The data-channel topic every Porthole control message travels on.
public let portholeTopic = "porthole"

/// A window the host can share.
public struct WindowInfo: Codable, Equatable, Sendable {
    public var id: UInt32
    public var app: String
    public var title: String
    public var bundle: String?
    /// Size in points.
    public var w: Double
    public var h: Double

    public init(id: UInt32, app: String, title: String, bundle: String?, w: Double, h: Double) {
        self.id = id; self.app = app; self.title = title; self.bundle = bundle; self.w = w; self.h = h
    }
}

/// One control message. A single flat shape keeps it easy to produce from JavaScript.
///
/// Viewer to host: list, open, close, key, text, mouse, scroll, resize.
/// Host to viewer: windows, opened, closed, error.
public struct Message: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case list, open, close, key, text, mouse, scroll, resize
        case windows, opened, closed, error
    }

    public enum MouseKind: String, Codable, Sendable {
        case down, up, move, drag
    }

    public var t: Kind
    public var win: UInt32?
    /// Track name the host publishes a window under (`opened`).
    public var track: String?
    public var list: [WindowInfo]?
    // Keyboard: macOS virtual keycode, key down or up, modifier bits (see `Modifiers`).
    public var code: UInt16?
    public var down: Bool?
    public var mods: UInt32?
    /// Text to type, for `text` and for the character a key produces.
    public var s: String?
    // Pointer: normalized 0...1 inside the window, button 0 left / 1 right / 2 other.
    public var kind: MouseKind?
    public var btn: Int?
    public var clicks: Int?
    public var x: Double?
    public var y: Double?
    // Scroll deltas in points; resize size in points.
    public var dx: Double?
    public var dy: Double?
    public var w: Double?
    public var h: Double?
    public var msg: String?

    public init(_ t: Kind) { self.t = t }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: data)
    }
}

/// Modifier bits sent on key and pointer messages. Same layout from the Mac and the browser viewer.
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
        guard name.hasPrefix("win-") else { return nil }
        return UInt32(name.dropFirst(4))
    }
}
