import CoreGraphics
import Foundation
import PortholeCore

func unlockTests() {
    unlockMessageTests()
    unlockPolicyTests()
    unlockLimiterTests()
    unlockTypingTests()
    unlockRunTests()
    unlockEnvTests()
}

private let owner = pairedIdentity(name: "Studio", suffix: "ab12", device: "0123456789abcdef")
private let pwViewer = "view-browser-ab12"

private func unlockMessageTests() {
    expect("unlock: the wire kind is \"unlock\"", Message.Kind.unlock.rawValue, "unlock")
    let ask = Message.decode(Data(#"{"t":"unlock","s":"hunter2"}"#.utf8))
    check("unlock: a browser request decodes with the password in s", ask?.t == .unlock && ask?.s == "hunter2")
    let reply = UnlockOutcome.unlocked.reply()
    let wire = json(reply.encoded())
    expect("unlock: the reply carries only t, on and msg", Set(wire?.keys.map { $0 } ?? []), ["t", "on", "msg"])
    check("unlock: an unlocked reply says on", wire?["on"] as? Bool == true)
    let still = UnlockOutcome.stillLocked(triesLeft: 2).reply()
    check("unlock: a still-locked reply says off and never echoes a password", still.on == false && still.s == nil)
    check("unlock: refusals reply off", UnlockOutcome.refused(.notLocked).reply().on == false)
    check("unlock: guests can't send it through the guest gate",
          GuestAccess.request(for: Message(.unlock), parent: { _ in nil }) == nil)
    check("unlock: both lock notices count as locked", UnlockPrompt.isLockNotice(LockNotice.list) && UnlockPrompt.isLockNotice(LockNotice.control))
    check("unlock: other errors don't", !UnlockPrompt.isLockNotice("Can't list windows") && !UnlockPrompt.isLockNotice(nil))
    expect("unlock: the sheet text names the Mac", UnlockPrompt.message(host: "Mac mini"),
           "Type Mac mini's login password. Porthole types it into the lock screen and doesn't keep it.")
    expect("unlock: still locked with tries left", UnlockOutcome.stillLocked(triesLeft: 1).message,
           "The screen is still locked. The password may be wrong. 1 more try before Porthole pauses unlocking for 10 minutes.")
    expect("unlock: still locked with no tries left", UnlockOutcome.stillLocked(triesLeft: 0).message,
           "The screen is still locked. The password may be wrong. Porthole pauses unlocking for 10 minutes.")
    expect("unlock: log lines never carry the password", UnlockOutcome.refused(.tooSoon(seconds: 3)).logLine,
           "unlock: refused (too soon, 3 s after the last attempt)")
}

private func unlockPolicyTests() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check("unlock: a paired Mac is an owner", UnlockPolicy.isOwner(owner))
    check("unlock: a host-password viewer is an owner", UnlockPolicy.isOwner(pwViewer))
    check("unlock: a share-link guest is not", !UnlockPolicy.isOwner("guest-abcdef12-xyz123"))
    check("unlock: an unknown identity is not", !UnlockPolicy.isOwner("probe"))
    var l = UnlockLimiter()
    expect("unlock: a guest is refused before anything else",
           UnlockPolicy.check(identity: "guest-abcdef12-xyz123", password: "pw", screenLocked: true, mayPost: true, limiter: &l, now: t0), .notOwner)
    expect("unlock: a guest refusal doesn't start an attempt", l.running, false)
    expect("unlock: no password", UnlockPolicy.check(identity: owner, password: nil, screenLocked: true, mayPost: true, limiter: &l, now: t0), .noPassword)
    expect("unlock: empty password", UnlockPolicy.check(identity: owner, password: "", screenLocked: true, mayPost: true, limiter: &l, now: t0), .noPassword)
    expect("unlock: a password with a line break is refused",
           UnlockPolicy.check(identity: owner, password: "ab\ncd", screenLocked: true, mayPost: true, limiter: &l, now: t0), .untypeable)
    expect("unlock: a password with a tab is refused",
           UnlockPolicy.check(identity: owner, password: "ab\tcd", screenLocked: true, mayPost: true, limiter: &l, now: t0), .untypeable)
    expect("unlock: an overlong password is refused",
           UnlockPolicy.check(identity: owner, password: String(repeating: "a", count: 257), screenLocked: true, mayPost: true, limiter: &l, now: t0), .untypeable)
    check("unlock: unicode and spaces are typeable", UnlockPolicy.typeable("pässwörd 日本 👍"))
    expect("unlock: an unlocked screen is refused",
           UnlockPolicy.check(identity: owner, password: "pw", screenLocked: false, mayPost: true, limiter: &l, now: t0), .notLocked)
    expect("unlock: without Accessibility it is refused",
           UnlockPolicy.check(identity: owner, password: "pw", screenLocked: true, mayPost: false, limiter: &l, now: t0), .noPermission)
    expect("unlock: a refused request doesn't count as an attempt", l.running, false)
    expect("unlock: an owner on a locked screen may try",
           UnlockPolicy.check(identity: pwViewer, password: "pw", screenLocked: true, mayPost: true, limiter: &l, now: t0), nil)
    check("unlock: the attempt is running", l.running)
    expect("unlock: a second request while one runs is busy",
           UnlockPolicy.check(identity: owner, password: "pw", screenLocked: true, mayPost: true, limiter: &l, now: t0.addingTimeInterval(1)), .busy)
}

private func unlockLimiterTests() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    var l = UnlockLimiter()
    expect("limiter: the first attempt starts", l.begin(now: t0), nil)
    expect("limiter: a failure leaves 2 tries", l.finished(unlocked: false, now: t0.addingTimeInterval(1)), 2)
    expect("limiter: one attempt per 5 s", l.begin(now: t0.addingTimeInterval(4)), .tooSoon(seconds: 1))
    expect("limiter: the gap counts from the attempt's start", l.begin(now: t0.addingTimeInterval(5)), nil)
    expect("limiter: a second failure leaves 1 try", l.finished(unlocked: false, now: t0.addingTimeInterval(6)), 1)
    expect("limiter: a third attempt starts", l.begin(now: t0.addingTimeInterval(20)), nil)
    expect("limiter: the third failure pauses", l.finished(unlocked: false, now: t0.addingTimeInterval(21)), 0)
    expect("limiter: paused for 10 minutes", l.begin(now: t0.addingTimeInterval(30)), .pausedAfterFailures(seconds: 591))
    expect("limiter: still paused a second before the end", l.begin(now: t0.addingTimeInterval(620)), .pausedAfterFailures(seconds: 1))
    expect("limiter: the pause ends after 10 minutes", l.begin(now: t0.addingTimeInterval(621)), nil)
    expect("limiter: after the pause the count starts again", l.finished(unlocked: false, now: t0.addingTimeInterval(622)), 2)
    expect("limiter: paused message", UnlockRefusal.pausedAfterFailures(seconds: 591).message, "Too many wrong passwords. Try again in 10 minutes.")
    expect("limiter: one-minute label", UnlockLimiter.minutesLabel(40), "1 minute")

    var spread = UnlockLimiter()
    _ = spread.begin(now: t0); _ = spread.finished(unlocked: false, now: t0)
    _ = spread.begin(now: t0.addingTimeInterval(300)); _ = spread.finished(unlocked: false, now: t0.addingTimeInterval(300))
    _ = spread.begin(now: t0.addingTimeInterval(601))
    expect("limiter: failures older than 10 minutes drop out", spread.finished(unlocked: false, now: t0.addingTimeInterval(601)), 1)

    var good = UnlockLimiter()
    _ = good.begin(now: t0); _ = good.finished(unlocked: false, now: t0)
    _ = good.begin(now: t0.addingTimeInterval(10)); _ = good.finished(unlocked: true, now: t0.addingTimeInterval(10))
    _ = good.begin(now: t0.addingTimeInterval(20))
    expect("limiter: a success clears earlier failures", good.finished(unlocked: false, now: t0.addingTimeInterval(20)), 2)

    var gone = UnlockLimiter()
    _ = gone.begin(now: t0)
    gone.abandoned()
    expect("limiter: an abandoned attempt stops running", gone.running, false)
    expect("limiter: an abandoned attempt still holds the 5 s gap", gone.begin(now: t0.addingTimeInterval(2)), .tooSoon(seconds: 3))
}

