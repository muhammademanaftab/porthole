import AppKit
import LiveKit
import PortholeCore

@MainActor
final class WholeMacState {
    struct Waiter {
        var id: UInt32
        var who: String
        var screen: CGSize?
        var prefs: StreamPrefs
    }

    struct Request {
        var screen: CGSize?
        var prefs: StreamPrefs
    }

    var mode: () -> WholeMacMode = { .off }
    var ask: ((String, String) -> Void)?
    var settled: ((String) -> Void)?
    var liveChanged: ((Int, String?) -> Void)?
    var approvals = WholeMacApprovals()
    var queue = WholeMacQueue()
    var requests: [String: Request] = [:]
    var pendingStarts = 0
    var displays: [UInt32: CGDirectDisplayID] = [:]
    var expiry: Timer?
    let environment = ProcessInfo.processInfo.environment

    static var now: Double { ProcessInfo.processInfo.systemUptime }
}

extension HostRoom {
    private var liveScreenIDs: [UInt32] { sessions.keys.filter(WholeMac.isScreen).sorted() }

    private func currentScreens() -> (facts: [ScreenFacts], matched: Bool) {
        let facts = ScreenCatalog.facts(stage: stage.displayID)
        return (facts, !stage.matched.isEmpty || WholeMac.needsScreenMatch(facts, environment: wholeMac.environment))
    }

    func screenEntries(for who: String) -> [WindowInfo] {
        guard WholeMac.offered(mode: wholeMac.mode(), viewer: WholeMac.viewer(who)) else { return [] }
        let (facts, matched) = currentScreens()
        return WholeMac.entries(facts, matched: matched)
    }

    func screenThumbTargets(for who: String) -> [(id: UInt32, display: CGDirectDisplayID)] {
        guard wholeMac.approvals.isApproved(mode: wholeMac.mode(), viewer: WholeMac.viewer(who)) else { return [] }
        let (facts, matched) = currentScreens()
        if matched {
            guard let id = WholeMac.windowID(screen: 0), let d = stage.displayID ?? WholeMac.ordered(facts).first?.id else { return [] }
            return [(id, d)]
        }
        return WholeMac.ordered(facts).enumerated().compactMap { i, f in WholeMac.windowID(screen: i).map { ($0, f.id) } }
    }

    func openScreen(_ id: UInt32, by who: String, screen: CGSize?, prefs: StreamPrefs) async {
        let viewer = WholeMac.viewer(who)
        let waiter = WholeMacState.Waiter(id: id, who: who, screen: screen, prefs: prefs)
        switch wholeMac.approvals.request(mode: wholeMac.mode(), viewer: viewer, now: WholeMacState.now) {
        case .refuse(let why):
            Log.info("whole mac: refused \(who): \(why)")
            var reply = Message(.error); reply.win = id; reply.msg = why
            await send(reply, to: who)
        case .allow:
            await startScreen(waiter)
        case .ask(let key):
            Log.info("whole mac: asking whether \(who) may see the whole Mac")
            enqueue(key, waiter)
            startApprovalExpiry()
            wholeMac.ask?(key, WholeMac.viewerName(who))
        case .waiting:
            guard let key = viewer.approvalKey else { return }
            enqueue(key, waiter)
        }
    }

    private static func requestKey(_ id: UInt32, _ who: String) -> String { "\(id)|\(who)" }

    private func enqueue(_ key: String, _ w: WholeMacState.Waiter) {
        wholeMac.queue.add(key, WholeMacWaiter(id: w.id, who: w.who))
        wholeMac.requests[Self.requestKey(w.id, w.who)] = WholeMacState.Request(screen: w.screen, prefs: w.prefs)
    }

    private func dequeue(_ key: String) -> [WholeMacState.Waiter] {
        wholeMac.queue.take(key).map { w in
            let r = wholeMac.requests.removeValue(forKey: Self.requestKey(w.id, w.who))
            return WholeMacState.Waiter(id: w.id, who: w.who, screen: r?.screen, prefs: r?.prefs ?? .standard)
        }
    }

    private func isPresent(_ who: String) -> Bool {
        room.remoteParticipants[Participant.Identity(from: who)] != nil
    }

    func wholeMacViewerLeft(_ who: String) {
        for (k, _) in wholeMac.requests where k.hasSuffix("|\(who)") { wholeMac.requests[k] = nil }
        for key in wholeMac.queue.drop(who: who) {
            Log.info("whole mac: \(who) left before anyone answered; question withdrawn")
            wholeMac.approvals.cancel(key)
            wholeMac.settled?(key)
        }
    }

    func wholeMacReset() {
        for key in wholeMac.queue.removeAll().keys { wholeMac.settled?(key) }
        wholeMac.requests.removeAll()
        wholeMac.approvals.reset()
    }

    func wholeMacModeChanged() {
        let mode = wholeMac.mode()
        Log.info("whole mac: mode now \(mode.rawValue)")
        guard mode == .off else { return }
        wholeMacReset()
        let ids = WholeMac.sessionsToEnd(mode: mode, live: Array(sessions.keys))
        Task {
            for id in ids {
                Log.info("whole mac: turned off; ending \(id)")
                await self.windowClosed(id)
            }
            self.wholeMacChanged()
        }
    }

    func answerWholeMac(_ key: String, allow asked: Bool) {
        let allow = asked && wholeMac.mode() != .off
        guard wholeMac.approvals.answer(key, allow: allow) else { return }
        let list = dequeue(key)
        Log.info("whole mac: \(allow ? "allowed" : "declined") \(key) (\(list.count) request(s))")
        wholeMac.settled?(key)
        Task {
            for w in list {
                if allow { await self.startScreen(w) } else {
                    var reply = Message(.error); reply.win = w.id; reply.msg = WholeMacApprovals.declinedMessage
                    await self.send(reply, to: w.who)
                }
            }
        }
    }

