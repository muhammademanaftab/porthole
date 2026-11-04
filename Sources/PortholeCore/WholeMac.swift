import CoreGraphics
import Foundation

public enum WholeMacMode: String, CaseIterable, Equatable, Sendable {
    case off, ask, always

    public var label: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Ask Each Time"
        case .always: return "Always"
        }
    }
}

public enum WholeMacViewer: Equatable, Sendable {
    case paired(device: String)
    case password(identity: String)
    case other

    public var approvalKey: String? {
        switch self {
        case .paired(let d): return "device:\(d)"
        case .password(let i): return "viewer:\(i)"
        case .other: return nil
        }
    }
}

public struct ScreenFacts: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var scale: Double
    public var isMain: Bool
    public var isBuiltin: Bool
    public var vendor: UInt32
    public var isStage: Bool

    public init(id: UInt32, frame: CGRect, scale: Double, isMain: Bool, isBuiltin: Bool, vendor: UInt32, isStage: Bool = false) {
        self.id = id; self.frame = frame; self.scale = scale; self.isMain = isMain
        self.isBuiltin = isBuiltin; self.vendor = vendor; self.isStage = isStage
    }
}

public enum WholeMac {
    public static let settingKey = "allowWholeMac"
    public static let envKey = "PORTHOLE_WHOLE_MAC"
    public static let matchEnvKey = "PORTHOLE_SCREEN_MATCH"
    public static let firstID: UInt32 = 0xFFFF_FF00
    public static let maxScreens = 16
    public static let appName = "Whole Mac"
    public static let approvalSeconds: Double = 18
    public static let stubVendors: Set<UInt32> = [0, 0x756E_6B6E, 0xFFFF_FFFF]
    public static let defaultMode = WholeMacMode.ask

    public static func mode(stored: Any?, environment: [String: String]) -> WholeMacMode {
        if let forced = environment[envKey].flatMap({ WholeMacMode(rawValue: $0.lowercased()) }) { return forced }
        return (stored as? String).flatMap(WholeMacMode.init(rawValue:)) ?? defaultMode
    }

    public static func viewer(_ identity: String) -> WholeMacViewer {
        if let device = deviceID(fromIdentity: identity) { return .paired(device: device) }
        if identity.hasPrefix("view-"), !identity.contains(".") { return .password(identity: identity) }
        return .other
    }

    public static func viewerName(_ identity: String) -> String {
        guard identity.hasPrefix("view-") else { return identity }
        var rest = identity.dropFirst(5)
        if let dot = rest.lastIndex(of: ".") { rest = rest[..<dot] }
        if let dash = rest.lastIndex(of: "-") { rest = rest[..<dash] }
        return rest.isEmpty ? "a viewer" : String(rest)
    }

    public static func offered(mode: WholeMacMode, viewer: WholeMacViewer) -> Bool {
        mode != .off && viewer != .other
    }

    public static func windowID(screen index: Int) -> UInt32? {
        guard index >= 0, index < maxScreens else { return nil }
        return firstID + UInt32(index)
    }

    public static func screenIndex(_ id: UInt32) -> Int? {
        guard id >= firstID, id < firstID + UInt32(maxScreens) else { return nil }
        return Int(id - firstID)
    }

    public static func isScreen(_ id: UInt32) -> Bool { screenIndex(id) != nil }