private func unlockTypingTests() {
    expect("typing: one piece per character, emoji kept whole", LockScreenTyping.pieces("aé👍").map(\.count), [1, 1, 2])
    let events = LockScreenTyping.events("ab", source: nil)
    expect("typing: a down and an up per character, then Return", events.count, 6)
    expect("typing: every event is a key event", Set(events.map(\.type.rawValue)), [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue])
    let text = events.prefix(4).map { e -> String in
        var len = 0
        var buf = [UniChar](repeating: 0, count: 4)
        e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        return String(utf16CodeUnits: buf, count: len)
    }
    expect("typing: each pair carries its character", text, ["a", "a", "b", "b"])
    expect("typing: the last pair is Return", events.suffix(2).map { $0.getIntegerValueField(.keyboardEventKeycode) }, [36, 36])
    check("typing: no modifiers on any event", events.allSatisfy { $0.flags.intersection([.maskShift, .maskCommand, .maskAlternate, .maskControl]).isEmpty })
}

private final class FakeMac: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    private var lockedReads: [Bool]
    init(locked: [Bool]) { lockedReads = locked }
    func note(_ s: String) { lock.lock(); steps.append(s); lock.unlock() }
    func isLocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        steps.append("check")
        return lockedReads.count > 1 ? lockedReads.removeFirst() : (lockedReads.first ?? true)
    }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return steps }
}

