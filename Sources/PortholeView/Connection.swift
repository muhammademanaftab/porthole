import Foundation
import LiveKit
import PortholeCore

@MainActor
final class Connection: NSObject, RoomDelegate {
    let hostAddress: String
    let password: String
    let room = Room()
    var onWindows: (([WindowInfo]) -> Void)?
    var onError: ((String) -> Void)?
    var onClosed: ((UInt32) -> Void)?
    private var pending: [UInt32: (VideoTrack, Message) -> Void] = [:]
    private var openedReplies: [UInt32: Message] = [:]

    init(hostAddress: String, password: String) {
        self.hostAddress = hostAddress
        self.password = password
    }

    var hostParticipant: RemoteParticipant? {
        room.remoteParticipants[Participant.Identity(from: "host")]
    }

    func connect() async throws {
        var comps = URLComponents()
        comps.scheme = "http"
        let parts = hostAddress.split(separator: ":")
        comps.host = String(parts[0])
        comps.port = parts.count > 1 ? Int(parts[1]) : 7878
        comps.path = "/token"
        comps.queryItems = [URLQueryItem(name: "pw", value: password),
                            URLQueryItem(name: "name", value: ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "mac")]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let url = obj["url"], let token = obj["token"] else {
            throw NSError(domain: "Porthole", code: 401, userInfo: [NSLocalizedDescriptionKey: "The host refused the password, or isn't running."])
        }
        room.add(delegate: self)
        try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false),
                               roomOptions: RoomOptions(adaptiveStream: false, dynacast: false))
    }

    private lazy var outbox: AsyncStream<(Data, Bool)>.Continuation = {
        let (stream, cont) = AsyncStream<(Data, Bool)>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let room = self.room
        Task {
            for await (data, reliable) in stream {
                let opts = DataPublishOptions(destinationIdentities: [Participant.Identity(from: "host")],
                                              topic: portholeTopic, reliable: reliable)
                try? await room.localParticipant.publish(data: data, options: opts)
            }
        }
        return cont
    }()

    func send(_ m: Message, reliable: Bool = true) {
        outbox.yield((m.encoded(), reliable))
    }

    func disconnect() async {
        outbox.finish()
        await room.disconnect()
    }

    private var listAnswered = false

    func requestList() {
        listAnswered = false
        Task {
            for _ in 0..<10 where !listAnswered {
                send(Message(.list))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func open(_ id: UInt32, then: @escaping (VideoTrack, Message) -> Void) {
        pending[id] = then
        var m = Message(.open); m.win = id
        Task {
            for _ in 0..<5 where pending[id] != nil && openedReplies[id] == nil {
                send(m)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func close(_ id: UInt32) {
        var m = Message(.close); m.win = id
        send(m)
        if let pub = hostParticipant?.trackPublications.values.first(where: { $0.name == Message.trackName(for: id) }) as? RemoteTrackPublication {
            Task { try? await pub.set(subscribed: false) }
        }
    }


    private func subscribeIfPublished(_ id: UInt32) {
        guard let pub = hostParticipant?.trackPublications.values
            .first(where: { $0.name == Message.trackName(for: id) }) as? RemoteTrackPublication else { return }
        if let track = pub.track as? VideoTrack { deliver(id, track) } else {
            Task { try? await pub.set(subscribed: true) }
        }
    }

    private func deliver(_ id: UInt32, _ track: VideoTrack) {
        guard let reply = openedReplies[id], let cb = pending.removeValue(forKey: id) else { return }
        openedReplies[id] = nil
        cb(track, reply)
    }


    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == portholeTopic, let m = Message.decode(data) else { return }
        Task { @MainActor in
            switch m.t {
            case .windows:
                self.listAnswered = true
                self.onWindows?(m.list ?? [])
            case .opened:
                guard let id = m.win else { return }
                self.openedReplies[id] = m
                self.subscribeIfPublished(id)
            case .closed: if let id = m.win { self.onClosed?(id) }
            case .error:
                if let id = m.win { self.pending[id] = nil }
                self.onError?(m.msg ?? "Unknown error")
            default: break
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        guard let id = Message.windowID(fromTrackName: publication.name) else { return }
        Task { @MainActor in if self.pending[id] != nil { self.subscribeIfPublished(id) } }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard let id = Message.windowID(fromTrackName: publication.name), let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in self.deliver(id, track) }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in self.onError?("Disconnected from host\(error.map { ": \($0.localizedDescription)" } ?? ".")") }
    }
}
