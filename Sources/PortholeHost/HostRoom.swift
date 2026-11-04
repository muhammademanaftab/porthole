import AppKit
import LiveKit
import PortholeCore

@MainActor
final class HostRoom: NSObject, RoomDelegate {
    let room = Room()
    let input = InputInjector()
    let stage = Stage()
    let audio = AppAudio()
    private var sessions: [UInt32: WindowSession] = [:]
    private var starting: [UInt32: Task<Void, Error>] = [:]
    private var registry = SessionRegistry()
    private var url = ""
    private var makeToken: (() -> String)?
    private var reconnecting = false
    private var clip = ClipboardSync(changeCount: NSPasteboard.general.changeCount)
    private var clipTimer: Timer?
    private var lockWarnedAt: [String: Date] = [:]
    var onChange: (() -> Void)?
    var onRestart: ((String, Bool) -> String?)?
    private(set) var isConnected = false

    var openWindowCount: Int { sessions.count }

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
        guard registry.activeViewers.contains(who), clip.incoming(text) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        clip.applied(changeCount: pb.changeCount)
        Log.info("clipboard: received \(text.utf8.count) bytes from \(who)")
    }

    private func join() async throws {
        let opts = RoomOptions(adaptiveStream: false, dynacast: false, suspendLocalVideoTracksInBackground: false)
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
        Task { @MainActor in await self.handle(m, from: who) }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Log.info("viewer joined: \(participant.identity?.stringValue ?? "?")")
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard let who = participant.identity?.stringValue else { return }
        Task { @MainActor in
            Log.info("viewer left: \(who)")
            self.input.releaseAllButtons()
            for id in self.registry.releaseAll(by: who) { await self.stopSession(id) }
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
                reply.list = try await WindowCatalog.list()
                if reply.list?.isEmpty == true, Session.isScreenLocked {
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
            await open(id, by: who, screen: screen)
        case .close:
            guard let id = m.win else { return }
            await release(id, by: who)
        case .icon:
            guard let id = m.win else { return }
            await sendIcon(id, to: who)
        case .key, .text, .mouse, .scroll, .resize:
            guard let id = m.win, registry.acceptsInput(id, from: who) else { return }
            await warnIfLocked(who)
            input.handle(m)
            if m.t == .resize { sessions[id]?.followSizeSoon() }
        case .restart:
            let refusal = onRestart.map { $0(who, registry.activeViewers.contains(who)) } ?? "This host can't restart itself."
            guard let refusal else { return }
            var reply = Message(.error); reply.msg = refusal
            await send(reply, to: who)
        default:
            break
        }
    }

    private func open(_ id: UInt32, by who: String, screen: CGSize?) async {
        let allowed = (try? await WindowCatalog.shareable(onScreenOnly: false).contains { $0.windowID == id }) ?? false
        guard allowed else {
            var reply = Message(.error); reply.win = id; reply.msg = "That window can't be shared."
            await send(reply, to: who)
            return
        }
        do {
            switch registry.beginOpen(id, by: who) {
            case .alreadyLive:
                break
            case .waitForStart:
                try await starting[id]?.value
            case .start:
                await stage.ensure(screenPoints: screen)
                await stage.park(id)
                let session = WindowSession(windowID: id)
                let task = Task { try await session.start(in: room) }
                starting[id] = task
                do { try await task.value } catch {
                    starting[id] = nil
                    stage.unpark(id)
                    registry.startFailed(id)
                    throw error
                }
                starting[id] = nil
                guard registry.startSucceeded(id) else {
                    await session.stop(in: room)
                    stage.unpark(id)
                    if sessions.isEmpty { stage.becameEmpty() }
                    return
                }
                session.onClosed = { [weak self] in Task { await self?.windowClosed(id) } }
                sessions[id] = session
                onChange?()
                if let pid = session.pid { await audio.add(window: id, pid: pid, in: room) }
            }
            guard registry.shouldReply(id, to: who) else { return }
            var reply = Message(.opened)
            reply.win = id
            reply.track = Message.trackName(for: id)
            await audio.settled()
            if audio.isLive { reply.audio = Message.audioTrackName }
            if let live = LiveWindow.lookup(id) { reply.w = live.bounds.width; reply.h = live.bounds.height }
            await send(reply, to: who)
            await warnIfLocked(who)
        } catch {
            registry.openFailed(id, by: who)
            var reply = Message(.error); reply.win = id; reply.msg = error.localizedDescription
            await send(reply, to: who)
        }
    }

    private func release(_ id: UInt32, by who: String) async {
        guard registry.release(id, by: who) else { return }
        await stopSession(id)
    }

    private func stopSession(_ id: UInt32) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await audio.remove(window: id, in: room)
        await session.stop(in: room)
        stage.unpark(id)
        if sessions.isEmpty { stage.becameEmpty() }
        onChange?()
    }

    private func windowClosed(_ id: UInt32) async {
        guard let who = registry.windowClosed(id), let session = sessions.removeValue(forKey: id) else { return }
        await audio.remove(window: id, in: room)
        await session.stop(in: room)
        stage.unpark(id)
        if sessions.isEmpty { stage.becameEmpty() }
        var m = Message(.closed); m.win = id
        for v in who { await send(m, to: v) }
        onChange?()
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

    private func send(_ m: Message, to who: String) async {
        let opts = DataPublishOptions(destinationIdentities: [Participant.Identity(from: who)], topic: portholeTopic, reliable: true)
        do { try await room.localParticipant.publish(data: m.encoded(), options: opts) } catch {
            Log.info("send to \(who) failed: \(error.localizedDescription)")
        }
    }
}
