import CoreGraphics
import Foundation
import ImageIO
import PortholeCore

private func testImage(width: Int, height: Int) -> CGImage? {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
    ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx?.makeImage()
}

private func pixelSizes(_ data: Data) -> [Int] {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
    return (0..<CGImageSourceGetCount(src)).compactMap { i in
        (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
    }
}

private func uint32(_ d: Data, at i: Int) -> UInt32 {
    d[d.startIndex + i..<d.startIndex + i + 4].reduce(0) { $0 << 8 | UInt32($1) }
}

func tileTests() {
    var icon = Message(.icon); icon.win = 7
    let wire = json(icon.encoded())
    check("icon: request encodes as exactly {t:icon, win}", wire?.count == 2 && wire?["t"] as? String == "icon" && wire?["win"] as? Int == 7)
    expect("icon: request decodes", Message.decode(Data(#"{"t":"icon","win":7}"#.utf8)), icon)
    check("icon: topic differs from the message and clipboard topics", iconTopic != portholeTopic && iconTopic != clipboardTopic)

    expect("icon: stream attributes carry the window id", AppIcon.window(from: AppIcon.attributes(win: 4_294_967_295)), 4_294_967_295)
    for bad in ["", "-1", "007", "abc", "4294967296", " 7"] {
        check("icon: attribute win \"\(bad)\" is rejected", AppIcon.window(from: ["win": bad]) == nil)
    }
    check("icon: missing win attribute is rejected", AppIcon.window(from: ["name": "x"]) == nil)

    guard let wide = testImage(width: 300, height: 200), let png = AppIcon.png(from: wide) else {
        check("icon: test image renders to PNG", false); return
    }
    expect("icon: rendered PNG is square at the default 512 px", pixelSizes(png), [AppIcon.pixels])
    expect("icon: rendered PNG honours a requested size", AppIcon.png(from: wide, pixels: 64).map(pixelSizes), [64])
    check("icon: zero pixels renders nothing", AppIcon.png(from: wide, pixels: 0) == nil)
    check("icon: rendered PNG is acceptable", AppIcon.isAcceptable(png))
    check("icon: rendered PNG reads back as an image", AppIcon.image(fromPNG: png)?.width == AppIcon.pixels)
    check("icon: empty data is rejected", !AppIcon.isAcceptable(Data()))
    check("icon: a bare PNG signature is rejected", !AppIcon.isAcceptable(png.prefix(8)))
    check("icon: JPEG bytes are rejected", !AppIcon.isAcceptable(Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 32))))
    check("icon: PNG over the size cap is rejected", !AppIcon.isAcceptable(png + Data(count: AppIcon.maxBytes)))
    check("icon: non-PNG does not decode to an image", AppIcon.image(fromPNG: Data("not a png at all".utf8)) == nil)

    let types = ICNS.entries.map(\.type)
    expect("icns: entry types are unique", Set(types).count, types.count)
    expect("icns: entries cover every Dock size from 16 to 512 px", Set(ICNS.entries.map(\.pixels)), [16, 32, 64, 128, 256, 512])
    expect("icns: largest entry is the size the host sends, so nothing is upscaled", ICNS.entries.map(\.pixels).max(), AppIcon.pixels)

    let a = Data([1, 2, 3]), b = Data([9])
    let raw = ICNS.encode([("ic07", a), ("toolong", b), ("ic08", b)])
    expect("icns: file starts with the icns magic", String(decoding: raw.prefix(4), as: UTF8.self), "icns")
    expect("icns: header length is the whole file", Int(uint32(raw, at: 4)), raw.count)
    expect("icns: invalid four-char types are skipped", raw.count, 8 + (8 + 3) + (8 + 1))
    expect("icns: first entry type", String(decoding: raw[8..<12], as: UTF8.self), "ic07")
    expect("icns: entry length includes its 8-byte header", uint32(raw, at: 12), 11)
    expect("icns: entry payload follows its header", Data(raw[16..<19]), a)
    expect("icns: second entry follows the first", String(decoding: raw[19..<23], as: UTF8.self), "ic08")

    if let icns = ICNS.make(fromPNG: png) {
        expect("icns: built file decodes with ImageIO at every size", Set(pixelSizes(icns)), [16, 32, 64, 128, 256, 512])
        expect("icns: built file length matches its header", Int(uint32(icns, at: 4)), icns.count)
    } else { check("icns: built from a PNG", false) }
    check("icns: refuses non-PNG input", ICNS.make(fromPNG: Data("nope".utf8)) == nil)

    expect("tile: plain app name", TileBundle.fileName(forApp: "TextEdit"), "TextEdit.app")
    expect("tile: names keep spaces but are trimmed", TileBundle.fileName(forApp: "  Visual Studio Code \n"), "Visual Studio Code.app")
    expect("tile: path separators become hyphens", TileBundle.fileName(forApp: "A/B:C"), "A-B-C.app")
    expect("tile: leading dots are dropped so the bundle is not hidden", TileBundle.fileName(forApp: "..hidden"), "hidden.app")
    expect("tile: empty name falls back", TileBundle.fileName(forApp: ""), "Porthole Portal.app")
    expect("tile: a name of only dots falls back", TileBundle.fileName(forApp: "..."), "Porthole Portal.app")
    expect("tile: control characters are removed", TileBundle.displayName(forApp: "Te\u{0}xt\u{7}Edit"), "TextEdit")
    expect("tile: unicode names are kept", TileBundle.fileName(forApp: "日本語メモ"), "日本語メモ.app")
    expect("tile: long names are capped", TileBundle.fileName(forApp: String(repeating: "x", count: 200)).count, 64 + 4)

    let id = TileBundle.bundleID(forApp: "TextEdit")
    check("tile: bundle id is namespaced and readable", id.hasPrefix(TileBundle.idPrefix + "TextEdit-"))
    expect("tile: bundle id is deterministic", TileBundle.bundleID(forApp: "TextEdit"), id)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    for name in ["Visual Studio Code", "日本語メモ", "A/B:C", "", "Café"] {
        check("tile: bundle id for \"\(name)\" uses only legal characters",
              TileBundle.bundleID(forApp: name).unicodeScalars.allSatisfy(allowed.contains))
    }
    check("tile: names that sanitise alike still get different bundle ids",
          TileBundle.bundleID(forApp: "日本") != TileBundle.bundleID(forApp: "中文")
          && TileBundle.bundleID(forApp: "A/B") != TileBundle.bundleID(forApp: "A:B"))
    expect("tile: bundle id ignores surrounding whitespace", TileBundle.bundleID(forApp: " TextEdit "), id)

    let plist = TileBundle.infoPlist(forApp: " TextEdit ", helperDigest: "abc")
    expect("tile: Dock and ⌘Tab name is the host app's name", plist["CFBundleName"] as? String, "TextEdit")
    expect("tile: display name matches", plist["CFBundleDisplayName"] as? String, "TextEdit")
    expect("tile: helper executable is named after the app, so the process name matches", plist["CFBundleExecutable"] as? String, "TextEdit")
    expect("tile: executable name is the bundle name without .app", TileBundle.executableName(forApp: "A/B:C"), "A-B-C")
    expect("tile: executable name falls back with the bundle", TileBundle.executableName(forApp: "..."), TileBundle.fallbackName)
    expect("tile: points at the generated icon", plist["CFBundleIconFile"] as? String, TileBundle.iconFile)
    expect("tile: is an application", plist["CFBundlePackageType"] as? String, "APPL")
    check("tile: is a regular app with a Dock tile", plist["LSUIElement"] == nil && plist["LSBackgroundOnly"] == nil)
    expect("tile: records the helper digest", plist[TileBundle.digestKey] as? String, "abc")
    let back = TileBundle.infoPlistData(forApp: "TextEdit", helperDigest: "abc")
        .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    expect("tile: plist serialises and reads back", back?["CFBundleIdentifier"] as? String, id)
    check("tile: a new helper changes the plist, forcing a rebuild",
          TileBundle.infoPlistData(forApp: "TextEdit", helperDigest: "abc") != TileBundle.infoPlistData(forApp: "TextEdit", helperDigest: "abd"))
    expect("tile: plist bytes are stable for the same input",
           TileBundle.infoPlistData(forApp: "TextEdit", helperDigest: "abc"), TileBundle.infoPlistData(forApp: "TextEdit", helperDigest: "abc"))

    for kind in [TileEvent.Kind.activate, .quit] {
        let e = TileEvent(kind, token: "T-1")
        expect("tile event: \(kind.rawValue) round trips through userInfo", TileEvent(userInfo: e.userInfo), e)
    }
    check("tile event: nil userInfo is rejected", TileEvent(userInfo: nil) == nil)
    check("tile event: unknown event is rejected", TileEvent(userInfo: ["event": "explode", "token": "T"]) == nil)
    check("tile event: missing token is rejected", TileEvent(userInfo: ["event": "activate"]) == nil)
    check("tile event: empty token is rejected", TileEvent(userInfo: ["event": "activate", "token": ""]) == nil)
    check("tile event: non-string token is rejected", TileEvent(userInfo: ["event": "quit", "token": 5]) == nil)

    let args = TileArguments.make(token: "abc-123", viewer: 4242)
    let parsed = TileArguments.parse(args)
    check("tile args: round trip", parsed?.token == "abc-123" && parsed?.viewer == 4242)
    let noisy = TileArguments.parse(["-psn_0_1234", "--viewer", "77", "-NSDocumentRevisionsDebugMode", "YES", "--tile", "x"])
    check("tile args: order and unrelated flags don't matter", noisy?.token == "x" && noisy?.viewer == 77)
    check("tile args: missing viewer is rejected", TileArguments.parse(["--tile", "x"]) == nil)
    check("tile args: missing token is rejected", TileArguments.parse(["--viewer", "5"]) == nil)
    check("tile args: flag without a value is rejected", TileArguments.parse(["--viewer", "5", "--tile"]) == nil)
    check("tile args: viewer pid must be positive", TileArguments.parse(["--tile", "x", "--viewer", "0"]) == nil)
    check("tile args: viewer pid must be numeric", TileArguments.parse(["--tile", "x", "--viewer", "me"]) == nil)
    check("tile args: empty token is rejected", TileArguments.parse(["--tile", "", "--viewer", "5"]) == nil)
}
