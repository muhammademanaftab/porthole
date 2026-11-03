import AppKit
import PortholeCore

private func near(_ a: CGPoint?, _ x: CGFloat, _ y: CGFloat) -> Bool {
    guard let a else { return false }
    return abs(a.x - x) < 1e-9 && abs(a.y - y) < 1e-9
}

func viewerTests() {
    let view = CGRect(x: 0, y: 0, width: 800, height: 600)
    let pixels = CGSize(width: 1600, height: 900)
    check("viewer point: press on the top letterbox bar is ignored",
          ViewerInput.point(CGPoint(x: 400, y: 50), kind: .down, contentPixels: pixels, bounds: view) == nil)
    check("viewer point: release on the bar clamps to the top edge",
          near(ViewerInput.point(CGPoint(x: 400, y: 50), kind: .up, contentPixels: pixels, bounds: view), 0.5, 0))
    check("viewer point: drag on the bar clamps to the top edge",
          near(ViewerInput.point(CGPoint(x: 400, y: 50), kind: .drag, contentPixels: pixels, bounds: view), 0.5, 0))
    check("viewer point: press on the picture's top edge is (0.5, 0)",
          near(ViewerInput.point(CGPoint(x: 400, y: 75), kind: .down, contentPixels: pixels, bounds: view), 0.5, 0))
    check("viewer point: before the first frame the whole view is the picture",
          near(ViewerInput.point(CGPoint(x: 400, y: 150), kind: .down, contentPixels: .zero, bounds: view), 0.5, 0.25))
    check("viewer point: scroll (no kind) on the bar is ignored",
          ViewerInput.point(CGPoint(x: 400, y: 50), kind: nil, contentPixels: pixels, bounds: view) == nil)

    let t0 = Date(timeIntervalSince1970: 1000)
    check("viewer move throttle: exactly 1/60 s later is dropped",
          !ViewerInput.shouldSendMove(now: t0.addingTimeInterval(1.0 / 60), last: t0))
    check("viewer move throttle: 17 ms later is sent", ViewerInput.shouldSendMove(now: t0.addingTimeInterval(0.017), last: t0))

    let at = CGPoint(x: 0.25, y: 0.75)
    let move = ViewerInput.mouseMessage(win: 3, kind: .move, button: 0, at: at, mods: 1, clickCount: 2)
    check("viewer mouse: move is unreliable and carries no click count", !move.reliable && move.message.clicks == nil
          && move.message.kind == .move && move.message.x == 0.25 && move.message.y == 0.75 && move.message.mods == 1)
    let drag = ViewerInput.mouseMessage(win: 3, kind: .drag, button: 1, at: at, mods: 0, clickCount: 2)
    check("viewer mouse: drag is reliable and carries no click count", drag.reliable && drag.message.clicks == nil && drag.message.btn == 1)
    let down = ViewerInput.mouseMessage(win: 3, kind: .down, button: 0, at: at, mods: 0, clickCount: 2)
    check("viewer mouse: down is reliable with the click count", down.reliable && down.message.clicks == 2 && down.message.win == 3)
    let up = ViewerInput.mouseMessage(win: 3, kind: .up, button: 2, at: at, mods: 0, clickCount: 3)
    check("viewer mouse: up is reliable with the click count", up.reliable && up.message.clicks == 3 && up.message.btn == 2)

    let precise = ViewerInput.scrollPixels(dx: 3, dy: -2.5, precise: true)
    check("viewer scroll: trackpad pixel deltas pass through", precise.dx == 3 && precise.dy == -2.5)
    let lines = ViewerInput.scrollPixels(dx: 1, dy: -2, precise: false)
    check("viewer scroll: wheel lines become 16 px, same as the browser", lines.dx == 16 && lines.dy == -32)

    check("key equivalent: Cmd+Q stays local", ViewerInput.keyEquivalentStaysLocal(.command, characters: "q"))
    check("key equivalent: Cmd+W is forwarded", !ViewerInput.keyEquivalentStaysLocal(.command, characters: "w"))
    check("key equivalent: Ctrl+Q is forwarded", !ViewerInput.keyEquivalentStaysLocal(.control, characters: "q"))
    check("key equivalent: Cmd+Option+Q stays local", ViewerInput.keyEquivalentStaysLocal([.command, .option], characters: "q"))

    let args: [(String, [String], String?, String?)] = [
        ("host then password", ["mini", "pw"], "mini", "pw"),
        ("password starting with a dash", ["mini", "-abc"], "mini", "-abc"),
        ("Xcode debug flags with values are skipped", ["-NSDocumentRevisionsDebugMode", "YES", "mini", "pw"], "mini", "pw"),
        ("persistence flag with value is skipped", ["mini", "-ApplePersistenceIgnoreState", "YES", "-pw"], "mini", "-pw"),
        ("Finder process serial number is skipped", ["-psn_0_12345", "mini", "pw"], "mini", "pw"),
        ("host only", ["mini"], "mini", nil),
        ("nothing", [], nil, nil),
    ]
    for (name, a, host, pw) in args {
        let r = viewerArguments(a)
        check("viewer args: \(name)", r.host == host && r.password == pw)
    }

    expect("short host name: first label", shortHostName("air.local"), "air")
    expect("short host name: no dots", shortHostName("air"), "air")
    expect("short host name: empty becomes mac", shortHostName(""), "mac")
    expect("short host name: leading dot becomes mac", shortHostName(".local"), "mac")
}
