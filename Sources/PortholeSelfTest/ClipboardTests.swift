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

    var p = ClipboardSync(changeCount: 0)
    expect("a concealed copy (a password manager) is not sent",
           p.outgoing(changeCount: 1, types: { ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"] }) { "hunter2" }, nil)
    expect("a transient copy is not sent", p.outgoing(changeCount: 2, types: { ["org.nspasteboard.TransientType", "public.utf8-plain-text"] }) { "hunter2" }, nil)
    expect("the skipped change is not sent later", p.outgoing(changeCount: 2, types: { [] }) { "hunter2" }, nil)
    expect("an ordinary copy with types is sent", p.outgoing(changeCount: 3, types: { ["public.utf8-plain-text"] }) { "hello" }, "hello")
    check("private types are recognised", ClipboardSync.isPrivate(types: ["org.nspasteboard.ConcealedType"])
          && ClipboardSync.isPrivate(types: ["org.nspasteboard.TransientType"]) && !ClipboardSync.isPrivate(types: ["public.utf8-plain-text"])
          && !ClipboardSync.isPrivate(types: []))

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

    var reg = SessionRegistry()
    _ = reg.beginOpen(1, by: "a"); _ = reg.startSucceeded(1)
    _ = reg.beginOpen(2, by: "b"); _ = reg.startSucceeded(2)
    _ = reg.beginOpen(3, by: "c")
    expect("active viewers are those with a live window", reg.activeViewers, ["a", "b"])
    _ = reg.release(1, by: "a")
    expect("a viewer who closed their window is no longer active", reg.activeViewers, ["b"])
    func collected(_ chunks: [String], declared: Int?) -> String? {
        let done = DispatchSemaphore(value: 0)
        let box = ClipBox()
        Task.detached {
            box.value = try? await ClipboardSync.collect(AsyncStream { c in chunks.forEach { c.yield($0) }; c.finish() }, declaredBytes: declared)
            done.signal()
        }
        done.wait()
        return box.value
    }
    expect("clipboard stream: chunks are joined", collected(["ab", "cd"], declared: 4), "abcd")
    expect("clipboard stream: a declared size over the cap is refused unread", collected(["x"], declared: ClipboardSync.maxBytes + 1), nil)
    let chunk = String(repeating: "x", count: 400_000)
    expect("clipboard stream: reading stops once the cap is passed", collected([chunk, chunk, chunk], declared: nil), nil)
    expect("clipboard stream: exactly the cap is kept", collected([chunk, chunk, String(repeating: "x", count: 200_000)], declared: nil)?.utf8.count, ClipboardSync.maxBytes)
}

final class ClipBox: @unchecked Sendable { var value: String? }
