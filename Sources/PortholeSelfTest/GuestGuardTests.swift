import AppKit
import CoreGraphics
import PortholeCore

func guestGuardTests() {
    injectedTextTests()
    trackSenderTests()
    roomGateTests()
    askThrottleTests()
    injectedClickTests()
}

private func injectedTextTests() {
    let source = PortholeEventTag.source()
    check("injected text: the host's event source is tagged", source?.userData == PortholeEventTag.value)
    let events = InjectedText.events([.text(Array("hi".utf16)), .newline, .text(Array("👋".utf16))], source: source)
    expect("injected text: a key pair per piece", events.count, 6)
    check("injected text: text and Return events carry empty flags, so held ⌘⌥⇧ don't turn typing into shortcuts",
          events.allSatisfy { $0.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty })
    check("injected text: every event still carries the Porthole tag", events.allSatisfy { PortholeEventTag.isInjected($0) })
    check("injected text: Return is key code 36", events[2].getIntegerValueField(.keyboardEventKeycode) == 36 && events[3].getIntegerValueField(.keyboardEventKeycode) == 36)
    check("injected text: downs and ups alternate", events.enumerated().allSatisfy { i, e in (e.type == .keyDown) == (i % 2 == 0) })
    var len = 0
    var buf = [UniChar](repeating: 0, count: 8)
    events[0].keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
    expect("injected text: the text rides in the event", String(utf16CodeUnits: buf, count: len), "hi")
    check("injected text: an untagged event is not ours", !PortholeEventTag.isInjected(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)))
    check("injected text: no event is not ours", !PortholeEventTag.isInjected(nil as CGEvent?))

    let ups = ViewerInput.modifierReleases(win: 4, flags: [.command, .option, .shift])
    expect("paste as keystrokes: the viewer lets go of ⌘⌥⇧ before the text", ups.map(\.code), [55, 58, 56])
    check("paste as keystrokes: the releases are key-ups with no modifiers", ups.allSatisfy { $0.t == .key && $0.down == false && $0.mods == 0 && $0.win == 4 })
    expect("paste as keystrokes: nothing held, nothing released", ViewerInput.modifierReleases(win: 4, flags: []).count, 0)
    expect("paste as keystrokes: Control too", ViewerInput.modifierReleases(win: 4, flags: .control).map(\.code), [59])
}

private func trackSenderTests() {
    let open = TrackGrantPlan(allParticipantsAllowed: true, grants: [])
    let closed = TrackGrantPlan(allParticipantsAllowed: false, grants: [TrackGrant(participantSid: "PA_mac", allTracks: true, trackSids: [])])
    var s = TrackPlanSender()
    check("track sender: the server starts open, so an open plan isn't sent", !s.shouldSend(open))
    check("track sender: a closed plan is sent", s.shouldSend(closed))
    s.sending(closed)
    check("track sender: the same plan isn't sent twice", !s.shouldSend(closed))
    check("track sender: reopening is sent", s.shouldSend(open))
    s.failed()
    check("track sender: after a failed send the open plan is sent again, so owners aren't left out", s.shouldSend(open) && s.mustRetry)
    check("track sender: after a failed send even the same closed plan is resent", s.shouldSend(closed))
    s.sending(open)
    check("track sender: once resent, it settles", !s.shouldSend(open) && !s.mustRetry)
}

private func roomGateTests() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let link = ShareLink(id: "0a1b2c3d", tokenHash: "h", window: nil, label: "p", control: false, created: now, expires: now.addingTimeInterval(3600))
    var g = GuestRoomGate()
    check("room gate: never shared, the room is open", !g.closed(live: [], now: now))
    check("room gate: closed while a link is live", g.closed(live: [link], now: now))
    check("room gate: still closed right after the link is revoked, while a saved guest token could rejoin", g.closed(live: [], now: now.addingTimeInterval(10)))
    var r = GuestRoomGate()
    _ = r.closed(live: [link], now: now)
    r.linkEnded(now: now.addingTimeInterval(60))
    check("room gate: a revoke keeps it closed for the token lifetime plus a minute", r.closed(live: [], now: now.addingTimeInterval(60 + 600 + 59)))
    check("room gate: closed until the link's expiry plus the margin", r.closed(live: [], now: now.addingTimeInterval(3600 + 600 + 59)))
    check("room gate: open again after that", !r.closed(live: [], now: now.addingTimeInterval(3600 + 660 + 1)))
    let restored = GuestRoomGate.restored(fileChanged: now)
    var copy = restored
    check("room gate: after a host restart it stays closed if links changed in the last 11 minutes", copy.closed(live: [], now: now.addingTimeInterval(300)))
    check("room gate: and opens later", !copy.closed(live: [], now: now.addingTimeInterval(700)))
    var none = GuestRoomGate.restored(fileChanged: nil)
    check("room gate: no share-links file means open", !none.closed(live: [], now: now))
    expect("room gate: the next expiry is when to update permissions", GuestRoomGate.nextExpiry([link], now: now), 3600)
    expect("room gate: no live links, no timer", GuestRoomGate.nextExpiry([], now: now), nil)

    let mac = TrackGrantPlan.Participant(sid: "PA_mac", identity: "view-Air-abc.0123456789abcdef")
    let back = TrackGrantPlan.Participant(sid: "PA_g", identity: "guest-0a1b2c3d-aaaaaa")
    let plan = TrackGrantPlan.make(participants: [mac, back], tracks: [.init(sid: "TR_1", name: "win-1")], link: { _ in nil }, parent: { _ in nil },
                                   sharedParents: [1], linksExist: false)
    check("room gate: a revoked guest rejoining with a saved token closes the room before it is kicked",
          !plan.allParticipantsAllowed && plan.grants.first { $0.participantSid == "PA_g" }?.trackSids == [])
    check("room gate: owners keep every track meanwhile", plan.grants.first { $0.participantSid == "PA_mac" }?.allTracks == true)
}

