import CoreGraphics
import Foundation
import PortholeCore
import ScreenCaptureKit

private let app = WindowOwner(pid: 500, bundle: "com.apple.TextEdit")

private func shareable(layer: Int = 0, w: CGFloat = 800, h: CGFloat = 600, owner: WindowOwner? = app,
                       myPID: Int32 = 100, myBundle: String? = "io.github.muhammademanaftab.porthole") -> Bool {
    WindowFilter.isShareable(layer: layer, size: CGSize(width: w, height: h), owner: owner, myPID: myPID, myBundle: myBundle)
}

private func info(_ id: UInt32, _ app: String, _ title: String) -> WindowInfo {
    WindowInfo(id: id, app: app, title: title, bundle: nil, w: 1, h: 1)
}

func captureTests() {
    let sizes: [(String, CGSize, CGFloat, CGSize)] = [
        ("Retina doubles points", CGSize(width: 800, height: 600), 2, CGSize(width: 1600, height: 1200)),
        ("odd pixel sizes round down to even", CGSize(width: 1001, height: 501), 1, CGSize(width: 1000, height: 500)),
        ("fractional scale floors then evens", CGSize(width: 1001, height: 667), 1.5, CGSize(width: 1500, height: 1000)),
        ("exactly the 3840x2400 cap is kept", CGSize(width: 1920, height: 1200), 2, CGSize(width: 3840, height: 2400)),
        ("16:10 above the cap scales to the cap", CGSize(width: 2560, height: 1600), 2, CGSize(width: 3840, height: 2400)),
        ("very wide is limited by width, aspect kept", CGSize(width: 3000, height: 1000), 2, CGSize(width: 3840, height: 1280)),
        ("very tall is limited by height, aspect kept", CGSize(width: 1000, height: 3000), 1, CGSize(width: 800, height: 2400)),
        ("zero size gives the 2x2 minimum", .zero, 2, CGSize(width: 2, height: 2)),
        ("1x1 gives the 2x2 minimum", CGSize(width: 1, height: 1), 1, CGSize(width: 2, height: 2)),
        ("tiny odd sizes round down to even", CGSize(width: 3, height: 5), 1, CGSize(width: 2, height: 4)),
    ]
    for (name, points, scale, want) in sizes {
        expect("capture size: \(name)", capturePixelSize(points: points, scale: scale), want)
    }
    expect("capture size: a custom limit is honoured",
           capturePixelSize(points: CGSize(width: 1000, height: 500), scale: 1, max: CGSize(width: 500, height: 500)),
           CGSize(width: 500, height: 250))

    check("window filter: ordinary app window is shareable", shareable())
    check("window filter: non-zero layer (menus, panels) excluded", !shareable(layer: 1) && !shareable(layer: -1))
    check("window filter: 60x40 is the smallest accepted", shareable(w: 60, h: 40))
    check("window filter: narrower than 60 excluded", !shareable(w: 59.5))
    check("window filter: shorter than 40 excluded", !shareable(h: 39.5))
    check("window filter: window without an owning app excluded", !shareable(owner: nil))
    check("window filter: own process excluded", !shareable(owner: WindowOwner(pid: 100, bundle: "x.other")))
    check("window filter: own bundle excluded even in another process",
          !shareable(owner: WindowOwner(pid: 7, bundle: "io.github.muhammademanaftab.porthole")))
    for bundle in ["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
                   "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal"] {
        check("window filter: password manager \(bundle) excluded", !shareable(owner: WindowOwner(pid: 7, bundle: bundle)))
    }
    for bundle in ["com.apple.dock", "com.apple.WindowManager"] {
        check("window filter: system \(bundle) excluded", !shareable(owner: WindowOwner(pid: 7, bundle: bundle)))
    }
    check("window filter: bundle match is exact", shareable(owner: WindowOwner(pid: 7, bundle: "com.apple.Passwords.helper")))

    expect("window list: sorted by app, then title",
           WindowFilter.sortedForPicker([info(1, "Terminal", "zsh"), info(2, "Safari", "News"), info(3, "Safari", "Docs"),
                                         info(4, "Finder", "")]).map(\.id), [4, 3, 2, 1])
    expect("window list: app order ignores case and wins over title",
           WindowFilter.sortedForPicker([info(1, "Beta", "aaa"), info(2, "Alpha", "zzz")]).map(\.id), [2, 1])
    expect("window list: lowercase app names are not pushed after uppercase",
           WindowFilter.sortedForPicker([info(1, "Zed", ""), info(2, "iTerm2", "")]).map(\.id), [2, 1])
    expect("window list: numbers in titles sort naturally",
           WindowFilter.sortedForPicker([info(1, "Notes", "Doc 10"), info(2, "Notes", "Doc 2")]).map(\.id), [2, 1])
    expect("window list: identical app and title keep window id order",
           WindowFilter.sortedForPicker([info(9, "Safari", "Tab"), info(3, "Safari", "Tab"), info(5, "Safari", "Tab")]).map(\.id), [3, 5, 9])
}

