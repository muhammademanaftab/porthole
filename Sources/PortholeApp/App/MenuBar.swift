import AppKit
import PortholeCore

@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private unowned let app: ViewerApp

    init(app: ViewerApp) {
        self.app = app
        super.init()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        let host = app.hosting
        item.button?.image = NSImage(systemSymbolName: host?.menuSymbol ?? "macwindow", accessibilityDescription: "Porthole")
        item.button?.toolTip = host?.menuToolTip ?? "Porthole: not sharing this Mac"
        menuNeedsUpdate(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = StatusMenu.build(app.hosting?.menuModel, host: app.hosting, app: app)
        let items = fresh.items
        fresh.removeAllItems()
        menu.removeAllItems()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
    }
}
