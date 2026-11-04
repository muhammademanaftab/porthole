import CoreGraphics
import PortholeCore

func fullscreenTests() {
    expect("fullscreen policy: stage by default", FullscreenPolicy(environment: [:]), .stage)
    expect("fullscreen policy: leave from the environment", FullscreenPolicy(environment: ["PORTHOLE_FULLSCREEN_POLICY": "leave"]), .leave)
    expect("fullscreen policy: case does not matter", FullscreenPolicy(environment: ["PORTHOLE_FULLSCREEN_POLICY": "Leave"]), .leave)
    expect("fullscreen policy: junk means stage", FullscreenPolicy(environment: ["PORTHOLE_FULLSCREEN_POLICY": "keep"]), .stage)
    check("fullscreen policy: stage takes a full-screen window out first", FullscreenPolicy.stage.shouldExit(isFullscreen: true))
    check("fullscreen policy: a normal window is left alone", !FullscreenPolicy.stage.shouldExit(isFullscreen: false))
    check("fullscreen policy: leave never exits", !FullscreenPolicy.leave.shouldExit(isFullscreen: true))

    let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
    check("picker: an off-screen window covering a whole display is a full-screen one in another Space",
          FullscreenPolicy.listed(onScreen: false, bounds: CGRect(x: 1512, y: 0, width: 2560, height: 1440), displays: displays))
    check("picker: other off-screen windows stay hidden",
          !FullscreenPolicy.listed(onScreen: false, bounds: CGRect(x: 1512, y: 25, width: 2560, height: 1415), displays: displays))
    check("picker: on-screen windows are always listed",
          FullscreenPolicy.listed(onScreen: true, bounds: CGRect(x: 10, y: 10, width: 300, height: 200), displays: displays))

    let before = CGRect(x: 0, y: 0, width: 1512, height: 982)
    check("exit: still full screen is not done", !FullscreenPolicy.exitDone(stillFullscreen: true, before: before, now: before))
    check("exit: an unknown attribute is not done", !FullscreenPolicy.exitDone(stillFullscreen: nil, before: before, now: before))
    check("exit: out of full screen but not yet moved waits for the frame", !FullscreenPolicy.exitDone(stillFullscreen: false, before: before, now: before))
    check("exit: out and at its old size is done",
          FullscreenPolicy.exitDone(stillFullscreen: false, before: before, now: CGRect(x: 200, y: 120, width: 900, height: 600)))
}
