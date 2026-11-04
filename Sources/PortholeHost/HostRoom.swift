import AppKit
import LiveKit
import PortholeCore

@MainActor
final class HostRoom: NSObject, RoomDelegate {
    let room = Room()
    let input = InputInjector()
    let stage = Stage()
    let audio = AppAudio()
    var sessions: [UInt32: WindowSession] = [:]
    let starting = StartGate<UInt32>()
    var registry = SessionRegistry()
    var viewerPrefs: [UInt32: [String: StreamPrefs]] = [:]
    private var url = ""
    private var makeToken: (() -> String)?
    private var reconnecting = false
    private var clip = ClipboardSync(changeCount: NSPasteboard.general.changeCount)
    private var clipTimer: Timer?
    private var lockWarnedAt: [String: Date] = [:]
    private var thumbTasks: [String: Task<Void, Never>] = [:]
    private var thumbAskedAt: [String: Date] = [:]
    private var thumbTaskIDs: [String: UUID] = [:]
    var shared: [UInt32: WindowInfo] = [:]
    private var tracker = CompanionTracker()
    private var baselines: [UInt32: Set<UInt32>] = [:]
    private var companionTimer: Timer?
    private var resizes = LatestWins<UInt32, ResizeJob>()
    let wholeMac = WholeMacState()

    struct ResizeJob: Sendable {
        var message: Message
        var who: String
    }
    var companionsEnabled: () -> Bool = { true }
    var onChange: (() -> Void)?
    var accepts: ((String) -> Bool)?
    var onRestart: ((String, Bool) -> String?)?
    private(set) var isConnected = false

    var openWindowCount: Int { parentIDs.count }

    private var parentIDs: [UInt32] { sessions.keys.filter { tracker.parent(of: $0) == nil }.sorted() }

    var sharedWindows: [(info: WindowInfo, viewers: Int)] {
        WindowFilter.sortedForPicker(parentIDs.compactMap { shared[$0] }).map { ($0, registry.viewers[$0.id]?.count ?? 0) }
    }

