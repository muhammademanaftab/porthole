import Foundation

public enum GuestKeys {
    static let space: UInt16 = 49
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let arrows: Set<UInt16> = [123, 124, 125, 126]
    static let digits: Set<UInt16> = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    static let systemKeys: Set<UInt16> = [160, 131, 130]
    static let q: UInt16 = 12
    static let d: UInt16 = 2

    public static func isSystemShortcut(code: UInt16, mods: Modifiers) -> Bool {
        if systemKeys.contains(code) { return true }
        let command = mods.contains(.command), control = mods.contains(.control), option = mods.contains(.option), shift = mods.contains(.shift)
        if code == space && (command || control) { return true }
        if code == tab && command { return true }
        if code == escape && command && option { return true }
        if arrows.contains(code) && control { return true }
        if digits.contains(code) && control { return true }
        if digits.contains(code) && command && shift { return true }
        if functionKeys.contains(code) && (control || command) { return true }
        if code == 103 || code == 111 { return true }
        if code == q && command && (control || shift) { return true }
        if code == d && command && option { return true }
        return false
    }

    public static func mayType(frontmostPID: Int32?, focusedWindow: UInt32?, focusedElementPID: Int32?, window: UInt32, owner: Int32) -> Bool {
        guard frontmostPID == owner, focusedWindow == window else { return false }
        if let focusedElementPID, focusedElementPID != owner { return false }
        return true
    }
}
