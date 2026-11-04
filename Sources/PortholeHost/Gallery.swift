import AppKit
import PortholeCore

@MainActor
enum HostGallery {
    static func show(_ screen: String, app: HostApp) {
        switch screen {
        case "sharing": settings(app, tab: 1)
        case "help": settings(app, tab: 2)
        case "pairing": app.trust.presentNewCode()
        case "menu": menu(app)
        default: settings(app, tab: 0)
        }
    }

    private static func settings(_ app: HostApp, tab: Int) {
        let w = SettingsWindow(link: { "http://100.70.1.20:7878/?pw=gallery-password" }, password: { "gallery-password" }, trust: app.trust, guests: app.guests)
        app.settingsWindow = w
        w.present(tab: tab)
    }

    private static func menu(_ app: HostApp) {
        let model = HostMenuModel(
            state: "Sharing", macName: "Studio Mac mini", address: "100.70.1.20",
            shared: [(WindowInfo(id: 1, app: "Safari", title: "Porthole — share single windows", bundle: "com.apple.Safari", w: 1440, h: 900), 2),
                     (WindowInfo(id: 2, app: "Notes", title: "Groceries", bundle: "com.apple.Notes", w: 900, h: 640), 1)],
            screenLocked: false, screenRecording: true, accessibility: false, paired: 3)
        let menu = StatusMenu.build(model, target: app)
        NSApp.activate()
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: 200, y: (NSScreen.main?.frame.height ?? 900) - 60), in: nil)
            NSApp.terminate(nil)
        }
    }
}
