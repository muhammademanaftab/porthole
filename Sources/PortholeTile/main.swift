import AppKit
import PortholeCore

@MainActor
final class TileApp: NSObject, NSApplicationDelegate {
    let token: String
    let viewer: pid_t
    private var watch: DispatchSourceProcess?

    init(token: String, viewer: pid_t) {
        self.token = token
        self.viewer = viewer
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if let url = Bundle.main.url(forResource: TileBundle.iconFile, withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        setUpMainMenu()
        let source = DispatchSource.makeProcessSource(identifier: viewer, eventMask: .exit, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        watch = source
        if kill(viewer, 0) != 0 { NSApp.terminate(nil) }
    }

    func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? TileBundle.fallbackName
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    func post(_ kind: TileEvent.Kind) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(TileEvent.notification), object: String(viewer),
            userInfo: TileEvent(kind, token: token).userInfo, deliverImmediately: true)
    }

    func handOff() {
        post(.activate)
        guard let app = NSRunningApplication(processIdentifier: viewer) else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    func applicationDidBecomeActive(_ note: Notification) { handOff() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        handOff()
        return false
    }

    func applicationWillTerminate(_ note: Notification) { post(.quit) }
}

guard let args = TileArguments.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: \(TileBundle.executable) --tile <token> --viewer <pid>\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = TileApp(token: args.token, viewer: args.viewer)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
