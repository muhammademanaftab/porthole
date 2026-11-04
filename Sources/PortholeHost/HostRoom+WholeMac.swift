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

    var mode: () -> WholeMacMode = { .off }
    var ask: ((String, String) -> Void)?
    var settled: ((String) -> Void)?
    var liveChanged: ((Int, String?) -> Void)?
    var approvals = WholeMacApprovals()
    var waiting: [String: [Waiter]] = [:]
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
        guard WholeMac.offered(mode: wholeMac.mode(), viewer: WholeMac.viewer(who)) else { return [] }
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
            wholeMac.waiting[key] = [waiter]
            startApprovalExpiry()
            wholeMac.ask?(key, WholeMac.viewerName(who))
        case .waiting:
            guard let key = viewer.approvalKey else { return }
            var list = wholeMac.waiting[key] ?? []
            if !list.contains(where: { $0.id == id && $0.who == who }) { list.append(waiter) }
            wholeMac.waiting[key] = list
        }
    }

    func answerWholeMac(_ key: String, allow: Bool) {
        guard wholeMac.approvals.answer(key, allow: allow) else { return }
        let list = wholeMac.waiting.removeValue(forKey: key) ?? []
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
            let list = wholeMac.waiting.removeValue(forKey: key) ?? []
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
                    endScreenMatchIfIdle()
                    throw NSError(domain: "Porthole", code: 4, userInfo: [NSLocalizedDescriptionKey: "That display isn't connected any more."])
                }
                let session = WindowSession(windowID: id, display: display, prefs: sharedPrefs(id, adding: id))
                let room = room
                let task = starting.begin(id) { @MainActor in try await session.start(in: room) }
                do { try await task.value } catch {
                    starting.finish(id)
                    registry.startFailed(id)
                    await session.stop(in: room)
                    endScreenMatchIfIdle()
                    throw error
                }
                starting.finish(id)
                guard registry.startSucceeded(id) else {
                    viewerPrefs[id] = nil
                    await session.stop(in: room)
                    endScreenMatchIfIdle()
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
        guard let d = wholeMac.displays[id] else { return }
        input.handle(m, screen: CGDisplayBounds(d))
        sessions[id]?.noteInput()
    }

    private func endScreenMatchIfIdle() {
        guard liveScreenIDs.isEmpty, starting.keys.allSatisfy({ !WholeMac.isScreen($0) }) else { return }
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
