import CoreGraphics
import Foundation

public enum CurtainSetting {
    public static let settingKey = "curtainWholeMac"
    public static let envKey = "PORTHOLE_CURTAIN"

    public static func enabled(stored: Any?, environment: [String: String]) -> Bool {
        switch environment[envKey] {
        case "0": return false
        case "1": return true
        default: return stored as? Bool ?? false
        }
    }
}

public enum PortholeEventTag {
    public static let value: Int64 = 0x504F_5254_484F
}

public enum CurtainVerdict: Equatable, Sendable {
    case pass, block, escape, reenable
}

public enum CurtainFilter {
    public static let escapeKey: UInt16 = 53
    public static let escapeFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    public static let escapeHint = "Control-Option-Command-Escape"

    public static let blockedTypes: Set<UInt32> = Set([
        CGEventType.keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .tabletPointer, .tabletProximity,
    ].map(\.rawValue))

    public static func isEscape(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        type == .keyDown && keyCode == escapeKey && flags.intersection([.maskControl, .maskAlternate, .maskCommand]) == escapeFlags
    }

    public static func verdict(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, userData: Int64) -> CurtainVerdict {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return .reenable }
        if userData == PortholeEventTag.value { return .pass }
        if isEscape(type: type, keyCode: keyCode, flags: flags) { return .escape }
        return blockedTypes.contains(type.rawValue) ? .block : .pass
    }

    public static let mask: CGEventMask = blockedTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
}

public protocol CurtainTap: AnyObject {
    func start(onEscape: @escaping () -> Void) -> Bool
    func stop()
}

public protocol CurtainScreens: AnyObject {
    func show(_ notice: CurtainNotice)
    func hide()
}

public struct CurtainNotice: Equatable, Sendable {
    public var title: String
    public var message: String
    public var hint: String

    public init(viewer: String?, blocking: Bool) {
        title = "This Mac is in use from another device"
        let who = viewer.map { "\($0) is using this Mac. " } ?? "Someone is using this Mac from another device. "
        message = who + (blocking ? "The keyboard, mouse and trackpad here are paused until they finish." : "What they do is hidden here until they finish.")
        hint = "Press \(CurtainFilter.escapeHint) to take this Mac back."
    }
}

public final class CurtainController {
    public enum LiftReason: String, Equatable, Sendable {
        case portalClosed, settingOff, escape, timeout, quit
    }

    public static let safetySeconds: Double = 30 * 60

    private let tap: CurtainTap
    private let screens: CurtainScreens
    public let safety: Double
    public private(set) var isUp = false
    public private(set) var isBlocking = false
    public private(set) var raisedAt: Double?
    public private(set) var lastLift: LiftReason?
    public private(set) var heldOff = false
    public var onEscape: (() -> Void)?

    public init(tap: CurtainTap, screens: CurtainScreens, safety: Double = CurtainController.safetySeconds) {
        self.tap = tap
        self.screens = screens
        self.safety = max(1, safety)
    }

    public func update(enabled: Bool, liveScreens: Int, viewer: String?, now: Double) {
        guard liveScreens > 0 else {
            heldOff = false
            lift(.portalClosed)
            return
        }
        guard enabled else { lift(.settingOff); return }
        guard !isUp, !heldOff else { return }
        isBlocking = tap.start { [weak self] in self?.onEscape?() }
        screens.show(CurtainNotice(viewer: viewer, blocking: isBlocking))
        isUp = true
        raisedAt = now
        lastLift = nil
    }

    public func escape() {
        guard isUp else { return }
        lift(.escape)
        heldOff = true
    }

    public func tick(now: Double) {
        guard isUp, let at = raisedAt, now - at >= safety else { return }
        lift(.timeout)
        heldOff = true
    }

    public func shutdown() { lift(.quit) }

    private func lift(_ why: LiftReason) {
        guard isUp else { return }
        tap.stop()
        screens.hide()
        isUp = false
        isBlocking = false
        raisedAt = nil
        lastLift = why
    }
}
