import Foundation
import PortholeCore

func clipboardTests() {
    var c = ClipboardSync(changeCount: 5)
    expect("unchanged pasteboard sends nothing", c.outgoing(changeCount: 5) { "x" }, nil)
    expect("a new copy is sent", c.outgoing(changeCount: 6) { "hello" }, "hello")
    expect("the same change is not sent twice", c.outgoing(changeCount: 6) { "hello" }, nil)
    expect("copying the same text again is not resent", c.outgoing(changeCount: 7) { "hello" }, nil)
    expect("non-text copy sends nothing", c.outgoing(changeCount: 8) { nil }, nil)
    expect("empty text is not sent", c.outgoing(changeCount: 9) { "" }, nil)
    expect("text over 1 MB is not sent", c.outgoing(changeCount: 10) { String(repeating: "a", count: ClipboardSync.maxBytes + 1) }, nil)
    expect("exactly 1 MB is sent", c.outgoing(changeCount: 11) { String(repeating: "b", count: ClipboardSync.maxBytes) }?.utf8.count, ClipboardSync.maxBytes)

    var r = ClipboardSync(changeCount: 0)
    check("remote text is applied", r.incoming("from host"))
    check("the same remote text is not applied twice", !r.incoming("from host"))
    r.applied(changeCount: 1)
    expect("our own write is not echoed back", r.outgoing(changeCount: 1) { "from host" }, nil)
    expect("a later local copy of the same text is not echoed", r.outgoing(changeCount: 2) { "from host" }, nil)
    expect("a different local copy is sent", r.outgoing(changeCount: 3) { "mine" }, "mine")
    check("remote text equal to what we just sent is ignored", !r.incoming("mine"))
    check("empty remote text is ignored", !r.incoming(""))
    check("multi-byte text counts bytes, not characters", !ClipboardSync.fits(String(repeating: "é", count: ClipboardSync.maxBytes / 2 + 1)))

    let p = LaunchAgent.plist(executable: "/Applications/Porthole Host.app/Contents/MacOS/porthole-host", logDirectory: "/tmp/logs")
    expect("agent label", p["Label"] as? String, "io.github.muhammademanaftab.porthole")
    expect("agent runs the host binary", p["ProgramArguments"] as? [String], ["/Applications/Porthole Host.app/Contents/MacOS/porthole-host"])
    expect("agent starts at login", p["RunAtLoad"] as? Bool, true)
    expect("agent restarts only after a crash, not after Quit", (p["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
    expect("agent only runs in a GUI login session", p["LimitLoadToSessionType"] as? String, "Aqua")
    expect("agent marks its launches", (p["EnvironmentVariables"] as? [String: String])?[LaunchAgent.launchedEnvKey], "1")
    expect("agent output goes to the log folder", p["StandardOutPath"] as? String, "/tmp/logs/host.out.log")
    let data = LaunchAgent.plistData(executable: "/x", logDirectory: "/y")
    let back = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    expect("agent plist serialises and reads back", back?["Label"] as? String, LaunchAgent.label)

    var reg = SessionRegistry()
    _ = reg.beginOpen(1, by: "a"); _ = reg.startSucceeded(1)
    _ = reg.beginOpen(2, by: "b"); _ = reg.startSucceeded(2)
    _ = reg.beginOpen(3, by: "c")
    expect("active viewers are those with a live window", reg.activeViewers, ["a", "b"])
    _ = reg.release(1, by: "a")
    expect("a viewer who closed their window is no longer active", reg.activeViewers, ["b"])
}
