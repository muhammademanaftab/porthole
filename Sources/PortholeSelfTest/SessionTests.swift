import Foundation
import PortholeCore

func sessionTests() {
    startGateTests()
    var r = SessionRegistry()
    expect("sessions: first viewer starts the capture", r.beginOpen(1, by: "A"), .start)
    expect("sessions: second viewer during start waits for it", r.beginOpen(1, by: "B"), .waitForStart)
    check("sessions: input is refused while the capture is still starting", !r.acceptsInput(1, from: "A"))
    check("sessions: successful start keeps the session", r.startSucceeded(1))
    check("sessions: both viewers get the opened reply", r.shouldReply(1, to: "A") && r.shouldReply(1, to: "B"))
    expect("sessions: third viewer joins the live session", r.beginOpen(1, by: "C"), .alreadyLive)
    expect("sessions: one live session", r.openCount, 1)
    check("sessions: input accepted from a viewer with the window open", r.acceptsInput(1, from: "A"))
    check("sessions: input refused from someone who never opened it", !r.acceptsInput(1, from: "Z"))
    check("sessions: input refused for a window that is not open", !r.acceptsInput(2, from: "A"))

    check("sessions: release by one of several viewers keeps the session", !r.release(1, by: "A"))
    check("sessions: released viewer's input is refused", !r.acceptsInput(1, from: "A"))
    check("sessions: remaining viewer's input is still accepted", r.acceptsInput(1, from: "B"))
    check("sessions: release by someone who never opened it changes nothing", !r.release(1, by: "Z") && r.acceptsInput(1, from: "B"))
    check("sessions: release by the second-to-last viewer keeps it", !r.release(1, by: "B"))
    check("sessions: release by the last viewer stops the session", r.release(1, by: "C"))
    check("sessions: releasing again does nothing", !r.release(1, by: "C"))
    check("sessions: nothing left after the last release", r.openCount == 0 && r.viewers[1] == nil)

    var c = SessionRegistry()
    _ = c.beginOpen(5, by: "A")
    check("close during start: release before the capture is live stops nothing yet", !c.release(5, by: "A"))
    check("close during start: finishing the start reports it must be stopped", !c.startSucceeded(5))
    check("close during start: no opened reply and no session", !c.shouldReply(5, to: "A") && c.openCount == 0 && c.viewers[5] == nil)
    expect("close during start: a later open starts afresh", c.beginOpen(5, by: "A"), .start)

    var p = SessionRegistry()
    _ = p.beginOpen(6, by: "A"); _ = p.beginOpen(6, by: "B")
    _ = p.release(6, by: "A")
    check("partial close during start: session kept for the remaining viewer", p.startSucceeded(6))
    check("partial close during start: only the remaining viewer gets the reply", !p.shouldReply(6, to: "A") && p.shouldReply(6, to: "B"))

    var f = SessionRegistry()
    _ = f.beginOpen(7, by: "A"); _ = f.beginOpen(7, by: "B")
    f.startFailed(7)
    f.openFailed(7, by: "A"); f.openFailed(7, by: "B")
    check("failed start: viewers are removed and nothing is live", f.openCount == 0 && !f.shouldReply(7, to: "A") && !f.shouldReply(7, to: "B"))
    expect("failed start: the next open tries again", f.beginOpen(7, by: "A"), .start)

    var l = SessionRegistry()
    for id: UInt32 in [1, 2, 3] { _ = l.beginOpen(id, by: "A"); _ = l.startSucceeded(id) }
    _ = l.beginOpen(2, by: "B")
    expect("viewer leaves: every window only they had open is stopped", l.releaseAll(by: "A"), [1, 3])
    check("viewer leaves: shared window stays for the other viewer", l.acceptsInput(2, from: "B") && !l.acceptsInput(2, from: "A"))
    expect("viewer leaves: one session left", l.openCount, 1)

    var w = SessionRegistry()
    _ = w.beginOpen(9, by: "A"); _ = w.beginOpen(9, by: "B"); _ = w.startSucceeded(9)
    expect("window closed on the host: all its viewers are told", w.windowClosed(9), ["A", "B"])
    check("window closed on the host: input refused afterwards", !w.acceptsInput(9, from: "A") && w.openCount == 0)
    expect("window closed on the host: second notice is ignored", w.windowClosed(9), nil)
    var s = SessionRegistry()
    _ = s.beginOpen(4, by: "A")
    expect("window closed while still starting is ignored", s.windowClosed(4), nil)

    var z = SessionRegistry()
    for id: UInt32 in [8, 3] { _ = z.beginOpen(id, by: "A"); _ = z.startSucceeded(id) }
    expect("room rejoin: every live session is stopped", z.reset(), [3, 8])
    check("room rejoin: no viewers or input remain", z.openCount == 0 && z.viewers.isEmpty && !z.acceptsInput(3, from: "A"))
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    func add(_ s: String) { lock.lock(); value.append(s); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return value }
}

private struct Boom: Error, Equatable {}

private func startGateTests() {
    let done = DispatchSemaphore(value: 0)
    var results: [(String, Bool)] = []
    Task.detached {
        let gate = StartGate<UInt32>()
        var out: [(String, Bool)] = []
        do { try await gate.wait(1); out.append(("start gate: waiting with nothing started says still starting", false)) } catch {
            out.append(("start gate: waiting with nothing started says still starting", error is StillStarting))
        }
        let log = Flag()
        let task = gate.begin(1) {
            log.add("work began")
            try await Task.sleep(nanoseconds: 50_000_000)
            log.add("work done")
        }
        out.append(("start gate: the task is registered before its work runs any await", gate.keys == [1]))
        let waiter = Task { try await gate.wait(1); log.add("waiter done") }
        _ = try? await waiter.value
        _ = try? await task.value
        out.append(("start gate: a waiter that arrives at once gets the result only after the start finishes",
                    log.events == ["work began", "work done", "waiter done"]))
        let failing = gate.begin(2) { try await Task.sleep(nanoseconds: 10_000_000); throw Boom() }
        var waiterError: Error?
        do { try await gate.wait(2) } catch { waiterError = error }
        _ = try? await failing.value
        out.append(("start gate: a failed start fails its waiters too", waiterError is Boom))
        gate.finish(1)
        out.append(("start gate: finish forgets the start", gate.keys == [2]))
        do { try await gate.wait(1); out.append(("start gate: after finish a waiter is told it is still starting", false)) } catch {
            out.append(("start gate: after finish a waiter is told it is still starting", error is StillStarting))
        }
        out.append(("start gate: the still-starting message", StillStarting().localizedDescription == "The window is still starting. Try again in a moment."))
        results = out
        done.signal()
    }
    done.wait()
    for (name, ok) in results { check(name, ok) }
}
