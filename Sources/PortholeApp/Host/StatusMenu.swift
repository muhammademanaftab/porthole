import AppKit
import PortholeCore

struct HostMenuModel {
    var state: String
    var macName: String
    var address: String?
    var shared: [(info: WindowInfo, viewers: Int)]
    var screenLocked: Bool
    var screenRecording: Bool
    var accessibility: Bool
    var paired: Int
    var shareLinks = 0
    var allowControl = false
    var controlOverridden = false
    var asks: [(who: String, label: String)] = []
}

@MainActor
enum StatusMenu {
    static func build(_ m: HostMenuModel?, host: HostApp?, app: ViewerApp) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let m, let host { addHost(m, to: menu, target: host) } else { addNotSharing(to: menu, app: app) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Viewing Other Macs"))
        if app.connection != nil {
            add(menu, "Show Windows on \(app.hostName)", #selector(ViewerApp.showPicker), "0", app, symbol: "square.grid.2x2")
        }
        add(menu, "Connect to a Mac…", #selector(ViewerApp.connectToHost), "k", app, symbol: "desktopcomputer.and.arrow.down")
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(ViewerApp.showSettings as (ViewerApp) -> () -> Void), ",", app)
        add(menu, "Quit Porthole", #selector(ViewerApp.quitApp), "q", app)
        return menu
    }

    private static func addNotSharing(to menu: NSMenu, app: ViewerApp) {
        let status = info("Not sharing this Mac", bold: true)
        status.image = dot(.systemGray)
        menu.addItem(status)
        menu.addItem(info(HTTPServer.computerName, bold: false))
        menu.addItem(.separator())
        add(menu, "Share This Mac…", #selector(ViewerApp.showSharingSettings), "", app, symbol: "macwindow.on.rectangle")
    }

    private static func addHost(_ m: HostMenuModel, to menu: NSMenu, target: HostApp) {

        let ok = m.state == "Sharing"
        let failed = m.state.hasPrefix("Error")
        let status = info(hostStatusLine(state: m.state, openWindows: m.shared.count), bold: true)
        status.image = dot(failed ? .systemRed : ok ? .systemGreen : .systemOrange)
        menu.addItem(status)
        menu.addItem(info([m.macName, m.address].compactMap { $0 }.joined(separator: " · "), bold: false))
        if m.screenLocked {
            let lock = info("Screen is locked: viewers can watch but not type", bold: false)
            lock.image = symbol("lock.fill", .systemOrange)
            menu.addItem(lock)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Shared Windows"))
        if m.shared.isEmpty {
            menu.addItem(info("None right now", bold: false))
        }
        for (window, viewers) in m.shared {
            let item = NSMenuItem(title: window.pickerLabel, action: nil, keyEquivalent: "")
            let title = NSMutableAttributedString(string: window.displayTitle, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            let extra = [window.title.isEmpty ? nil : window.app, viewerCountLabel(viewers).isEmpty ? nil : viewerCountLabel(viewers)]
                .compactMap { $0 }.joined(separator: " · ")
            if !extra.isEmpty {
                title.append(NSAttributedString(string: "  \(extra)", attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                                                    .foregroundColor: NSColor.secondaryLabelColor]))
            }
            item.attributedTitle = title
            item.image = appIcon(window.bundle)
            item.isEnabled = true
            item.toolTip = window.pickerLabel
            menu.addItem(item)
        }

        if !m.asks.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Asking to Control"))
            for ask in m.asks {
                let allow = add(menu, "Allow Guest of \(ask.label)", #selector(HostApp.allowAsk(_:)), "", target, symbol: "hand.raised")
                allow.representedObject = ask.who
                let deny = add(menu, "Don't Allow", #selector(HostApp.denyAsk(_:)), "", target)
                deny.representedObject = ask.who
                deny.indentationLevel = 1
            }
        }

        menu.addItem(.separator())
        add(menu, "Share Window…", #selector(HostApp.shareWindow), "", target, symbol: "square.and.arrow.up")
        add(menu, "Share Picker…", #selector(HostApp.sharePicker), "", target, symbol: "square.grid.2x2")
        add(menu, m.shareLinks == 0 ? "Shared Links…" : "Shared Links (\(m.shareLinks))…", #selector(HostApp.showSharedLinks), "", target, symbol: "link.badge.plus")
        let control = add(menu, m.controlOverridden ? "Allow Remote Control (set for this run)" : "Allow Remote Control", #selector(HostApp.toggleAllowControl), "", target)
        control.state = m.allowControl ? .on : .off
        control.toolTip = "One switch for every share link: on, control links may type and click and a guest who asks is let in at once; off, every link watches and guests ask you."

        menu.addItem(.separator())
        add(menu, "Pair a New Viewer…", #selector(HostApp.pairViewer), "p", target, symbol: "plus.circle")
        add(menu, m.paired == 0 ? "Paired Macs…" : "Paired Macs (\(m.paired))…", #selector(HostApp.showPairedMacs), "", target, symbol: "desktopcomputer")
        add(menu, "Copy Browser Link", #selector(HostApp.copyLink), "c", target, symbol: "link")
        add(menu, "Copy Password", #selector(HostApp.copyPassword), "", target, symbol: "key")

        if !m.screenRecording || !m.accessibility {
            menu.addItem(.separator())
            if !m.screenRecording {
                add(menu, "Allow Screen Recording…", #selector(HostApp.openScreenSettings), "", target, symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
            }
            if !m.accessibility {
                add(menu, "Allow Accessibility…", #selector(HostApp.openAXSettings), "", target, symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
            }
        }

    }

    private static func info(_ text: String, bold: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: bold ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) : NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        item.isEnabled = true
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ target: AnyObject,
                            symbol name: String? = nil, tint: NSColor? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        item.isEnabled = true
        if let name { item.image = symbol(name, tint) }
        return item
    }

    private static func symbol(_ name: String, _ tint: NSColor?) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let tint else { return image }
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
    }

    private static func dot(_ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .regular).applying(.init(paletteColors: [color])))
    }

    private static func appIcon(_ bundle: String?) -> NSImage {
        let image = bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}
