import AppKit
import PortholeCore

@MainActor
enum HostGallery {
    static func show(_ screen: String, host: HostApp, app: ViewerApp) {
        switch screen {
        case "help": settings(app, tab: .help)
        case "pairing": host.trust.presentNewCode()
        case "menu": menu(host, app: app)
        default: settings(app, tab: .sharing)
        }
    }

    private static func settings(_ app: ViewerApp, tab: SettingsWindow.Tab) {
        app.showSettings(tab: tab, link: { "http://100.70.1.20:7878/?pw=gallery-password" }, password: { "gallery-password" })
    }

    private static func menu(_ host: HostApp, app: ViewerApp) {
        let model = HostMenuModel(
            state: "Sharing", macName: "Studio Mac mini", address: "100.70.1.20",
            shared: [(WindowInfo(id: 1, app: "Safari", title: "Porthole — share single windows", bundle: "com.apple.Safari", w: 1440, h: 900), 2),
                     (WindowInfo(id: 2, app: "Notes", title: "Groceries", bundle: "com.apple.Notes", w: 900, h: 640), 1)],
            screenLocked: false, screenRecording: true, accessibility: false, paired: 3)
        let menu = StatusMenu.build(model, host: host, app: app)
        NSApp.activate()
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: 200, y: (NSScreen.main?.frame.height ?? 900) - 60), in: nil)
            NSApp.terminate(nil)
        }
    }
}
