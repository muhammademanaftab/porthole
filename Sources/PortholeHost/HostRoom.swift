import Foundation
import LiveKit
import PortholeCore

@MainActor
final class HostRoom: NSObject, RoomDelegate {
    let room = Room()
    let input = InputInjector()
    private var sessions: [UInt32: WindowSession] = [:]
    private var starting: [UInt32: Task<Void, Error>] = [:]
    private var viewers: [UInt32: Set<String>] = [:]
    private var url = ""
    private var makeToken: (() -> String)?
    private var reconnecting = false
    var onChange: (() -> Void)?
    private(set) var isConnected = false

    var openWindowCount: Int { sessions.count }

    func connect(url: String, makeToken: @escaping () -> String) async throws {
        self.url = url
        self.makeToken = makeToken
        room.add(delegate: self)
        try await join()
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
        for (id, session) in sessions {
            await session.stop(in: room)
            sessions[id] = nil
        }
        viewers.removeAll()
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
                delay = min(delay * 2, 30)
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
            for id in self.viewers.keys { await self.release(id, by: who) }
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
        if m.t != .mouse && m.t != .key { Log.info("\(m.t.rawValue) from \(who)") }
        switch m.t {
        case .list:
            var reply = Message(.windows)
            do { reply.list = try await WindowCatalog.list() } catch {
                Log.info("listing windows failed: \(error.localizedDescription)")
                reply = Message(.error); reply.msg = "Can't list windows: \(error.localizedDescription). Check Screen Recording permission."
            }
            await send(reply, to: who)
        case .open:
            guard let id = m.win else { return }
            await open(id, by: who)
        case .close:
            guard let id = m.win else { return }
            await release(id, by: who)
        case .key, .text, .mouse, .scroll, .resize:
            guard let id = m.win, sessions[id] != nil, viewers[id]?.contains(who) == true else { return }
            input.handle(m)
            if m.t == .resize { sessions[id]?.followSizeSoon() }
        default:
            break
        }
    }

    private func open(_ id: UInt32, by who: String) async {
        let allowed = (try? await WindowCatalog.shareable(onScreenOnly: false).contains { $0.windowID == id }) ?? false
        guard allowed else {
            var reply = Message(.error); reply.win = id; reply.msg = "That window can't be shared."
            await send(reply, to: who)
            return
        }
        viewers[id, default: []].insert(who)
        do {
            if sessions[id] == nil {
                if let pending = starting[id] {
                    try await pending.value
                } else {
                    let session = WindowSession(windowID: id)
                    let task = Task { try await session.start(in: room) }
                    starting[id] = task
                    defer { starting[id] = nil }
                    try await task.value
                    session.onClosed = { [weak self] in Task { await self?.windowClosed(id) } }
                    sessions[id] = session
                    if viewers[id]?.isEmpty ?? true {
                        sessions[id] = nil
                        await session.stop(in: room)
                        return
                    }
                    onChange?()
                }
            }
            guard viewers[id]?.contains(who) == true else { return }
            var reply = Message(.opened)
            reply.win = id
            reply.track = Message.trackName(for: id)
            if let live = LiveWindow.lookup(id) { reply.w = live.bounds.width; reply.h = live.bounds.height }
            await send(reply, to: who)
        } catch {
            viewers[id]?.remove(who)
            var reply = Message(.error); reply.win = id; reply.msg = error.localizedDescription
            await send(reply, to: who)
        }
    }

    private func release(_ id: UInt32, by who: String) async {
        viewers[id]?.remove(who)
        guard viewers[id]?.isEmpty ?? true, let session = sessions.removeValue(forKey: id) else { return }
        viewers[id] = nil
        await session.stop(in: room)
        onChange?()
    }

    private func windowClosed(_ id: UInt32) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        let who = viewers.removeValue(forKey: id) ?? []
        await session.stop(in: room)
        var m = Message(.closed); m.win = id
        for v in who { await send(m, to: v) }
        onChange?()
    }

    private func send(_ m: Message, to who: String) async {
        let opts = DataPublishOptions(destinationIdentities: [Participant.Identity(from: who)], topic: portholeTopic, reliable: true)
        do { try await room.localParticipant.publish(data: m.encoded(), options: opts) } catch {
            Log.info("send to \(who) failed: \(error.localizedDescription)")
        }
    }
}
