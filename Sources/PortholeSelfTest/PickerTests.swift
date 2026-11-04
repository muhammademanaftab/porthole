import CoreGraphics
import Foundation
import PortholeCore

func pickerTests() {
    let notes = WindowInfo(id: 1, app: "TextEdit", title: "Shopping List", bundle: nil, w: 640.4, h: 479.6)
    let cafe = WindowInfo(id: 2, app: "Safari", title: "Café menu", bundle: nil, w: 1280, h: 800)
    let finder = WindowInfo(id: 3, app: "Finder", title: "", bundle: nil, w: 900, h: 600)
    let all = [notes, cafe, finder]

    expect("size label rounds to whole points", notes.sizeLabel, "640×480")
    expect("display title: the window title", notes.displayTitle, "Shopping List")
    expect("display title: untitled falls back to the app", finder.displayTitle, "Finder")
    expect("subtitle: app and size", notes.displaySubtitle, "TextEdit · 640×480")
    expect("subtitle: untitled shows only the size", finder.displaySubtitle, "900×600")

    expect("filter: empty query keeps everything in order", filterWindows(all, query: "").map(\.id), [1, 2, 3])
    expect("filter: blank query keeps everything", filterWindows(all, query: "  \t ").map(\.id), [1, 2, 3])
    expect("filter: matches the app name", filterWindows(all, query: "safari").map(\.id), [2])
    expect("filter: matches the title", filterWindows(all, query: "LIST").map(\.id), [1])
    expect("filter: ignores accents", filterWindows(all, query: "cafe").map(\.id), [2])
    expect("filter: every word must match", filterWindows(all, query: "text shopping").map(\.id), [1])
    expect("filter: words may come from app and title", filterWindows(all, query: "menu safari").map(\.id), [2])
    expect("filter: one missing word excludes", filterWindows(all, query: "text zebra").map(\.id), [])
    expect("filter: substring inside a word", filterWindows(all, query: "ind").map(\.id), [3])
    expect("search tokens split on any whitespace", searchTokens(" a\tb  c\n"), ["a", "b", "c"])

    expect("notice: loading before the first list", pickerNotice(loaded: false, total: 0, shown: 0, query: "", error: nil), .loading)
    expect("notice: empty host", pickerNotice(loaded: true, total: 0, shown: 0, query: "", error: nil), .empty)
    expect("notice: locked screen is recognised", pickerNotice(loaded: true, total: 0, shown: 0, query: "", error: LockNotice.list), .locked)
    expect("notice: locked even before a list arrives", pickerNotice(loaded: false, total: 0, shown: 0, query: "", error: LockNotice.list), .locked)
    expect("notice: other errors with no windows", pickerNotice(loaded: false, total: 0, shown: 0, query: "", error: "Disconnected"), .error("Disconnected"))
    expect("notice: an empty error string is ignored", pickerNotice(loaded: true, total: 0, shown: 0, query: "", error: ""), .empty)
    expect("notice: errors don't hide a list", pickerNotice(loaded: true, total: 3, shown: 3, query: "", error: "Disconnected"), nil)
    expect("notice: no matches names the trimmed query", pickerNotice(loaded: true, total: 3, shown: 0, query: " zebra ", error: nil), .noMatches("zebra"))
    expect("notice: windows shown means none", pickerNotice(loaded: true, total: 3, shown: 1, query: "x", error: nil), nil)
    expect("notice: no-match message quotes the query", PickerNotice.noMatches("zebra").message, "No window matches \u{201C}zebra\u{201D}.")
    expect("notice: locked message is the host's text", PickerNotice.locked.message, LockNotice.list)
    check("notice: every case has a symbol and title", [PickerNotice.loading, .empty, .locked, .noMatches("a"), .error("b")]
        .allSatisfy { !$0.symbol.isEmpty && !$0.title.isEmpty && !$0.message.isEmpty })

    expect("count: all shown, singular", pickerCountLabel(total: 1, shown: 1), "1 window")
    expect("count: all shown, plural", pickerCountLabel(total: 4, shown: 4), "4 windows")
    expect("count: filtered", pickerCountLabel(total: 4, shown: 2), "2 of 4 windows")

    expect("thumb size: wide window fits the width", WindowThumbnail.pixelSize(window: CGSize(width: 1920, height: 1080)),
           CGSize(width: 480, height: 270))
    expect("thumb size: tall window fits the height", WindowThumbnail.pixelSize(window: CGSize(width: 600, height: 1200)),
           CGSize(width: 150, height: 300))
    expect("thumb size: small windows are not enlarged", WindowThumbnail.pixelSize(window: CGSize(width: 200, height: 100)),
           CGSize(width: 200, height: 100))
    expect("thumb size: extreme aspect keeps at least one pixel", WindowThumbnail.pixelSize(window: CGSize(width: 100_000, height: 2)),
           CGSize(width: 480, height: 1))
    expect("thumb size: empty window has none", WindowThumbnail.pixelSize(window: CGSize(width: 0, height: 100)), nil)
    expect("thumb size: custom limit", WindowThumbnail.pixelSize(window: CGSize(width: 1000, height: 1000), limit: CGSize(width: 64, height: 64)),
           CGSize(width: 64, height: 64))
    check("thumb: cached pictures stay fresh for at least 6 s", WindowThumbnail.cacheFresh >= 6)
    let asked = Date(timeIntervalSinceReferenceDate: 1000)
    check("thumb: a first request is served", WindowThumbnail.shouldServe(lastAsked: nil, now: asked))
    check("thumb: a repeat within 2 s is ignored", !WindowThumbnail.shouldServe(lastAsked: asked, now: asked.addingTimeInterval(1.9)))
    check("thumb: a request 2 s later is served", WindowThumbnail.shouldServe(lastAsked: asked, now: asked.addingTimeInterval(2)))
    check("thumb: a clock that went backwards doesn't block requests", WindowThumbnail.shouldServe(lastAsked: asked, now: asked.addingTimeInterval(-5)))
    check("thumb: JPEG accepted", WindowThumbnail.isAcceptable(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])))
    check("thumb: PNG refused", !WindowThumbnail.isAcceptable(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])))
    check("thumb: bare signature refused", !WindowThumbnail.isAcceptable(Data([0xFF, 0xD8, 0xFF])))
    check("thumb: oversize refused", !WindowThumbnail.isAcceptable(Data([0xFF, 0xD8, 0xFF]) + Data(count: WindowThumbnail.maxBytes)))
    let many = (1...60).map { WindowInfo(id: UInt32($0), app: "A", title: "", bundle: nil, w: 1, h: 1) }
    expect("thumb requests are capped and keep picker order", WindowThumbnail.requests(for: many), Array(1...40).map(UInt32.init))
    expect("thumb requests for a short list", WindowThumbnail.requests(for: all), [1, 2, 3])

    var thumb = Message(.thumb); thumb.win = 9
    expect("thumb message round-trips", Message.decode(thumb.encoded()), thumb)
    check("thumb kind encodes as \"thumb\"", String(data: thumb.encoded(), encoding: .utf8)?.contains("\"t\":\"thumb\"") == true)

    viewerSettingsTests()
}