private func askThrottleTests() {
    let now = Date(timeIntervalSince1970: 500)
    var t = AskThrottle()
    check("ask panels: the first ask on a link opens a panel", t.mayShowPanel(link: "L1", now: now))
    check("ask panels: one open panel per link", !t.mayShowPanel(link: "L1", now: now.addingTimeInterval(1)))
    check("ask panels: another link gets its own", t.mayShowPanel(link: "L2", now: now))
    t.panelClosed(link: "L1", now: now.addingTimeInterval(5))
    check("ask panels: a cooldown after the panel closes", !t.mayShowPanel(link: "L1", now: now.addingTimeInterval(20)))
    check("ask panels: after 30 s a new panel may open", t.mayShowPanel(link: "L1", now: now.addingTimeInterval(36)))
}

private func injectedClickTests() {
    let panel = guardedPanelRect(CGRect(x: 100, y: 700, width: 380, height: 160), primaryHeight: 1000)
    expect("guarded panels: frames turn into global top-left coordinates", panel, CGRect(x: 100, y: 140, width: 380, height: 160))
    check("guarded panels: an injected click on a guest Ask panel is blocked", WholeMac.blocksInjectedClick(at: CGPoint(x: 300, y: 200), guarded: [panel]))
    check("guarded panels: clicks elsewhere go through", !WholeMac.blocksInjectedClick(at: CGPoint(x: 50, y: 50), guarded: [panel]))
    let tagged = PortholeEventTag.source().flatMap { CGEvent(mouseEventSource: $0, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 300, y: 200), mouseButton: .left) }
    check("guarded panels: a click the host injected carries the tag the panels ignore", PortholeEventTag.isInjected(tagged))
    check("guarded panels: a person's click does not", !PortholeEventTag.isInjected(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)))
    let cmd: Modifiers = [.command], ctrl: Modifiers = [.control]
    let blocked: [(String, UInt16, Modifiers)] = [
        ("Spotlight", 49, cmd), ("Finder search", 49, [.command, .option]), ("input source", 49, ctrl), ("app switcher", 48, cmd),
        ("force quit", 53, [.command, .option]), ("Mission Control", 126, ctrl), ("a space", 124, ctrl), ("desktop 2", 19, ctrl),
        ("screenshot", 21, [.command, .shift]), ("lock screen", 12, [.command, .control]), ("log out", 12, [.command, .shift]),
        ("menu bar focus", 120, ctrl), ("the Dock", 2, [.command, .option]), ("the Mission Control key", 160, []), ("show desktop", 103, []),
    ]
    for (name, code, mods) in blocked { check("guest keys: \(name) is a system shortcut", GuestKeys.isSystemShortcut(code: code, mods: mods)) }
    let allowed: [(String, UInt16, Modifiers)] = [
        ("a letter", 0, []), ("space", 49, []), ("shift-space", 49, [.shift]), ("tab", 48, []), ("copy", 8, cmd), ("save", 1, cmd),
        ("an arrow", 124, []), ("word left", 123, [.option]), ("line start", 123, cmd), ("escape", 53, []), ("quit the app", 12, cmd), ("a digit", 19, []),
    ]
    for (name, code, mods) in allowed { check("guest keys: \(name) is typed", !GuestKeys.isSystemShortcut(code: code, mods: mods)) }
    check("guest typing: the shared window has the keyboard", GuestKeys.mayType(frontmostPID: 7, focusedWindow: 40, focusedElementPID: 7, window: 40, owner: 7))
    check("guest typing: another app is in front", !GuestKeys.mayType(frontmostPID: 9, focusedWindow: 40, focusedElementPID: 9, window: 40, owner: 7))
    check("guest typing: another window of the app has the keyboard", !GuestKeys.mayType(frontmostPID: 7, focusedWindow: 41, focusedElementPID: 7, window: 40, owner: 7))
    check("guest typing: Spotlight or another panel holds the text focus", !GuestKeys.mayType(frontmostPID: 7, focusedWindow: 40, focusedElementPID: 300, window: 40, owner: 7))
    check("guest typing: an app without a readable focused element still types", GuestKeys.mayType(frontmostPID: 7, focusedWindow: 40, focusedElementPID: nil, window: 40, owner: 7))
    check("guest typing: an unreadable focused window is refused", !GuestKeys.mayType(frontmostPID: 7, focusedWindow: nil, focusedElementPID: 7, window: 40, owner: 7))
}
