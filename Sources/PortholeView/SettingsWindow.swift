import AppKit
import PortholeCore

@MainActor
final class ViewerSettingsWindow: NSWindow {
    private let tabs = ViewerSettingsTabs()
    private let general = ViewerGeneralPane()
    var onChange: ((ViewerSettings) -> Void)? {
        didSet { general.onChange = onChange; windows.onChange = onChange; stream.onChange = onChange }
    }
    private let windows = ViewerWindowsPane()
    private let stream = ViewerStreamPane()

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabs.tabStyle = .toolbar
        for (pane, label, symbol) in [(general as NSViewController, "General", "gearshape"),
                                      (windows, "Windows", "macwindow"),
                                      (stream, "Stream", "dial.medium")] {
            let item = NSTabViewItem(viewController: pane)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        contentViewController = tabs
        toolbarStyle = .preference
        title = "General"
    }

    func present(tab: Int? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab }
        title = tabs.tabViewItems[tabs.selectedTabViewItemIndex].label
        tabs.fitWindow(animate: false)
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    func reflect(_ s: ViewerSettings) { general.reflect(s) }

    static var current: ViewerSettings { ViewerSettings(lookup: { UserDefaults.standard.object(forKey: $0) }) }

    static func save(_ s: ViewerSettings) {
        for (key, value) in s.stored {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

final class ViewerSettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let label = item?.label { view.window?.title = label }
        fitWindow(animate: view.window?.isVisible == true)
    }

    func fitWindow(animate: Bool) {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController?.view, let w = view.window else { return }
        pane.layoutSubtreeIfNeeded()
        var frame = w.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 520, height: pane.fittingSize.height)))
        frame.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - frame.height)
        w.setFrame(frame, display: true, animate: animate)
    }
}

@MainActor
enum ViewerForm {
    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 140
        grid.rowAlignment = .firstBaseline
        return grid
    }

    static func note(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.textColor = .secondaryLabelColor
        t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        t.preferredMaxLayoutWidth = 320
        t.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return t
    }

    static func column(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    static func pane(_ content: NSView) -> NSView {
        let v = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
            v.widthAnchor.constraint(equalToConstant: 520),
        ])
        return v
    }

    static func popUp<T: Equatable>(_ choices: [T], label: (T) -> String, selected: T, target: AnyObject, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, c) in choices.enumerated() {
            p.addItem(withTitle: label(c))
            p.lastItem?.tag = i
            if i == 0 && choices.count > 1 { p.menu?.addItem(.separator()) }
        }
        if let i = choices.firstIndex(of: selected) { p.selectItem(withTag: i) }
        p.target = target
        p.action = action
        return p
    }
}

@MainActor
class ViewerPane: NSViewController {
    var onChange: ((ViewerSettings) -> Void)?

    func update(_ change: (inout ViewerSettings) -> Void) {
        var s = ViewerSettingsWindow.current
        change(&s)
        ViewerSettingsWindow.save(s)
        onChange?(s)
    }
}

@MainActor
final class ViewerGeneralPane: ViewerPane {
    private let sound = NSButton(checkboxWithTitle: "Play sound from shared windows", target: nil, action: nil)
    private let effects = NSButton(checkboxWithTitle: "Play sound effects", target: nil, action: nil)

    override func loadView() {
        title = "General"
        sound.target = self
        sound.action = #selector(toggleSound)
        sound.state = ViewerSettingsWindow.current.playSound ? .on : .off
        effects.target = self
        effects.action = #selector(toggleEffects)
        effects.state = ViewerSettingsWindow.current.soundEffects ? .on : .off
        let grid = ViewerForm.grid([
            [NSTextField(labelWithString: "Sound:"),
             ViewerForm.column([sound, ViewerForm.note("Same as Mute Host Sound in the Porthole menu. The host only sends sound while one of its windows is open here.")])],
            [NSTextField(labelWithString: "Sound Effects:"),
             ViewerForm.column([effects, ViewerForm.note("A quiet sound when a shared window opens or closes, and when pairing works or fails. macOS's \"Play user interface sound effects\" being off silences them too.")])],
        ])
        view = ViewerForm.pane(grid)
    }

    @objc private func toggleSound() { update { $0.playSound = sound.state == .on } }
    @objc private func toggleEffects() { update { $0.soundEffects = effects.state == .on } }

    func reflect(_ s: ViewerSettings) {
        if isViewLoaded { sound.state = s.playSound ? .on : .off; effects.state = s.soundEffects ? .on : .off }
    }
}

@MainActor
final class ViewerWindowsPane: ViewerPane {
    private let hide = NSButton(checkboxWithTitle: "Automatically hide the title bar", target: nil, action: nil)

    override func loadView() {
        title = "Windows"
        hide.target = self
        hide.action = #selector(toggleHide)
        hide.state = ViewerSettingsWindow.current.hideTitleBar ? .on : .off
        let grid = ViewerForm.grid([
            [NSTextField(labelWithString: "Title bar:"),
             ViewerForm.column([hide, ViewerForm.note("Shared windows show their title bar only while the pointer is near the top. Saved now; shared windows will follow it in a coming version.")])],
        ])
        view = ViewerForm.pane(grid)
    }

    @objc private func toggleHide() { update { $0.hideTitleBar = hide.state == .on } }
}

@MainActor
final class ViewerStreamPane: ViewerPane {
    private var bitrate: NSPopUpButton!
    private var fps: NSPopUpButton!
    private var level: NSPopUpButton!

    override func loadView() {
        title = "Stream"
        let s = ViewerSettingsWindow.current
        bitrate = ViewerForm.popUp(ViewerSettings.bitrateChoices, label: ViewerSettings.bitrateLabel, selected: s.bitrateKbps,
                                   target: self, action: #selector(changed))
        fps = ViewerForm.popUp(ViewerSettings.fpsChoices, label: ViewerSettings.fpsLabel, selected: s.fps, target: self, action: #selector(changed))
        level = ViewerForm.popUp(ViewerSettings.levelChoices, label: ViewerSettings.levelLabel, selected: s.level,
                                 target: self, action: #selector(changed))
        let reset = NSButton(title: "Use Automatic for All", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        let grid = ViewerForm.grid([
            [NSTextField(labelWithString: "Bitrate:"), bitrate],
            [NSTextField(labelWithString: "Frame rate:"), fps],
            [NSTextField(labelWithString: "Sharpness:"), ViewerForm.column([level,
                ViewerForm.note("The highest capture scale. The host steps down from it when a window is busy and climbs back when it calms down.")])],
            [NSView(), ViewerForm.column([reset,
                ViewerForm.note("Applies to windows you open from now on. When several Macs watch one window, the first to open it sets its stream.")])],
        ])
        grid.row(at: 3).topPadding = 6
        view = ViewerForm.pane(grid)
    }

    @objc private func changed() {
        update {
            $0.bitrateKbps = ViewerSettings.bitrateChoices[bitrate.selectedTag()]
            $0.fps = ViewerSettings.fpsChoices[fps.selectedTag()]
            $0.level = ViewerSettings.levelChoices[level.selectedTag()]
        }
    }

    @objc private func resetAll() {
        for p in [bitrate, fps, level] { p?.selectItem(withTag: 0) }
        changed()
    }
}