func viewerSettingsTests() {
    let none = ViewerSettings(lookup: { _ in nil })
    expect("viewer settings: defaults are automatic, sound on, title bar kept", none, ViewerSettings())
    check("viewer settings: default plays sound", none.playSound)
    check("viewer settings: default keeps the title bar", !none.hideTitleBar)

    let stored: [String: Any] = [ViewerSettings.bitrateKey: 50_000, ViewerSettings.fpsKey: 120, ViewerSettings.levelKey: 1.5,
                                 ViewerSettings.hideTitleBarKey: true, ViewerSettings.playSoundKey: false]
    let read = ViewerSettings(lookup: { stored[$0] })
    expect("viewer settings: reads stored values", read,
           ViewerSettings(bitrateKbps: 50_000, fps: 120, level: 1.5, hideTitleBar: true, playSound: false))

    let bad: [String: Any] = [ViewerSettings.bitrateKey: 999_999, ViewerSettings.fpsKey: 45, ViewerSettings.levelKey: 3.0,
                              ViewerSettings.hideTitleBarKey: "yes"]
    expect("viewer settings: out-of-range values fall back to automatic", ViewerSettings(lookup: { bad[$0] }), ViewerSettings())

    var m = Message(.open)
    read.apply(to: &m)
    expect("viewer settings: open carries bitrate kbps", m.bitrate, 50_000)
    expect("viewer settings: open carries fps", m.fps, 120)
    expect("viewer settings: open carries level", m.level, 1.5)
    let prefs = StreamPrefs(open: m)
    expect("viewer settings: host reads them back", prefs, StreamPrefs(bitrate: 50_000_000, fps: 120, level: 1.5))
    var auto = Message(.open)
    ViewerSettings().apply(to: &auto)
    check("viewer settings: automatic sends no stream fields", auto.bitrate == nil && auto.fps == nil && auto.level == nil)
    expect("viewer settings: automatic means host defaults", StreamPrefs(open: auto), .standard)

    for b in ViewerSettings.bitrateChoices.compactMap({ $0 }) { check("bitrate choice \(b) is allowed by the host", StreamPrefs.bitrateKbpsRange.contains(b)) }
    for f in ViewerSettings.fpsChoices.compactMap({ $0 }) { check("fps choice \(f) is allowed by the host", StreamPrefs.allowedFps.contains(f)) }
    expect("level choices are the host's ladder", ViewerSettings.levelChoices.compactMap { $0 }, StreamPrefs.levels)

    expect("bitrate label: automatic names the default", ViewerSettings.bitrateLabel(nil), "Automatic (25 Mbps)")
    expect("bitrate label: whole Mbps", ViewerSettings.bitrateLabel(50_000), "50 Mbps")
    expect("bitrate label: fractional Mbps", ViewerSettings.bitrateLabel(2_500), "2.5 Mbps")
    expect("fps label: automatic", ViewerSettings.fpsLabel(nil), "Automatic (60 fps)")
    expect("fps label", ViewerSettings.fpsLabel(120), "120 fps")
    expect("level label: automatic", ViewerSettings.levelLabel(nil), "Automatic (up to Retina)")
    expect("level label: retina", ViewerSettings.levelLabel(2), "Retina (2×)")
    expect("level label: fractional", ViewerSettings.levelLabel(1.25), "1.25×")
    expect("level label: one", ViewerSettings.levelLabel(1), "1×")
}
