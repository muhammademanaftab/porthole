import CoreGraphics
import PortholeCore

func titleBarTests() {
    check("title bar: follows the setting with no override", TitleBarReveal.autoHide(global: true, override: nil))
    check("title bar: a window's own choice wins over the setting", !TitleBarReveal.autoHide(global: true, override: false))
    check("title bar: a window can hide its bar with the setting off", TitleBarReveal.autoHide(global: false, override: true))

    check("title bar: the saved setting applies without the variable", TitleBarReveal.global(saved: true, environment: [:]))
    check("title bar: PORTHOLE_AUTO_HIDE_BAR=1 for this run", TitleBarReveal.global(saved: false, environment: ["PORTHOLE_AUTO_HIDE_BAR": "1"]))
    check("title bar: PORTHOLE_AUTO_HIDE_BAR=0 for this run", !TitleBarReveal.global(saved: true, environment: ["PORTHOLE_AUTO_HIDE_BAR": "0"]))

    let f = CGRect(x: 100, y: 100, width: 800, height: 600)
    expect("pointer: at the top edge is 0 from the top", TitleBarReveal.distanceFromTop(pointer: CGPoint(x: 400, y: 700), frame: f), 0)
    expect("pointer: 30 pt down", TitleBarReveal.distanceFromTop(pointer: CGPoint(x: 400, y: 670), frame: f), 30)
    expect("pointer: beside the window is nowhere", TitleBarReveal.distanceFromTop(pointer: CGPoint(x: 950, y: 690), frame: f), nil)
    expect("pointer: above the window is nowhere", TitleBarReveal.distanceFromTop(pointer: CGPoint(x: 400, y: 720), frame: f), nil)

    var r = TitleBarReveal()
    check("reveal: hidden to start", !r.shown)
    check("reveal: the middle of the picture keeps it hidden", !r.pointer(distanceFromTop: 200, now: 0))
    check("reveal: near the top edge slides it in", r.pointer(distanceFromTop: 3, now: 1))
    check("reveal: moving onto the bar keeps it", r.pointer(distanceFromTop: 30, now: 2))
    check("reveal: just after leaving it stays a moment", r.pointer(distanceFromTop: 300, now: 3))
    check("reveal: still there before the delay", r.pointer(distanceFromTop: 300, now: 3 + TitleBarReveal.hideDelay - 0.1))
    check("reveal: tucked away after the delay", !r.pointer(distanceFromTop: 300, now: 3 + TitleBarReveal.hideDelay))
    r.pointer(distanceFromTop: 0, now: 10)
    r.pointer(distanceFromTop: nil, now: 10.2)
    check("reveal: coming back in time cancels the hide", r.pointer(distanceFromTop: 20, now: 10.5) && r.pointer(distanceFromTop: 20, now: 12))
    check("reveal: leaving the window hides it after the delay", r.pointer(distanceFromTop: nil, now: 13) && !r.pointer(distanceFromTop: nil, now: 13.7))
    r.pointer(distanceFromTop: 0, now: 20)
    r.hide()
    check("reveal: hide() tucks it at once", !r.shown)
    check("reveal: a pointer resting lower down does not bring it back", !r.pointer(distanceFromTop: 30, now: 21))
}
