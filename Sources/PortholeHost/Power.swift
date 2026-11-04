import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import PortholeCore

enum Power {
    private static var assertions: [IOPMAssertionID] = []

    static func keepAwake() {
        guard assertions.isEmpty else { return }
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Porthole Host is sharing windows" as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        Log.info("power: keeping display and system awake (\(assertions.count) assertions)")
    }

    static func allowSleep() {
        for id in assertions { IOPMAssertionRelease(id) }
        if !assertions.isEmpty { Log.info("power: display and system may sleep again") }
        assertions.removeAll()
    }

    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Porthole Host waking the display" as CFString, kIOPMUserActiveLocal, &id)
    }
}

enum Session {
    static var isScreenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false)
    }

    static let lockedListMessage = LockNotice.list

    static let lockedMessage = LockNotice.control
}