func pacingTests() {
    expect("capture resend: keepalive after 1 s without a frame", CapturePacing.resendAfter, 1.0)
    check("capture frames: complete frames are accepted", CapturePacing.acceptsFrame(status: SCFrameStatus.complete.rawValue))
    for s in [SCFrameStatus.idle, .blank, .suspended, .started, .stopped] {
        check("capture frames: status \(s.rawValue) is skipped", !CapturePacing.acceptsFrame(status: s.rawValue))
    }
    check("capture frames: missing or unknown status is skipped",
          !CapturePacing.acceptsFrame(status: nil) && !CapturePacing.acceptsFrame(status: 99))
    expect("capture resize: follow-up checks at 0.15, 0.4 and 0.8 s", CapturePacing.followSizeDelays, [0.15, 0.4, 0.8])

    let primary = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    let right = ScreenInfo(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), scale: 1)
    let above = ScreenInfo(frame: CGRect(x: 0, y: 900, width: 1920, height: 1080), scale: 1)
    expect("screen flip: CG top-left rect becomes AppKit bottom-left",
           appKitRect(fromCG: CGRect(x: 100, y: 100, width: 800, height: 600), primaryHeight: 900),
           CGRect(x: 100, y: 200, width: 800, height: 600))
    expect("screen scale: window on the Retina primary", backingScale(forCGBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                                                                      screens: [primary, right]), 2)
    expect("screen scale: window on the display to the right", backingScale(forCGBounds: CGRect(x: 1600, y: 100, width: 800, height: 600),
                                                                            screens: [primary, right]), 1)
    expect("screen scale: straddling window uses the screen holding most of it",
           backingScale(forCGBounds: CGRect(x: 1000, y: 100, width: 1000, height: 600), screens: [primary, right]), 1)
    expect("screen scale: window above the primary needs the y flip",
           backingScale(forCGBounds: CGRect(x: 100, y: -500, width: 800, height: 400), screens: [primary, above]), 1)
    expect("screen scale: off-screen window falls back to the primary",
           backingScale(forCGBounds: CGRect(x: -5000, y: -5000, width: 10, height: 10), screens: [primary, right]), 2)
    expect("screen scale: no screens gives nil", backingScale(forCGBounds: .zero, screens: []), nil)

    let cgAbove = ScreenInfo(frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), scale: 1)
    let stage = ScreenInfo(frame: CGRect(x: 3360, y: 0, width: 1512, height: 982), scale: 2)
    expect("display scale: CG display bounds need no flip", backingScale(forCGBounds: CGRect(x: 100, y: -500, width: 800, height: 400),
                                                                      displays: [primary, cgAbove]), 1)
    expect("display scale: window on the Retina primary", backingScale(forCGBounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                                                                      displays: [primary, cgAbove]), 2)
    expect("display scale: window parked on the 2x stage", backingScale(forCGBounds: CGRect(x: 3400, y: 50, width: 900, height: 600),
                                                                       displays: [primary, right, stage]), 2)
    expect("display scale: straddling window uses the display holding most of it",
           backingScale(forCGBounds: CGRect(x: 1000, y: 100, width: 1000, height: 600), displays: [primary, right]), 1)
    expect("display scale: off-screen window falls back to the first display",
           backingScale(forCGBounds: CGRect(x: -5000, y: -5000, width: 10, height: 10), displays: [right, primary]), 1)
    expect("display scale: no displays gives nil", backingScale(forCGBounds: .zero, displays: []), nil)
}
