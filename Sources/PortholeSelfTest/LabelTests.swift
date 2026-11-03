import CoreGraphics
import PortholeCore

func labelTests() {
    let titled = WindowInfo(id: 1, app: "TextEdit", title: "Notes", bundle: nil, w: 1, h: 1)
    let untitled = WindowInfo(id: 2, app: "Finder", title: "", bundle: nil, w: 1, h: 1)
    expect("picker label: app and title", titled.pickerLabel, "TextEdit — Notes")
    expect("picker label: untitled shows the app only", untitled.pickerLabel, "Finder")
    expect("portal title: title, app and host", titled.portalTitle(host: "mini"), "Notes · TextEdit (mini)")
    expect("portal title: untitled", untitled.portalTitle(host: "100.64.0.1"), "Finder (100.64.0.1)")

    expect("menu title: nothing open", hostMenuTitle(state: "Sharing", openWindows: 0), "Porthole: Sharing")
    expect("menu title: one window is singular", hostMenuTitle(state: "Sharing", openWindows: 1), "Porthole: Sharing · 1 window open")
    expect("menu title: several windows are plural", hostMenuTitle(state: "Sharing", openWindows: 3), "Porthole: Sharing · 3 windows open")

    let screen = CGSize(width: 1440, height: 900)
    expect("portal size: fits unchanged", portalContentSize(remote: CGSize(width: 800, height: 600), screen: screen),
           CGSize(width: 800, height: 600))
    expect("portal size: tiny windows grow to 320x200", portalContentSize(remote: CGSize(width: 100, height: 0), screen: screen),
           CGSize(width: 320, height: 200))
    expect("portal size: huge windows shrink to the screen", portalContentSize(remote: CGSize(width: 3000, height: 2000), screen: screen),
           screen)
}
