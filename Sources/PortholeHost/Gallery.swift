import AppKit
import PortholeCore

@MainActor
enum HostGallery {
    static func show(_ screen: String, app: HostApp) {
        switch screen {
        case "sharing": settings(app, tab: 1)
        case "help": settings(app, tab: 2)
        case "pairing": app.trust.presentNewCode()
        default: settings(app, tab: 0)
        }
    }

    private static func settings(_ app: HostApp, tab: Int) {
        let w = SettingsWindow(link: { "http://100.70.1.20:7878/?pw=gallery-password" }, password: { "gallery-password" }, trust: app.trust)
        app.settingsWindow = w
        w.present(tab: tab)
    }
}
