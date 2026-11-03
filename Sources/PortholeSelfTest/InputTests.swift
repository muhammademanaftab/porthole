import AppKit
import CoreGraphics
import PortholeCore

private let deviceLeftControl: UInt = 0x0001
private let deviceLeftShift: UInt = 0x0002
private let deviceRightShift: UInt = 0x0004
private let deviceLeftCommand: UInt = 0x0008
private let deviceRightCommand: UInt = 0x0010
private let deviceLeftOption: UInt = 0x0020
private let deviceRightOption: UInt = 0x0040
private let deviceRightControl: UInt = 0x2000

private func flags(_ f: NSEvent.ModifierFlags, device: UInt = 0) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: f.rawValue | device)
}

func modifierTests() {
    expect("modifiers: wire bits shift=1 control=2 option=4 command=8",
           [Modifiers.shift, .control, .option, .command].map(\.rawValue), [1, 2, 4, 8])

    expect("cg flags: none", Modifiers().cgEventFlags, [])
    expect("cg flags: shift", Modifiers.shift.cgEventFlags, .maskShift)
    expect("cg flags: control", Modifiers.control.cgEventFlags, .maskControl)
    expect("cg flags: option is the alternate mask", Modifiers.option.cgEventFlags, .maskAlternate)
    expect("cg flags: command", Modifiers.command.cgEventFlags, .maskCommand)
    expect("cg flags: all four", Modifiers(rawValue: 15).cgEventFlags, [.maskShift, .maskControl, .maskAlternate, .maskCommand])
    expect("cg flags: unknown high bits are dropped", Modifiers(rawValue: 0xF0).cgEventFlags, [])

    expect("viewer flags: none", Modifiers(NSEvent.ModifierFlags()).rawValue, 0)
    expect("viewer flags: shift", Modifiers(NSEvent.ModifierFlags.shift).rawValue, 1)
    expect("viewer flags: control", Modifiers(NSEvent.ModifierFlags.control).rawValue, 2)
    expect("viewer flags: option", Modifiers(NSEvent.ModifierFlags.option).rawValue, 4)
    expect("viewer flags: command", Modifiers(NSEvent.ModifierFlags.command).rawValue, 8)
    expect("viewer flags: caps lock, fn and numeric pad are not sent",
           Modifiers([.shift, .command, .capsLock, .function, .numericPad, .help]).rawValue, 9)

    let sides: [(UInt16, Modifiers?)] = [(56, .shift), (60, .shift), (59, .control), (62, .control),
                                         (58, .option), (61, .option), (55, .command), (54, .command),
                                         (57, nil), (63, nil), (0, nil), (53, nil)]
    for (code, want) in sides { expect("modifier key \(code) maps to its flag", Modifiers.forKeyCode(code), want) }

    expect("host: flagsChanged key codes are exactly 54...63", Modifiers.flagKeyCodes, Set(54...63))

    let down: [(String, UInt16, NSEvent.ModifierFlags, Bool?)] = [
        ("left shift pressed alone", 56, flags(.shift, device: deviceLeftShift), true),
        ("left shift released while right shift is held", 56, flags(.shift, device: deviceRightShift), false),
        ("right shift pressed while left is held", 60, flags(.shift, device: deviceLeftShift | deviceRightShift), true),
        ("last shift released", 60, [], false),
        ("left control released while right control is held", 59, flags(.control, device: deviceRightControl), false),
        ("right control pressed", 62, flags(.control, device: deviceRightControl), true),
        ("left option pressed", 58, flags(.option, device: deviceLeftOption), true),
        ("right option released while left is held", 61, flags(.option, device: deviceLeftOption), false),
        ("right command pressed", 54, flags(.command, device: deviceRightCommand), true),
        ("left command released while right is held", 55, flags(.command, device: deviceRightCommand), false),
        ("left control pressed", 59, flags(.control, device: deviceLeftControl), true),
        ("synthetic event without device bits falls back to the generic flag", 55, .command, true),
        ("left command bit alone counts", 55, flags([], device: deviceLeftCommand), true),
        ("caps lock is not a tracked modifier", 57, .capsLock, nil),
        ("letter key is not a modifier", 0, .shift, nil),
    ]
    for (name, code, f, want) in down {
        expect("modifier down: \(name)", ViewerInput.modifierIsDown(code: code, flags: f), want)
    }
}

