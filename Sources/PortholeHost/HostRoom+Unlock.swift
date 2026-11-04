import Foundation
import PortholeCore

extension HostRoom {
    func unlockRequested(_ m: Message, from who: String) async {
        if let refusal = UnlockPolicy.check(identity: who, password: m.s, screenLocked: Session.isScreenLocked,
                                            mayPost: InputInjector.isTrusted, limiter: &unlockLimiter, now: Date()) {
            await finishUnlock(.refused(refusal), for: who)
            return
        }
        Log.info("unlock: \(who) asks to unlock the screen; waking the display", .trust)
        let input = input
        let run = LockScreenUnlock(
            isLocked: { Session.isScreenLocked },
            wake: { Power.wakeDisplay() },
            type: { await input.typeIntoLockScreen($0, stillLocked: { Session.isScreenLocked }) },
            sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
            typed: { Log.info("unlock: typed into the lock screen", .trust) })
        let outcome: UnlockOutcome
        switch await run.run(m.s ?? "") {
        case .unlockedBeforeTyping:
            unlockLimiter.abandoned()
            outcome = .refused(.notLocked)
        case .unlockedWhileTyping:
            unlockLimiter.abandoned()
            outcome = .unlockedWhileTyping
        case .unlocked:
            _ = unlockLimiter.finished(unlocked: true, now: Date())
            outcome = .unlocked
        case .stillLocked:
            outcome = .stillLocked(triesLeft: unlockLimiter.finished(unlocked: false, now: Date()))
        }
        await finishUnlock(outcome, for: who)
    }

    private func finishUnlock(_ outcome: UnlockOutcome, for who: String) async {
        Log.info("\(outcome.logLine) (asked by \(who))", .trust)
        await send(outcome.reply(), to: who)
        if outcome.isUnlocked { onChange?() }
    }
}
