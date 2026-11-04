import CoreGraphics
import Foundation
import PortholeCore

func fluidSizingTests() {
    var t = LiveResizeThrottle()
    expect("live resize: first drag tick is sent at once", t.during(CGSize(width: 800.4, height: 600.6), now: 10), CGSize(width: 800, height: 601))
    expect("live resize: a tick 40 ms later is held back", t.during(CGSize(width: 810, height: 600), now: 10.04), nil)
    expect("live resize: the same size is never resent", t.during(CGSize(width: 800, height: 601), now: 11), nil)
    expect("live resize: a tick after the interval goes out", t.during(CGSize(width: 820, height: 600), now: 10.04 + LiveResizeThrottle.interval), CGSize(width: 820, height: 600))
    expect("live resize: the end of the drag always sends", t.finish(CGSize(width: 830, height: 610), now: 10.13), CGSize(width: 830, height: 610))
    expect("live resize: the last sent size is remembered", t.lastSent, CGSize(width: 830, height: 610))
    var rate = LiveResizeThrottle()
    var sent = 0
    for i in 0..<120 where rate.during(CGSize(width: 400 + i, height: 300), now: Double(i) / 120) != nil { sent += 1 }
    check("live resize: a 1 s drag at 120 Hz sends 10 to 15 messages (\(sent))", (10...15).contains(sent))

    var f = SizeFollowSchedule()
    let first = f.request()
    expect("follow: the first request plans a lead check and two trailing ones", first.map(\.delay), [0.1, 0.4, 0.8])
    let second = f.request()
    expect("follow: while the lead is pending only trailing checks are added", second.map(\.delay), [0.4, 0.8])
    check("follow: a stale trailing check is skipped", !f.shouldRun(first[1].step))
    check("follow: the latest trailing check runs", f.shouldRun(second[1].step))
    check("follow: the lead check runs", f.shouldRun(first[0].step))
    expect("follow: after the lead ran a new lead is planned", f.request().first?.step, .lead)

    let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)
    let stage = CGRect(x: 1512, y: 0, width: 1920, height: 1200)
    let small = CGRect(x: 100, y: 100, width: 600, height: 400)
    expect("resize plan: a size that fits keeps the origin",
           ResizePlan.make(window: small, asked: CGSize(width: 900, height: 700), areas: [screen, stage]),
           ResizePlan(size: CGSize(width: 900, height: 700), origin: nil))
    expect("resize plan: growing past the right edge moves the window left",
           ResizePlan.make(window: small, asked: CGSize(width: 1500, height: 700), areas: [screen, stage]),
           ResizePlan(size: CGSize(width: 1500, height: 700), origin: CGPoint(x: 12, y: 100)))
    expect("resize plan: never larger than the screen it is on",
           ResizePlan.make(window: small, asked: CGSize(width: 3000, height: 2000), areas: [screen, stage]),
           ResizePlan(size: CGSize(width: 1512, height: 920), origin: CGPoint(x: 0, y: 25)))
    let parked = CGRect(x: 1512, y: 64, width: 800, height: 600)
    expect("resize plan: a window on the stage can grow to the stage size",
           ResizePlan.make(window: parked, asked: CGSize(width: 1920, height: 1100), areas: [screen, stage]),
           ResizePlan(size: CGSize(width: 1920, height: 1100), origin: nil))
    expect("resize plan: a stage window taller than the room left moves up",
           ResizePlan.make(window: parked, asked: CGSize(width: 1000, height: 1180), areas: [screen, stage]),
           ResizePlan(size: CGSize(width: 1000, height: 1180), origin: CGPoint(x: 1512, y: 20)))
    expect("resize plan: off every screen it is passed through",
           ResizePlan.make(window: CGRect(x: 9000, y: 9000, width: 10, height: 10), asked: CGSize(width: 5000, height: 5000), areas: [screen]),
           ResizePlan(size: CGSize(width: 5000, height: 5000), origin: nil))

    check("host reply: a size the app took needs no reply", !PortalSizing.hostShouldReply(asked: CGSize(width: 800, height: 600), actual: CGSize(width: 801, height: 600)))
    check("host reply: a size the app refused gets one", PortalSizing.hostShouldReply(asked: CGSize(width: 300, height: 200), actual: CGSize(width: 500, height: 300)))

    let big = CGSize(width: 1512, height: 900)
    expect("snap: the portal takes the size the host kept",
           PortalSizing.snap(asked: CGSize(width: 300, height: 200), lastSent: CGSize(width: 300, height: 200),
                             actual: CGSize(width: 500, height: 320), liveResizing: false, screen: big),
           CGSize(width: 500, height: 320))
    expect("snap: never while the user is still dragging",
           PortalSizing.snap(asked: CGSize(width: 300, height: 200), lastSent: CGSize(width: 300, height: 200),
                             actual: CGSize(width: 500, height: 320), liveResizing: true, screen: big), nil)
    expect("snap: a stale reply for an earlier drag tick is ignored",
           PortalSizing.snap(asked: CGSize(width: 300, height: 200), lastSent: CGSize(width: 640, height: 480),
                             actual: CGSize(width: 500, height: 320), liveResizing: false, screen: big), nil)
    expect("snap: a kept size larger than this screen keeps its aspect",
           PortalSizing.snap(asked: CGSize(width: 3000, height: 1800), lastSent: CGSize(width: 3000, height: 1800),
                             actual: CGSize(width: 3024, height: 1800), liveResizing: false, screen: big),
           CGSize(width: 1512, height: 900))
    expect("snap: already the same size is left alone",
           PortalSizing.snap(asked: CGSize(width: 800, height: 600), lastSent: CGSize(width: 800, height: 600),
                             actual: CGSize(width: 801, height: 600), liveResizing: false, screen: big), nil)

    var lim = PortalSizing.Limits()
    let narrow = CGSize(width: 200, height: 150)
    lim.learn(asked: narrow, actual: CGSize(width: 480, height: 150), liveResizing: true, finalAsked: narrow)
    check("limits: nothing is learned during a drag", lim == PortalSizing.Limits())
    lim.learn(asked: narrow, actual: CGSize(width: 480, height: 150), liveResizing: false, finalAsked: CGSize(width: 260, height: 150))
    check("limits: a reply for an earlier drag tick teaches nothing", lim == PortalSizing.Limits())
    lim.learn(asked: narrow, actual: CGSize(width: 480, height: 150), liveResizing: false, finalAsked: narrow)
    expect("limits: a refused narrow width after the drag becomes the minimum width", lim.minimum, CGSize(width: 480, height: 0))
    let tall = CGSize(width: 2000, height: 1600)
    lim.learn(asked: tall, actual: CGSize(width: 2000, height: 1000), liveResizing: false, finalAsked: tall)
    expect("limits: a capped height becomes the maximum height", lim.maximum.height, 1000)
    check("limits: the width stays unbounded above", lim.maximum.width > 1e9)
    lim.learn(asked: CGSize(width: 1300, height: 1150), actual: CGSize(width: 1300, height: 1150), liveResizing: false, finalAsked: CGSize(width: 1300, height: 1150))
    expect("limits: a larger size kept later relaxes the maximum", lim.maximum.height, 1150)
    lim.learn(asked: CGSize(width: 300, height: 400), actual: CGSize(width: 420, height: 400), liveResizing: false, finalAsked: CGSize(width: 300, height: 400))
    expect("limits: a smaller size kept later relaxes the minimum", lim.minimum.width, 420)
    lim.reset()
    check("limits: reset forgets everything", lim == PortalSizing.Limits())

    var cells = PortalSizing.Limits()
    for (w, h) in [(803.0, 611.0), (650.0, 433.0), (1200.0, 905.0), (500.0, 300.0)] {
        let asked = CGSize(width: w, height: h)
        let snapped = CGSize(width: (w / 7).rounded(.down) * 7, height: ((h - 22) / 17).rounded(.down) * 17 + 22)
        cells.learn(asked: asked, actual: snapped, liveResizing: false, finalAsked: asked)
    }
    check("limits: a terminal rounding down to its cell size learns no limits", cells == PortalSizing.Limits())
    var snap39 = PortalSizing.Limits()
    snap39.learn(asked: CGSize(width: 800, height: 600), actual: CGSize(width: 761, height: 600), liveResizing: false, finalAsked: CGSize(width: 800, height: 600))
    check("limits: a 39 pt snap is an increment, not a maximum", snap39 == PortalSizing.Limits())

    var lw = LatestWins<UInt32, Int>()
    check("latest wins: the first resize runs at once", lw.offer(7, 1))
    check("latest wins: one arriving while it runs waits", !lw.offer(7, 2) && !lw.offer(7, 3))
    check("latest wins: another window is independent", lw.offer(8, 1))
    expect("latest wins: the runner takes only the newest", lw.next(7), 3)
    expect("latest wins: the ones in between are dropped", lw.next(7), nil)
    check("latest wins: and the window is free again", !lw.isBusy(7) && lw.offer(7, 4))

    expect("picture: fills while dragging", PictureFit.mode(liveResizing: true, video: CGSize(width: 1600, height: 1000), view: CGSize(width: 500, height: 500), sinceResizeEnd: nil), .fill)
    expect("picture: fills just after a drag while the frame aspect is stale",
           PictureFit.mode(liveResizing: false, video: CGSize(width: 1600, height: 1000), view: CGSize(width: 1000, height: 400), sinceResizeEnd: 0.3), .fill)
    expect("picture: fits once the new frame matches",
           PictureFit.mode(liveResizing: false, video: CGSize(width: 2000, height: 800), view: CGSize(width: 1000, height: 400), sinceResizeEnd: 0.3), .fit)
    expect("picture: fits after the settle time even if the aspect differs",
           PictureFit.mode(liveResizing: false, video: CGSize(width: 1600, height: 1000), view: CGSize(width: 1000, height: 400), sinceResizeEnd: 2), .fit)
    expect("picture: fits with no picture yet", PictureFit.mode(liveResizing: false, video: nil, view: CGSize(width: 1000, height: 400), sinceResizeEnd: 0.1), .fit)

    expect("fill rect: wide content in a square overflows left and right",
           filledRect(content: CGSize(width: 1600, height: 900), in: CGRect(x: 0, y: 0, width: 900, height: 900)),
           CGRect(x: -350, y: 0, width: 1600, height: 900))
    let p = ViewerInput.point(CGPoint(x: 450, y: 450), kind: .move, contentPixels: CGSize(width: 1600, height: 900),
                              bounds: CGRect(x: 0, y: 0, width: 900, height: 900), fill: true)
    expect("fill input: the view centre maps to the picture centre", p, CGPoint(x: 0.5, y: 0.5))
    let edge = ViewerInput.point(CGPoint(x: 0, y: 0), kind: .move, contentPixels: CGSize(width: 1600, height: 900),
                                 bounds: CGRect(x: 0, y: 0, width: 900, height: 900), fill: true)
    expect("fill input: the view's left edge maps inside the cropped picture", edge.map { ($0.x * 10000).rounded() / 10000 }, 0.2188)
}