    public static func ordered(_ screens: [ScreenFacts]) -> [ScreenFacts] {
        screens.filter { !$0.isStage }.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
            return a.id < b.id
        }.prefix(maxScreens).map { $0 }
    }

    public static func looksLikeStub(_ s: ScreenFacts) -> Bool {
        !s.isStage && !s.isBuiltin && stubVendors.contains(s.vendor)
    }

    public static func needsScreenMatch(_ screens: [ScreenFacts], environment: [String: String]) -> Bool {
        switch environment[matchEnvKey] {
        case "0": return false
        case "1": return true
        default:
            let real = screens.filter { !$0.isStage }
            return real.isEmpty || real.allSatisfy(looksLikeStub)
        }
    }

    public static func title(index: Int, of count: Int, matched: Bool) -> String {
        if matched { return "This Mac's Screen" }
        if count <= 1 { return "Main Display" }
        return index == 0 ? "Main Display" : "Display \(index + 1)"
    }

    public static func entries(_ screens: [ScreenFacts], matched: Bool) -> [WindowInfo] {
        let list = ordered(screens)
        if matched {
            let size = (screens.first(where: \.isStage) ?? list.first)?.frame.size ?? CGSize(width: 1920, height: 1080)
            return [entry(index: 0, title: title(index: 0, of: 1, matched: true), size: size)].compactMap { $0 }
        }
        return list.enumerated().compactMap { i, s in
            entry(index: i, title: title(index: i, of: list.count, matched: false), size: s.frame.size)
        }
    }

    private static func entry(index: Int, title: String, size: CGSize) -> WindowInfo? {
        guard let id = windowID(screen: index) else { return nil }
        var w = WindowInfo(id: id, app: appName, title: title, bundle: nil, w: Double(size.width), h: Double(size.height))
        w.screen = true
        return w
    }

    public static func target(_ id: UInt32, screens: [ScreenFacts]) -> ScreenFacts? {
        guard let i = screenIndex(id) else { return nil }
        let list = ordered(screens)
        return i < list.count ? list[i] : nil
    }

    public static func inputPoint(nx: Double, ny: Double, screen: CGRect) -> CGPoint {
        globalPoint(nx: nx, ny: ny, windowBounds: screen)
    }

    public static func acceptsInput(_ kind: Message.Kind) -> Bool {
        switch kind {
        case .key, .text, .mouse, .scroll: return true
        default: return false
        }
    }

    public static func mayStart(mode: WholeMacMode, approved: Bool, viewerPresent: Bool) -> Bool {
        mode != .off && viewerPresent && (mode == .always || approved)
    }

    public static func mayControl(mode: WholeMacMode) -> Bool { mode != .off }

    public static func sessionsToEnd(mode: WholeMacMode, live: [UInt32]) -> [UInt32] {
        mode == .off ? live.filter(isScreen).sorted() : []
    }

    public static func blocksInjectedClick(at p: CGPoint, guarded frames: [CGRect]) -> Bool {
        frames.contains { $0.insetBy(dx: -8, dy: -8).contains(p) }
    }

    public static func capturePixels(screen: CGRect, scale: Double, level: Double) -> CGSize {
        capturePixelSize(points: screen.size, scale: CGFloat(min(scale, level)))
    }
}

public struct WholeMacApprovals: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case allow
        case ask(key: String)
        case waiting
        case refuse(String)
    }

    public private(set) var granted: Set<String> = []
    public private(set) var pending: [String: Double] = [:]
    public var timeout: Double

    public static let offMessage = "Whole Mac is turned off on this Mac (Settings › Sharing This Mac)."
    public static let notAllowedMessage = "Only paired Macs and viewers with the password can see the whole Mac."
    public static let declinedMessage = "Someone on the host declined Whole Mac."
    public static let unansweredMessage = "Nobody answered on the host. Ask again when someone is there, or set Whole Mac to Always."

    public init(timeout: Double = WholeMac.approvalSeconds) { self.timeout = timeout }

    public mutating func request(mode: WholeMacMode, viewer: WholeMacViewer, now: Double) -> Decision {
        guard mode != .off else { return .refuse(Self.offMessage) }
        guard let key = viewer.approvalKey else { return .refuse(Self.notAllowedMessage) }
        if mode == .always || granted.contains(key) { return .allow }
        if let asked = pending[key], now - asked < timeout { return .waiting }
        pending[key] = now
        return .ask(key: key)
    }

    public func isApproved(mode: WholeMacMode, viewer: WholeMacViewer) -> Bool {
        guard mode != .off, let key = viewer.approvalKey else { return false }
        return mode == .always || granted.contains(key)
    }

    public mutating func cancel(_ key: String) {
        pending[key] = nil
    }

    @discardableResult
    public mutating func answer(_ key: String, allow: Bool) -> Bool {
        guard pending.removeValue(forKey: key) != nil else { return false }
        if allow { granted.insert(key) }
        return true
    }

    public mutating func expire(now: Double) -> [String] {
        let gone = pending.filter { now - $0.value >= timeout }.map(\.key).sorted()
        for k in gone { pending[k] = nil }
        return gone
    }

    public mutating func revoke(_ key: String) {
        granted.remove(key)
        pending[key] = nil
    }

    public mutating func reset() {
        granted.removeAll()
        pending.removeAll()
    }
}

public struct WholeMacWaiter: Equatable, Sendable {
    public var id: UInt32
    public var who: String

    public init(id: UInt32, who: String) { self.id = id; self.who = who }
}

public struct WholeMacQueue: Equatable, Sendable {
    public private(set) var waiting: [String: [WholeMacWaiter]] = [:]

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty }

    @discardableResult
    public mutating func add(_ key: String, _ w: WholeMacWaiter) -> Bool {
        var list = waiting[key] ?? []
        guard !list.contains(w) else { return false }
        list.append(w)
        waiting[key] = list
        return true
    }

    public mutating func take(_ key: String) -> [WholeMacWaiter] {
        waiting.removeValue(forKey: key) ?? []
    }

    public mutating func drop(who: String) -> [String] {
        var emptied: [String] = []
        for key in waiting.keys.sorted() {
            let left = waiting[key]?.filter { $0.who != who } ?? []
            if left.isEmpty { waiting[key] = nil; emptied.append(key) } else { waiting[key] = left }
        }
        return emptied
    }

    public mutating func removeAll() -> [String: [WholeMacWaiter]] {
        defer { waiting.removeAll() }
        return waiting
    }
}
