import CoreGraphics
import PortholeCore

private let app = WindowOwner(pid: 500, bundle: "com.apple.TextEdit")

private func shareable(layer: Int = 0, w: CGFloat = 800, h: CGFloat = 600, owner: WindowOwner? = app,
                       myPID: Int32 = 100, myBundle: String? = "io.github.muhammademanaftab.porthole") -> Bool {
    WindowFilter.isShareable(layer: layer, size: CGSize(width: w, height: h), owner: owner, myPID: myPID, myBundle: myBundle)
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
        ("3x5 gives 2x4", CGSize(width: 3, height: 5), 1, CGSize(width: 2, height: 4)),
    ]
    for (name, points, scale, want) in sizes {
        expect("capture size: \(name)", capturePixelSize(points: points, scale: scale), want)
    }
    expect("capture size: a custom limit is honoured",
           capturePixelSize(points: CGSize(width: 1000, height: 500), scale: 1, max: CGSize(width: 500, height: 500)),
           CGSize(width: 500, height: 250))
    expect("capture size: default limit is 3840x2400", maxCapturePixels, CGSize(width: 3840, height: 2400))

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

    let sorted = WindowFilter.sortedForPicker([
        WindowInfo(id: 1, app: "Terminal", title: "zsh", bundle: nil, w: 1, h: 1),
        WindowInfo(id: 2, app: "Safari", title: "News", bundle: nil, w: 1, h: 1),
        WindowInfo(id: 3, app: "Safari", title: "Docs", bundle: nil, w: 1, h: 1),
        WindowInfo(id: 4, app: "Finder", title: "", bundle: nil, w: 1, h: 1),
    ])
    expect("window list: sorted by app, then title", sorted.map(\.id), [4, 3, 2, 1])
}