    private func startApprovalExpiry() {
        guard wholeMac.expiry == nil else { return }
        wholeMac.expiry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireApprovals() }
        }
    }

    private func expireApprovals() {
        let gone = wholeMac.approvals.expire(now: WholeMacState.now)
        if wholeMac.approvals.pending.isEmpty { wholeMac.expiry?.invalidate(); wholeMac.expiry = nil }
        for key in gone {
            let list = dequeue(key)
            Log.info("whole mac: nobody answered for \(key)")
            wholeMac.settled?(key)
            Task {
                for w in list {
                    var reply = Message(.error); reply.win = w.id; reply.msg = WholeMacApprovals.unansweredMessage
                    await self.send(reply, to: w.who)
                }
            }
        }
    }

    private func resolveDisplay(_ id: UInt32, screen: CGSize?) async -> CGDirectDisplayID? {
        let (facts, matched) = currentScreens()
        Log.info("whole mac: displays \(ScreenCatalog.describe(facts)); screen match \(matched)")
        guard matched else { return WholeMac.target(id, screens: facts)?.id }
        guard WholeMac.screenIndex(id) == 0 else { return nil }
        await stage.ensure(screenPoints: screen)
        if stage.matched.isEmpty { stage.matchScreens() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return stage.displayID
    }

    private func startScreen(_ w: WholeMacState.Waiter) async {
        let id = w.id, who = w.who
        let mode = wholeMac.mode()
        let approved = wholeMac.approvals.isApproved(mode: mode, viewer: WholeMac.viewer(who))
        guard WholeMac.mayStart(mode: mode, approved: approved, viewerPresent: isPresent(who)) else {
            Log.info("whole mac: not starting \(id) for \(who) (mode \(mode.rawValue), approved \(approved), present \(isPresent(who)))")
            if mode == .off, isPresent(who) {
                var reply = Message(.error); reply.win = id; reply.msg = WholeMacApprovals.offMessage
                await send(reply, to: who)
            }
            return
        }
        wholeMac.pendingStarts += 1
        defer { wholeMac.pendingStarts -= 1 }
        viewerPrefs[id, default: [:]][who] = w.prefs
        do {
            switch registry.beginOpen(id, by: who) {
            case .alreadyLive:
                applyPrefs()
            case .waitForStart:
                try await starting.wait(id)
            case .start:
                guard let display = await resolveDisplay(id, screen: w.screen) else {
                    registry.startFailed(id)
                    endScreenMatchIfIdle(own: 1)
                    throw NSError(domain: "Porthole", code: 4, userInfo: [NSLocalizedDescriptionKey: "That display isn't connected any more."])
                }
                let session = WindowSession(windowID: id, display: display, prefs: sharedPrefs(id, adding: id))
                let room = room
                let task = starting.begin(id) { @MainActor in try await session.start(in: room) }
                do { try await task.value } catch {
                    starting.finish(id)
                    registry.startFailed(id)
                    await session.stop(in: room)
                    endScreenMatchIfIdle(own: 1)
                    throw error
                }
                starting.finish(id)
                guard registry.startSucceeded(id) else {
                    viewerPrefs[id] = nil
                    await session.stop(in: room)
                    endScreenMatchIfIdle(own: 1)
                    return
                }
                session.onClosed = { [weak self] in Task { await self?.windowClosed(id) } }
                sessions[id] = session
                wholeMac.displays[id] = display
                let size = CGDisplayBounds(display).size
                let title = WholeMac.title(index: WholeMac.screenIndex(id) ?? 0, of: max(1, WholeMac.ordered(ScreenCatalog.facts(stage: stage.displayID)).count),
                                           matched: !stage.matched.isEmpty)
                shared[id] = WindowInfo(id: id, app: WholeMac.appName, title: title, bundle: nil, w: size.width, h: size.height, screen: true)
                Log.info("whole mac: sharing display \(display) (\(Int(size.width))x\(Int(size.height)) pt) as \(id) with \(who)")
                applyPrefs()
                onChange?()
            }
            guard registry.shouldReply(id, to: who) else { return }
            var reply = Message(.opened)
            reply.win = id
            reply.track = Message.trackName(for: id)
            if let d = wholeMac.displays[id] { let b = CGDisplayBounds(d); reply.w = b.width; reply.h = b.height }
            await send(reply, to: who)
        } catch {
            registry.openFailed(id, by: who)
            viewerPrefs[id]?[who] = nil
            if viewerPrefs[id]?.isEmpty == true { viewerPrefs[id] = nil }
            var reply = Message(.error); reply.win = id; reply.msg = error.localizedDescription
            await send(reply, to: who)
        }
    }

    func screenInput(_ m: Message, _ id: UInt32) {
        guard WholeMac.mayControl(mode: wholeMac.mode()), let d = wholeMac.displays[id] else { return }
        input.handle(m, screen: CGDisplayBounds(d))
        sessions[id]?.noteInput()
    }

    private func endScreenMatchIfIdle(own: Int = 0) {
        guard liveScreenIDs.isEmpty, wholeMac.pendingStarts <= own, starting.keys.allSatisfy({ !WholeMac.isScreen($0) }) else { return }
        stage.unmatchScreens()
    }

    func wholeMacChanged() {
        wholeMac.displays = wholeMac.displays.filter { sessions[$0.key] != nil }
        let live = liveScreenIDs
        if live.isEmpty { endScreenMatchIfIdle() }
        let viewer = live.lazy.compactMap { self.registry.viewers[$0]?.sorted().first }.first.map(WholeMac.viewerName)
        wholeMac.liveChanged?(live.count, viewer)
    }
}