    func connect(url: String, makeToken: @escaping () -> String) async throws {
        self.url = url
        self.makeToken = makeToken
        room.add(delegate: self)
        AppAudio.prepare()
        try await room.registerTextStreamHandler(for: clipboardTopic) { [weak self] reader, identity in
            let text = try await reader.readAll()
            await self?.clipboardReceived(text, from: identity.stringValue)
        }
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        companionTimer = Timer.scheduledTimer(withTimeInterval: CompanionRules.pollSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCompanions() }
        }
        try await join()
    }

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard let text = clip.outgoing(changeCount: pb.changeCount, text: { pb.string(forType: .string) }) else { return }
        let to = registry.activeViewers
        guard !to.isEmpty else { return }
        Log.info("clipboard: sending \(text.utf8.count) bytes to \(to.count) viewer(s)")
        let opts = StreamTextOptions(topic: clipboardTopic, destinationIdentities: to.map { Participant.Identity(from: $0) })
        Task { do { _ = try await room.localParticipant.sendText(text, options: opts) } catch {
            Log.info("clipboard send failed: \(error.localizedDescription)")
        } }
    }

    private func clipboardReceived(_ text: String, from who: String) {
        guard accepts?(who) ?? true, registry.activeViewers.contains(who), clip.incoming(text) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        clip.applied(changeCount: pb.changeCount)
        Log.info("clipboard: received \(text.utf8.count) bytes from \(who)")
    }

    private func join() async throws {
        let opts = RoomOptions(adaptiveStream: false, dynacast: true, suspendLocalVideoTracksInBackground: false)
        try await room.connect(url: url, token: makeToken?() ?? "", roomOptions: opts)
        isConnected = true
        onChange?()
    }

    private func rejoin() async {
        guard !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        await audio.removeAll(in: room)
        for id in registry.reset() {
            if let session = sessions.removeValue(forKey: id) { await session.stop(in: room) }
        }
        viewerPrefs.removeAll()
        _ = tracker.removeAll()
        baselines.removeAll()
        stage.unparkAll()
        stage.becameEmpty()
        input.releaseAllButtons()
        var delay: UInt64 = 1
        while true {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            do {
                try await join()
                Log.info("host rejoined the room")
                return
            } catch {
                Log.info("rejoin failed: \(error.localizedDescription)")
                delay = nextBackoff(delay)
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == portholeTopic, let m = Message.decode(data),
              let who = participant?.identity?.stringValue else { return }
        Task { @MainActor in
            guard self.accepts?(who) ?? true else { return }
            await self.handle(m, from: who)
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Log.info("viewer joined: \(participant.identity?.stringValue ?? "?")")
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard let who = participant.identity?.stringValue else { return }
        Task { @MainActor in
            Log.info("viewer left: \(who)")
            self.thumbTasks.removeValue(forKey: who)?.cancel()
            self.thumbAskedAt[who] = nil
            self.thumbTaskIDs[who] = nil
            self.input.releaseAllButtons()
            for id in self.viewerPrefs.keys { self.viewerPrefs[id]?[who] = nil }
            for id in self.registry.releaseAll(by: who) { await self.stopSession(id) }
            self.applyPrefs()
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Log.info("host left the room: \(error?.localizedDescription ?? "no error")")
        Task { @MainActor in
            self.isConnected = false
            self.onChange?()
            await self.rejoin()
        }
    }

    private func handle(_ m: Message, from who: String) async {
        if m.t != .mouse && m.t != .key { Log.info("\(m.t.rawValue) from \(who)") } else { Log.debug("\(m.t.rawValue) from \(who) win \(m.win ?? 0)") }
        switch m.t {
        case .list:
            var reply = Message(.windows)
            Power.wakeDisplay()
            do {
                let windows = try await WindowCatalog.list()
                reply.list = screenEntries(for: who) + windows
                if windows.isEmpty, Session.isScreenLocked {
                    Log.info("screen is locked; no windows to list")
                    var warn = Message(.error); warn.msg = Session.lockedListMessage
                    await send(warn, to: who)
                }
            } catch {
                Log.info("listing windows failed: \(error.localizedDescription)")
                reply = Message(.error); reply.msg = "Can't list windows: \(error.localizedDescription). Check Screen Recording permission."
            }
            await send(reply, to: who)
        case .open:
            guard let id = m.win else { return }
            let screen = (m.sw ?? 0) >= 1 && (m.sh ?? 0) >= 1 ? CGSize(width: m.sw!, height: m.sh!) : nil
            if WholeMac.isScreen(id) { await openScreen(id, by: who, screen: screen, prefs: StreamPrefs(open: m)); return }
            await open(id, by: who, screen: screen, prefs: StreamPrefs(open: m))
        case .close:
            guard let id = m.win else { return }
            await release(id, by: who)
        case .icon:
            guard let id = m.win else { return }
            await sendIcon(id, to: who)
        case .thumb:
            sendThumbnails(to: who)
        case .key, .text, .mouse, .scroll, .resize:
            guard let id = m.win, registry.acceptsInput(id, from: who) else { return }
            if WholeMac.isScreen(id) { screenInput(m, id); return }
            await warnIfLocked(who)
            input.handle(m)
            sessions[id]?.noteInput()
            if m.t == .resize {
                guard resizes.offer(id, ResizeJob(message: m, who: who)) else { return }
                while let job = resizes.next(id) {
                    if let r = input.resize(job.message), PortalSizing.hostShouldReply(asked: r.asked, actual: r.actual) {
                        var reply = Message(.sized)
                        reply.win = id; reply.w = r.actual.width; reply.h = r.actual.height
                        reply.aw = r.asked.width; reply.ah = r.asked.height
                        await send(reply, to: job.who)
                    }
                    sessions[id]?.followSizeSoon()
                    await Task.yield()
                }
            }
        case .restart:
            let refusal = onRestart.map { $0(who, registry.activeViewers.contains(who)) } ?? "This host can't restart itself."
            guard let refusal else { return }
            var reply = Message(.error); reply.msg = refusal
            await send(reply, to: who)
        default:
            break
        }
    }

    private func open(_ id: UInt32, by who: String, screen: CGSize?, prefs: StreamPrefs) async {
        let parentOfCompanion = tracker.parent(of: id)
        let companion = parentOfCompanion != nil
        if let p = parentOfCompanion, !tracker.mayOpen(id, by: who, parentViewers: registry.viewers[p] ?? []) { return }
        if tracker.wasCompanion(id) {
            var reply = Message(.error); reply.win = id; reply.msg = "That dialog has closed."
            await send(reply, to: who)
            return
        }
        let found = companion ? (try? await WindowCatalog.window(id: id)) ?? nil
            : (try? await WindowCatalog.shareable(onScreenOnly: false))?.first { $0.windowID == id }
        guard let found, !(companion && CompanionRules.isBlocked(found.owningApplication?.bundleIdentifier)) else {
            var reply = Message(.error); reply.win = id; reply.msg = "That window can't be shared."
            await send(reply, to: who)
            return
        }
        viewerPrefs[id, default: [:]][who] = prefs
        do {
            switch registry.beginOpen(id, by: who) {
            case .alreadyLive:
                applyPrefs()
            case .waitForStart:
                try await starting.wait(id)
            case .start:
                let session = WindowSession(windowID: id, prefs: sharedPrefs(id, adding: id))
                let stage = stage, room = room
                let task = starting.begin(id) { @MainActor in
                    if !companion, await stage.leaveFullscreen(id) {
                        await stage.ensure(screenPoints: screen)
                        await stage.park(id)
                    }
                    try await session.start(in: room)
                }
                do { try await task.value } catch {
                    starting.finish(id)
                    registry.startFailed(id)
                    await session.stop(in: room)
                    stage.unpark(id)
                    if sessions.isEmpty { stage.becameEmpty() }
                    throw error
                }
                starting.finish(id)
                guard registry.startSucceeded(id) else {
                    viewerPrefs[id] = nil
                    await session.stop(in: room)
                    stage.unpark(id)
                    if sessions.isEmpty { stage.becameEmpty() }
                    return
                }
                if companion && tracker.parent(of: id) == nil {
                    let told = registry.windowClosed(id) ?? []
                    viewerPrefs[id] = nil
                    await session.stop(in: room)
                    if sessions.isEmpty { stage.becameEmpty() }
                    var reply = Message(.error); reply.win = id; reply.msg = "That dialog has closed."
                    for v in told.union([who]).sorted() { await send(reply, to: v) }
                    return
                }
                session.onClosed = { [weak self] in Task { await self?.windowClosed(id) } }
                sessions[id] = session
                if !companion { baselines[id] = Self.onScreenWindowIDs() }
                if !companion { shared[id] = WindowInfo(id: id, app: found.owningApplication?.applicationName ?? "", title: found.title ?? "",
                                        bundle: found.owningApplication?.bundleIdentifier, w: found.frame.width, h: found.frame.height) }
                applyPrefs()
                onChange?()
                if !companion, let pid = session.pid { await audio.add(window: id, pid: pid, in: room) }
            }
            guard registry.shouldReply(id, to: who) else { return }
            var reply = Message(.opened)
            reply.win = id
            reply.track = Message.trackName(for: id)
            if !companion {
                await audio.settled()
                if audio.isLive { reply.audio = Message.audioTrackName }
            }
            if let live = LiveWindow.lookup(id) { reply.w = live.bounds.width; reply.h = live.bounds.height }
            await send(reply, to: who)
            await warnIfLocked(who)
        } catch {
            registry.openFailed(id, by: who)
            viewerPrefs[id]?[who] = nil
            if viewerPrefs[id]?.isEmpty == true { viewerPrefs[id] = nil }
            var reply = Message(.error); reply.win = id; reply.msg = error.localizedDescription
            await send(reply, to: who)
        }
    }

    private func release(_ id: UInt32, by who: String) async {
        viewerPrefs[id]?[who] = nil
        tracker.release(id, by: who)
        tracker.parentReleased(id, by: who)
        if registry.release(id, by: who) { await stopSession(id) }
        applyPrefs()
    }

    func sharedPrefs(_ id: UInt32, adding extra: UInt32? = nil) -> StreamPrefs {
        var live = Set(sessions.keys).union(starting.keys).filter { tracker.parent(of: $0) == nil || $0 == id }
        if let extra { live.insert(extra) }
        let viewers = (viewerPrefs[id] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        return StreamPrefs.combined(viewers, onlySharedWindow: live == [id])
    }

    func applyPrefs() {
        for (id, session) in sessions { session.update(prefs: sharedPrefs(id)) }
    }

    private func stopSession(_ id: UInt32) async {
        viewerPrefs[id] = nil
        guard let session = sessions.removeValue(forKey: id) else { return }
        input.forget(id)
        shared[id] = nil
        baselines[id] = nil
        await audio.remove(window: id, in: room)
        await session.stop(in: room)
        stage.unpark(id)
        if sessions.isEmpty { stage.becameEmpty() }
        applyPrefs()
        onChange?()
    }

    func windowClosed(_ id: UInt32) async {
        guard let who = registry.windowClosed(id), let session = sessions.removeValue(forKey: id) else { return }
        viewerPrefs[id] = nil
        input.forget(id)
        shared[id] = nil
        baselines[id] = nil
        await audio.remove(window: id, in: room)
        await session.stop(in: room)
        stage.unpark(id)
        if sessions.isEmpty { stage.becameEmpty() }
        applyPrefs()
        var m = Message(.closed); m.win = id
        for v in who { await send(m, to: v) }
        onChange?()
    }

    static func onScreenWindowIDs() -> Set<UInt32> {
        Set(onScreenWindows().map(\.id))
    }

    static func onScreenWindows() -> [WindowSnapshot] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap(WindowSnapshot.init(cgInfo:))
    }

    private func pollCompanions() {
        let parents = parentIDs.filter { registry.live.contains($0) }
        let actions: [CompanionTracker.Action]
        if companionsEnabled(), !parents.isEmpty {
            var bundles: [Int32: String?] = [:]
            let windows = Self.onScreenWindows().map { w -> WindowSnapshot in
                var w = w
                if bundles[w.pid] == nil { bundles[w.pid] = .some(NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier) }
                w.bundle = bundles[w.pid] ?? nil
                return w
            }
            let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var input: [UInt32: CompanionTracker.Parent] = [:]
            for p in parents {
                input[p] = CompanionTracker.Parent(window: byID[p], baseline: baselines[p] ?? [], viewers: registry.viewers[p] ?? [],
                                                   appActive: byID[p].map { $0.pid == front } ?? false)
            }
            actions = tracker.update(parents: input, windows: windows) { parent, ids in
                guard let pid = byID[parent]?.pid else { return [] }
                return AXWindows.attachedWindowIDs(parent: parent, pid: pid).intersection(ids)
            }
        } else {
            guard !tracker.records.isEmpty else { return }
            actions = tracker.removeAll()
        }
        guard !actions.isEmpty else { return }
        Task { await self.apply(actions) }
    }

    private func apply(_ actions: [CompanionTracker.Action]) async {
        for a in actions {
            switch a {
            case .announce(let m, let who):
                Log.info("companion: window \(m.win ?? 0) over \(m.of ?? 0) offered to \(who) at \(Int(m.x ?? 0)),\(Int(m.y ?? 0)) \(Int(m.w ?? 0))x\(Int(m.h ?? 0))")
                await send(m, to: who)
            case .gone(let id, let told):
                Log.info("companion: window \(id) gone")
                var viewers = told
                if let v = registry.windowClosed(id) { viewers.formUnion(v) }
                if let session = sessions.removeValue(forKey: id) {
                    viewerPrefs[id] = nil
                    input.forget(id)
                    await session.stop(in: room)
                    if sessions.isEmpty { stage.becameEmpty() }
                    applyPrefs()
                    onChange?()
                }
                var m = Message(.closed); m.win = id
                for v in viewers.sorted() { await send(m, to: v) }
            }
        }
    }

    private func sendThumbnails(to who: String) {
        let now = Date()
        guard WindowThumbnail.shouldServe(lastAsked: thumbAskedAt[who], now: now) else { return }
        thumbAskedAt[who] = now
        thumbTasks[who]?.cancel()
        let token = UUID()
        thumbTaskIDs[who] = token
        let screens = screenThumbTargets(for: who)
        thumbTasks[who] = Task { [weak self] in
            let deliver: (UInt32, Data) async -> Void = { [weak self] id, jpeg in
                guard let self, !Task.isCancelled else { return }
                let opts = StreamByteOptions(topic: thumbTopic, attributes: AppIcon.attributes(win: id),
                                             destinationIdentities: [Participant.Identity(from: who)],
                                             mimeType: "image/jpeg", name: "thumb-\(id).jpg", totalSize: jpeg.count)
                do { _ = try await self.room.localParticipant.sendBytes(jpeg, options: opts) } catch {
                    Log.info("thumbnail send to \(who) failed: \(error.localizedDescription)")
                }
            }
            await Thumbnails.screens(screens, deliver)
            await Thumbnails.each(deliver)
            guard let self, self.thumbTaskIDs[who] == token else { return }
            self.thumbTasks[who] = nil
            self.thumbTaskIDs[who] = nil
        }
    }

    private func sendIcon(_ id: UInt32, to who: String) async {
        guard let png = await AppIcons.png(forWindow: id) else { Log.info("no icon for window \(id)"); return }
        let opts = StreamByteOptions(topic: iconTopic, attributes: AppIcon.attributes(win: id),
                                     destinationIdentities: [Participant.Identity(from: who)],
                                     mimeType: "image/png", name: "icon-\(id).png", totalSize: png.count)
        do { _ = try await room.localParticipant.sendBytes(png, options: opts) } catch {
            Log.info("icon send to \(who) failed: \(error.localizedDescription)")
        }
    }

    private func warnIfLocked(_ who: String) async {
        guard Session.isScreenLocked else { return }
        if let last = lockWarnedAt[who], Date().timeIntervalSince(last) < 15 { return }
        lockWarnedAt[who] = Date()
        Log.info("screen is locked; warning \(who)")
        var m = Message(.error); m.msg = Session.lockedMessage
        await send(m, to: who)
    }

    func send(_ m: Message, to who: String) async {
        let opts = DataPublishOptions(destinationIdentities: [Participant.Identity(from: who)], topic: portholeTopic, reliable: true)
        do { try await room.localParticipant.publish(data: m.encoded(), options: opts) } catch {
            Log.info("send to \(who) failed: \(error.localizedDescription)")
        }
    }
}
