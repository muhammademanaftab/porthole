import Foundation
import PortholeCore

private func decode(_ s: String) -> Message? { Message.decode(Data(s.utf8)) }

func messageTests() {
    expect("message: empty list request encodes to exactly {\"t\":\"list\"}",
           String(decoding: Message(.list).encoded(), as: UTF8.self), #"{"t":"list"}"#)

    var m = Message(.mouse)
    m.win = 42; m.kind = .down; m.btn = 1; m.x = 0.25; m.y = 0.75; m.clicks = 2; m.mods = 9
    let wire = json(m.encoded())
    expect("message: mouse encodes only the set fields under their wire names",
           Set(wire?.keys.map { $0 } ?? []), ["t", "win", "kind", "btn", "x", "y", "clicks", "mods"])
    check("message: mouse wire values are strings for enums and numbers for the rest",
          wire?["t"] as? String == "mouse" && wire?["kind"] as? String == "down" && wire?["win"] as? Int == 42
          && wire?["x"] as? Double == 0.25 && wire?["mods"] as? Int == 9)

    var full = Message(.windows)
    full.win = 4_294_967_295; full.track = "win-1"; full.code = 65_535; full.down = false; full.mods = 15
    full.s = "héllo 👋 日本"; full.kind = .drag; full.btn = 2; full.clicks = 3; full.x = 0; full.y = 1
    full.dx = -3.5; full.dy = 48; full.w = 1280; full.h = 720; full.msg = "nope"
    full.list = [WindowInfo(id: 7, app: "TextEdit", title: "Notes — draft", bundle: nil, w: 640, h: 480)]
    expect("message: every field, max ids and unicode survive a round trip", Message.decode(full.encoded()), full)

    expect("message: Kind wire strings", [Message.Kind.list, .open, .close, .key, .text, .mouse, .scroll, .resize,
                                         .windows, .opened, .closed, .error].map(\.rawValue),
           ["list", "open", "close", "key", "text", "mouse", "scroll", "resize", "windows", "opened", "closed", "error"])
    expect("message: MouseKind wire strings", [Message.MouseKind.down, .up, .move, .drag].map(\.rawValue),
           ["down", "up", "move", "drag"])

    let key = decode(#"{"t":"key","win":7,"code":0,"down":true,"mods":9,"s":"a"}"#)
    check("browser: key down JSON decodes", key?.t == .key && key?.win == 7 && key?.code == 0 && key?.down == true
          && key?.mods == 9 && key?.s == "a")
    let arrow = decode(#"{"t":"key","win":7,"code":123,"down":false,"mods":0}"#)
    check("browser: key without s (arrow keys) decodes with s nil", arrow?.code == 123 && arrow?.down == false && arrow?.s == nil)
    expect("browser: text with raw unicode decodes", decode(#"{"t":"text","win":7,"s":"héllo 👋 日本"}"#)?.s, "héllo 👋 日本")
    let escaped = #"{"t":"text","win":7,"s":""# + ["00e9", "d83d", "dc4b"].map { "\\" + "u" + $0 }.joined() + #""}"#
    if escaped.unicodeScalars.allSatisfy(\.isASCII) {
        expect("browser: text with JSON \\u escapes and a surrogate pair decodes", decode(escaped)?.s, "\u{E9}\u{1F44B}")
    } else { check("browser: escaped text fixture must be pure ASCII", false) }
    let down = decode(#"{"t":"mouse","win":7,"kind":"down","btn":1,"x":0.25,"y":1,"clicks":2,"mods":8}"#)
    check("browser: mouse down decodes, integer y becomes 1.0", down?.kind == .down && down?.btn == 1 && down?.x == 0.25
          && down?.y == 1.0 && down?.clicks == 2 && down?.mods == 8)
    let move = decode(#"{"t":"mouse","win":7,"kind":"move","btn":0,"x":0.5,"y":0.5,"mods":0}"#)
    check("browser: mouse move without clicks decodes with clicks nil", move?.kind == .move && move?.clicks == nil)
    let scroll = decode(#"{"t":"scroll","win":7,"x":0.5,"y":0.5,"dx":-3,"dy":48}"#)
    check("browser: scroll decodes deltas", scroll?.t == .scroll && scroll?.dx == -3 && scroll?.dy == 48)
    let resize = decode(#"{"t":"resize","win":7,"w":1280,"h":720}"#)
    check("browser: resize decodes size", resize?.t == .resize && resize?.w == 1280 && resize?.h == 720)
    let open = decode(#"{"t":"open","win":7}"#)
    check("browser: open decodes window id only", open?.t == .open && open?.win == 7)
    expect("message: unknown fields are ignored", decode(#"{"t":"list","extra":1,"nested":{"a":[1,2]}}"#)?.t, .list)

    let windows = decode(#"{"t":"windows","list":[{"id":5,"app":"Finder","title":"","w":800,"h":600}]}"#)
    expect("message: window list with missing bundle decodes bundle as nil", windows?.list,
           [WindowInfo(id: 5, app: "Finder", title: "", bundle: nil, w: 800, h: 600)])
    check("message: window info missing a required field is rejected",
          decode(#"{"t":"windows","list":[{"id":5,"app":"Finder","w":800,"h":600}]}"#) == nil)

    let malformed: [(String, String)] = [
        ("unknown kind", #"{"t":"nope"}"#),
        ("kind is case sensitive", #"{"t":"Mouse"}"#),
        ("missing t", #"{"win":7}"#),
        ("win as string", #"{"t":"open","win":"7"}"#),
        ("negative win", #"{"t":"open","win":-1}"#),
        ("win above UInt32", #"{"t":"open","win":4294967296}"#),
        ("key code above UInt16", #"{"t":"key","code":65536}"#),
        ("unknown mouse kind", #"{"t":"mouse","kind":"click"}"#),
        ("fractional btn", #"{"t":"mouse","btn":1.5}"#),
        ("not JSON", "t=list"),
        ("empty body", ""),
        ("JSON array", #"[{"t":"list"}]"#),
    ]
    for (name, body) in malformed { check("message: rejects \(name)", decode(body) == nil) }

    expect("track: name from id", Message.trackName(for: 123), "win-123")
    expect("track: id from name", Message.windowID(fromTrackName: "win-123"), 123)
    expect("track: max UInt32 id round trips", Message.windowID(fromTrackName: Message.trackName(for: .max)), UInt32.max)
    let badTracks = ["screen", "win-", "win-4294967296", "win--1", "win-12a", "Win-1", "xwin-1", "win-1 ", "win-+7", "win-007", "win-0x1"]
    for t in badTracks { check("track: \"\(t)\" is not a window track", Message.windowID(fromTrackName: t) == nil) }
}
