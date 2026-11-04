import CoreGraphics
import Foundation
import PortholeCore

final class FakeTap: CurtainTap {
    var allowed = true
    var running = false
    var starts = 0
    var stops = 0
    var escape: (() -> Void)?
    var injected: [(CGEventType, UInt16, CGEventFlags, Int64)] = []
    var delivered: [CGEventType] = []

    func start(onEscape: @escaping () -> Void) -> Bool {
        starts += 1
        guard allowed else { return false }
        running = true
        escape = onEscape
        return true
    }

    func stop() {
        stops += 1
        running = false
        escape = nil
    }

    func feed(_ type: CGEventType, key: UInt16 = 0, flags: CGEventFlags = [], tag: Int64 = 0) {
        guard running else { delivered.append(type); return }
        switch CurtainFilter.verdict(type: type, keyCode: key, flags: flags, userData: tag) {
        case .pass, .reenable, .expired: delivered.append(type)
        case .block: break
        case .escape:
            running = false
            escape?()
        }
    }
}

final class FakeScreens: CurtainScreens {
    var shown: [CurtainNotice] = []
    var hides = 0
    var visible = false
    func show(_ notice: CurtainNotice) { shown.append(notice); visible = true }
    func hide() { hides += 1; visible = false }
}

func curtainTests() {
    check("curtain: off by default", !CurtainSetting.enabled(stored: nil, environment: [:]))
    check("curtain: the remembered switch turns it on", CurtainSetting.enabled(stored: true, environment: [:]))
    check("curtain: PORTHOLE_CURTAIN=0 wins for one run", !CurtainSetting.enabled(stored: true, environment: ["PORTHOLE_CURTAIN": "0"]))
    check("curtain: PORTHOLE_CURTAIN=1 wins for one run", CurtainSetting.enabled(stored: false, environment: ["PORTHOLE_CURTAIN": "1"]))

    let tag = PortholeEventTag.value
    let esc: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    expect("filter: a local key is blocked", CurtainFilter.verdict(type: .keyDown, keyCode: 0, flags: [], userData: 0), .block)
    expect("filter: a local click is blocked", CurtainFilter.verdict(type: .leftMouseDown, keyCode: 0, flags: [], userData: 0), .block)
    expect("filter: local pointer moves are blocked", CurtainFilter.verdict(type: .mouseMoved, keyCode: 0, flags: [], userData: 0), .block)
    expect("filter: local scrolling is blocked", CurtainFilter.verdict(type: .scrollWheel, keyCode: 0, flags: [], userData: 0), .block)
    expect("filter: local modifier changes are blocked", CurtainFilter.verdict(type: .flagsChanged, keyCode: 56, flags: .maskShift, userData: 0), .block)
    expect("filter: Porthole's own key passes", CurtainFilter.verdict(type: .keyDown, keyCode: 0, flags: [], userData: tag), .pass)
    expect("filter: Porthole's own click passes", CurtainFilter.verdict(type: .leftMouseDown, keyCode: 0, flags: [], userData: tag), .pass)
    expect("filter: Porthole's own scroll passes", CurtainFilter.verdict(type: .scrollWheel, keyCode: 0, flags: [], userData: tag), .pass)
    expect("filter: another app's tag is still blocked", CurtainFilter.verdict(type: .keyDown, keyCode: 0, flags: [], userData: tag + 1), .block)
    expect("filter: Control-Option-Command-Escape takes the Mac back", CurtainFilter.verdict(type: .keyDown, keyCode: 53, flags: esc, userData: 0), .escape)
    expect("filter: the combo with Shift also works", CurtainFilter.verdict(type: .keyDown, keyCode: 53, flags: esc.union(.maskShift), userData: 0), .escape)
    expect("filter: Option-Command-Escape (Force Quit) alone does not", CurtainFilter.verdict(type: .keyDown, keyCode: 53, flags: [.maskAlternate, .maskCommand], userData: 0), .block)
    expect("filter: a viewer can't send the escape combo", CurtainFilter.verdict(type: .keyDown, keyCode: 53, flags: esc, userData: tag), .pass)
    expect("filter: key up of Escape is not the escape", CurtainFilter.verdict(type: .keyUp, keyCode: 53, flags: esc, userData: 0), .block)
    expect("filter: a disabled tap is switched back on", CurtainFilter.verdict(type: .tapDisabledByTimeout, keyCode: 0, flags: [], userData: 0), .reenable)
    expect("filter: other events pass", CurtainFilter.verdict(type: .null, keyCode: 0, flags: [], userData: 0), .pass)
    for (raw, name) in [(UInt32(14), "media and system keys"), (29, "trackpad gestures"), (30, "magnify"), (31, "swipe"), (18, "rotate"), (32, "smart magnify"), (34, "pressure")] {
        let t = CGEventType(rawValue: raw)!
        expect("filter: local \(name) are blocked", CurtainFilter.verdict(type: t, keyCode: 0, flags: [], userData: 0), .block)
        check("filter: the tap mask covers \(name)", CurtainFilter.mask & (CGEventMask(1) << CGEventMask(raw)) != 0)
    }
    expect("filter: the tap thread stops blocking by itself after the safety time",
           CurtainFilter.verdict(type: .keyDown, keyCode: 0, flags: [], userData: 0, elapsed: 1800, limit: 1800), .expired)
    expect("filter: still blocking just before the safety time",
           CurtainFilter.verdict(type: .keyDown, keyCode: 0, flags: [], userData: 0, elapsed: 1799.9, limit: 1800), .block)
    check("filter: the tap mask covers keys, buttons, moves and scrolling",
          [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseUp, .mouseMoved, .leftMouseDragged, .scrollWheel]
            .allSatisfy { CurtainFilter.mask & (CGEventMask(1) << CGEventMask($0.rawValue)) != 0 })

    let tap = FakeTap(), screens = FakeScreens()
    let c = CurtainController(tap: tap, screens: screens, safety: 1800)
    check("curtain: a new host starts with no curtain", !c.isUp && !screens.visible && !tap.running)
    c.update(enabled: true, liveScreens: 0, viewer: nil, now: 0)
    check("curtain: switched on with no Whole Mac portal shows nothing", !c.isUp && screens.shown.isEmpty && tap.starts == 0)
    c.update(enabled: false, liveScreens: 1, viewer: "Laptop", now: 1)
    check("curtain: switched off never shows during a Whole Mac portal", !c.isUp && screens.shown.isEmpty && tap.starts == 0)
    c.update(enabled: true, liveScreens: 1, viewer: "Laptop", now: 2)
    check("curtain: raised for a live Whole Mac portal", c.isUp && c.isBlocking && screens.visible && tap.running)
    check("curtain: the notice names the viewer and the way out",
          screens.shown.last?.message.contains("Laptop") == true && screens.shown.last?.hint.contains("Control-Option-Command-Escape") == true)
    c.update(enabled: true, liveScreens: 2, viewer: "Laptop", now: 3)
    expect("curtain: a second portal does not raise it twice", screens.shown.count, 1)
    tap.feed(.keyDown, key: 0)
    tap.feed(.leftMouseDown)
    tap.feed(.keyDown, key: 0, tag: PortholeEventTag.value)
    tap.feed(.mouseMoved, tag: PortholeEventTag.value)
    expect("curtain: only the viewer's tagged events get through", tap.delivered, [.keyDown, .mouseMoved])
    c.update(enabled: true, liveScreens: 0, viewer: nil, now: 4)
    check("curtain: lifts when the portal closes", !c.isUp && !screens.visible && !tap.running && c.lastLift == .portalClosed)
    tap.feed(.keyDown, key: 0)
    expect("curtain: local typing works again once lifted", tap.delivered.last, .keyDown)

    c.onEscape = { [weak c] in c?.escape() }
    c.update(enabled: true, liveScreens: 1, viewer: "Laptop", now: 10)
    check("curtain: raised again for a new portal", c.isUp)
    tap.feed(.keyDown, key: 53, flags: [.maskControl, .maskAlternate, .maskCommand])
    check("curtain: the local key combo lifts it", !c.isUp && !screens.visible && !tap.running && c.lastLift == .escape)
    c.update(enabled: true, liveScreens: 1, viewer: "Laptop", now: 11)
    check("curtain: stays down after the escape while that portal lives", !c.isUp && c.heldOff)
    c.update(enabled: true, liveScreens: 0, viewer: nil, now: 12)
    c.update(enabled: true, liveScreens: 1, viewer: "Laptop", now: 13)
    check("curtain: a later portal raises it again", c.isUp)
    c.update(enabled: false, liveScreens: 1, viewer: "Laptop", now: 14)
    check("curtain: switching it off lifts it at once", !c.isUp && c.lastLift == .settingOff)
    c.update(enabled: true, liveScreens: 1, viewer: "Laptop", now: 100)
    c.tick(now: 100 + 1799)
    check("curtain: still up just before the safety timeout", c.isUp)
    c.tick(now: 100 + 1800)
    check("curtain: lifts itself after 30 minutes", !c.isUp && c.lastLift == .timeout && !tap.running)
    c.update(enabled: true, liveScreens: 1, viewer: "Laptop", now: 1901)
    check("curtain: does not come back after the timeout during the same portal", !c.isUp)
    c.update(enabled: true, liveScreens: 0, viewer: nil, now: 1902)
    c.update(enabled: true, liveScreens: 1, viewer: "Laptop", now: 1903)
    c.shutdown()
    check("curtain: quitting the host lifts it", !c.isUp && !tap.running && c.lastLift == .quit)
    expect("curtain: the safety timeout is 30 minutes", CurtainController.safetySeconds, 1800)

    let noAX = FakeTap(); noAX.allowed = false
    let s2 = FakeScreens()
    let c2 = CurtainController(tap: noAX, screens: s2)
    c2.update(enabled: true, liveScreens: 1, viewer: nil, now: 0)
    check("curtain: without Accessibility it still hides the screen but says input isn't paused",
          c2.isUp && !c2.isBlocking && s2.shown.last?.message.contains("paused") == false)
    c2.update(enabled: true, liveScreens: 0, viewer: nil, now: 1)
    check("curtain: and lifts the same way", !c2.isUp && !s2.visible)
}
