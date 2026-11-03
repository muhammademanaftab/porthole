import Foundation
import LiveKit
import PortholeCore

/// The host's seat in the LiveKit room: answers viewers' control messages and
/// publishes one video track per window that at least one viewer has open.
@MainActor
final class HostRoom: NSObject, RoomDelegate {
    let room = Room()
    let input = InputInjector()
    private var sessions: [UInt32: WindowSession] = [:]
    private var starting: [UInt32: Task<Void, Error>] = [:]
    private var viewers: [UInt32: Set<String>] = [:]
    var onChange: (() -> Void)?

    var openWindowCount: Int { sessions.count }

    func connect(url: String, token: String) async throws {
        room.add(delegate: self)
        let opts = RoomOptions(adaptiveStream: false, dynacast: false, suspendLocalVideoTracksInBackground: false)
        try await room.connect(url: url, token: token, roomOptions: opts)
    }

    // MARK: RoomDelegate

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == portholeTopic, let m = Message.decode(data),
              let who = participant?.identity?.stringValue else { return }
        Task { @MainActor in await self.handle(m, from: who) }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard let who = participant.identity?.stringValue else { return }
        Task { @MainActor in
            for id in self.viewers.keys { await self.release(id, by: who) }
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        NSLog("Porthole: host left the room: \(error?.localizedDescription ?? "no error")")
    }

    // MARK: Messages

    private func handle(_ m: Message, from who: String) async {
        switch m.t {
        case .list:
            var reply = Message(.windows)
            do { reply.list = try await WindowCatalog.list() } catch {
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
            input.handle(m)
        default:
            break
        }
    }

    private func open(_ id: UInt32, by who: String) async {
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
                    onChange?()
                }
            }
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
            NSLog("Porthole: send to \(who) failed: \(error.localizedDescription)")
        }
    }
}