private func unlockRunTests() {
    let done = DispatchSemaphore(value: 0)
    var results: [(String, Bool)] = []
    Task.detached {
        var out: [(String, Bool)] = []
        func runner(_ mac: FakeMac) -> LockScreenUnlock {
            LockScreenUnlock(isLocked: { mac.isLocked() }, wake: { mac.note("wake") }, type: { mac.note("type \($0.count)") },
                             sleep: { mac.note("sleep \($0)") }, typed: { mac.note("typed") })
        }
        let ok = FakeMac(locked: [true, true, true, false])
        let r1 = await runner(ok).run("pw")
        out.append(("run: wakes, waits, checks, types, then polls until unlocked", r1 == .unlocked
                    && ok.log == ["wake", "sleep 1.5", "check", "type 2", "typed", "sleep 0.5", "check", "sleep 0.5", "check", "sleep 0.5", "check"]))
        let stuck = FakeMac(locked: [true])
        let r2 = await runner(stuck).run("pw")
        let polls = stuck.log.filter { $0 == "sleep 0.5" }.count
        out.append(("run: gives up after about 8 s still locked", r2 == .stillLocked && polls == 16))
        let early = FakeMac(locked: [false])
        let r3 = await runner(early).run("pw")
        out.append(("run: never types when the screen unlocked during the wake wait", r3 == .unlockedBeforeTyping
                    && !early.log.contains { $0.hasPrefix("type") }))
        results = out
        done.signal()
    }
    done.wait()
    for (name, ok) in results { check(name, ok) }
}

private func unlockEnvTests() {
    expect("env: secs:password parses", UnlockEnv.parse("5:hunter2"), UnlockEnv.Request(delay: 5, password: "hunter2"))
    expect("env: the password may contain colons", UnlockEnv.parse("0:a:b"), UnlockEnv.Request(delay: 0, password: "a:b"))
    expect("env: unset", UnlockEnv.parse(nil), nil)
    expect("env: no colon", UnlockEnv.parse("hunter2"), nil)
    expect("env: not a number", UnlockEnv.parse("x:hunter2"), nil)
    expect("env: negative", UnlockEnv.parse("-1:hunter2"), nil)
    expect("env: empty password", UnlockEnv.parse("3:"), nil)
    expect("env: too long a wait", UnlockEnv.parse("601:pw"), nil)
    let flag = EnvFlags.all.first { $0.name == UnlockEnv.name }
    check("env: PORTHOLE_OPEN_UNLOCK is listed for the viewer", flag?.scope == "viewer")
    check("env: PORTHOLE_OPEN_UNLOCK is masked", flag?.secret == true)
    let rows = EnvFlags.rows(environment: [UnlockEnv.name: "5:hunter2"], setOnly: true)
    check("env: porthole env never prints the value", rows.count == 1 && !EnvFlags.render(rows).contains("hunter2") && EnvFlags.shown(rows[0]) != "5:hunter2")
}