func mouseTests() {
    expect("mouse button: 0 left, 1 right, 2 center", [0, 1, 2].map(MouseMapping.button), [.left, .right, .center])
    expect("mouse button: unknown indexes fall back to left", [3, -1].map(MouseMapping.button), [.left, .left])

    let table: [(Message.MouseKind, Int, CGEventType)] = [
        (.down, 0, .leftMouseDown), (.down, 1, .rightMouseDown), (.down, 2, .otherMouseDown),
        (.up, 0, .leftMouseUp), (.up, 1, .rightMouseUp), (.up, 2, .otherMouseUp),
        (.drag, 0, .leftMouseDragged), (.drag, 1, .rightMouseDragged), (.drag, 2, .otherMouseDragged),
        (.move, 0, .mouseMoved), (.move, 1, .mouseMoved), (.down, 7, .leftMouseDown),
    ]
    for (kind, btn, want) in table {
        expect("mouse event: \(kind.rawValue) button \(btn)", MouseMapping.eventType(kind, button: btn), want)
    }

    expect("click state: only set for double clicks and more",
           [nil, 0, 1, 2, 3].map(MouseMapping.clickState), [nil, nil, nil, 2, 3])

    let w = MouseMapping.wheelDeltas(dx: 2.4, dy: -7.5)
    check("scroll: wheel1 is vertical, wheel2 horizontal, halves round away from zero", w.0 == -8 && w.1 == 2)
    let half = MouseMapping.wheelDeltas(dx: -0.4, dy: 0.5)
    check("scroll: 0.5 rounds to 1 and -0.4 to 0", half.0 == 1 && half.1 == 0)
    let none = MouseMapping.wheelDeltas(dx: nil, dy: nil)
    check("scroll: missing deltas are zero", none.0 == 0 && none.1 == 0)
    let huge = MouseMapping.wheelDeltas(dx: -1e10, dy: 1e10)
    check("scroll: out-of-range deltas clamp to Int32 instead of trapping", huge.0 == 2_147_483_647 && huge.1 == -2_147_483_648)
    expect("scroll: NaN is zero", MouseMapping.wheelValue(.nan), 0)
    expect("scroll: infinities clamp", [MouseMapping.wheelValue(.infinity), MouseMapping.wheelValue(-.infinity)],
           [2_147_483_647, -2_147_483_648])
    expect("scroll: just past Int32.max after rounding clamps", MouseMapping.wheelValue(2_147_483_647.6), 2_147_483_647)
    expect("scroll: exactly Int32.min is kept", MouseMapping.wheelValue(-2_147_483_648), -2_147_483_648)
}

func textTests() {
    expect("text: empty string gives no chunks", utf16Chunks("").count, 0)
    expect("text: exactly 20 units is one chunk", utf16Chunks(String(repeating: "x", count: 20)).map(\.count), [20])
    expect("text: 45 units split 20/20/5", utf16Chunks(String(repeating: "x", count: 45)).map(\.count), [20, 20, 5])
    expect("text: unicode is sent as UTF-16 units incl. surrogate pairs", utf16Chunks("é日👋"),
           [[0x00E9, 0x65E5, 0xD83D, 0xDC4B]])
    let long = String(repeating: "Renée 👋 日本 ", count: 7)
    expect("text: chunks rejoin to the original string", String(utf16CodeUnits: utf16Chunks(long).flatMap { $0 }, count: long.utf16.count), long)
}

func resizeTests() {
    expect("resize: minimum 100x80 accepted", resizeTarget(w: 100, h: 80), CGSize(width: 100, height: 80))
    expect("resize: width below 100 refused", resizeTarget(w: 99.9, h: 600), nil)
    expect("resize: height below 80 refused", resizeTarget(w: 800, h: 79.9), nil)
    expect("resize: missing height refused", resizeTarget(w: 800, h: nil), nil)
    expect("resize: zero and negative refused", resizeTarget(w: -800, h: 0), nil)
}
