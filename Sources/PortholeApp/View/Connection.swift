import AppKit
import Foundation
import LiveKit
import PortholeCore

@MainActor
final class Connection: NSObject, RoomDelegate {
    let hostAddress: String
    let credential: ViewerCredential
    let hostID: String?
    private(set) var activeAddress: String?
    private(set) var route: RouteInfo?
    var onRoute: ((RouteInfo?) -> Void)?
    private var activeScope: AddressScope?
    private var activeProven = false
    private var sdkReconnecting = false
    private var routeTask: Task<Void, Never>?
    let room = Room()
    var onWindows: (([WindowInfo]) -> Void)?
    var onError: ((String) -> Void)?
    var onClosed: ((UInt32) -> Void)?
    var onClipboard: ((String) -> Void)?
    var onIcon: ((UInt32, Data) -> Void)?
    var onThumb: ((UInt32, Data) -> Void)?
    var onOpenError: ((UInt32, String) -> Void)?
    var isCompanion: (UInt32) -> Bool = { _ in false }
    var onSized: ((Message) -> Void)?
    var onCompanion: ((Message) -> Void)?
    var onLink: ((LinkState) -> Void)?
    var onUnlock: ((Message) -> Void)?
    private(set) var hostLocked = false
    var streamSettings: () -> ViewerSettings = { ViewerSettings() }

    enum LinkState { case connected, reconnecting, disconnected(String) }
    private var pending: [UInt32: (VideoTrack, Message) -> Void] = [:]
    private var openedReplies: [UInt32: Message] = [:]
    private var listening = SharedUse<String, UInt32>()
    var muted = false { didSet { applyVolume() } }
    var onReconnected: (() -> Void)?
    private var closing = false
    private var reconnecting = false
    private var handlersReady = false
    private var attempt = 0
    private var connectedAt: Date?

    init(hostAddress: String, credential: ViewerCredential, hostID: String? = nil) {
        self.hostAddress = hostAddress
        self.credential = credential
        self.hostID = hostID
    }

    var hostParticipant: RemoteParticipant? {
        room.remoteParticipants[Participant.Identity(from: "host")]
    }

    func connect() async throws {
        do {
            try await connectOnce()
            VLog.info("connected to \(hostAddress)\(activeAddress.map { $0 == hostAddress ? "" : " via \($0)" } ?? "")")
        } catch {
            if !(error is CancellationError) { VLog.warn("connect to \(hostAddress) failed: \(error.localizedDescription)") }
            throw error
        }
    }

    private func connectOnce() async throws {
        let mode = RouteFinder.mode()
        let plan = await RouteFinder.plan(saved: hostAddress, hostID: hostID, credential: credential, mode: mode)
        guard !closing else { throw CancellationError() }
        guard !plan.isEmpty else {
            throw NSError(domain: "Porthole", code: 404, userInfo: [NSLocalizedDescriptionKey: RoutePlan.noRouteMessage(mode: mode, hostName: hostAddress)])
        }
        VLog.info("route: \(mode.rawValue) mode, trying \(plan.map(\.address).joined(separator: ", "))")
        var lastError: Error?
        for (i, candidate) in plan.enumerated() {
            guard !closing else { throw CancellationError() }
            let next = i + 1 < plan.count ? plan[i + 1].address : nil
            var confirmed = candidate.trustedWithoutProof
            if candidate.shouldChallenge {
                let answer = await RouteFinder.challenge(candidate.address, credential: credential, expectedID: candidate.expectedID, budget: candidate.budget)
                if HelloProof.namesOtherHost(answer, expectedID: candidate.expectedID) {
                    VLog.info("route: \(candidate.address) is a different host\(next.map { "; trying \($0)" } ?? "")")
                    continue
                }
                switch answer {
                case .confirmed: confirmed = true
                case .unconfirmed(let hello):
                    if candidate.mustProve {
                        VLog.info("route: \(candidate.address) \(hello == nil ? "didn't answer" : "couldn't prove it is this host")\(next.map { "; trying \($0)" } ?? "")")
                        continue
                    }
                    VLog.info("route: saved address \(candidate.address) gave no proof; trying it as before")
                }
            }
            do {
                try await connect(via: candidate, confirmed: confirmed)
                return
            } catch let err as NSError where err.domain == "Porthole" && (err.code == 401 || err.code == 403 || err.code == 400) {
                throw err
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard let next else { throw error }
                VLog.info("route: \(candidate.address) failed (\(error.localizedDescription)); trying \(next)")
            }
        }
        throw lastError ?? NSError(domain: "Porthole", code: 404, userInfo: [NSLocalizedDescriptionKey: RoutePlan.noRouteMessage(mode: mode, hostName: hostAddress)])
    }

    private func connect(via candidate: RouteCandidate, confirmed: Bool) async throws {
        guard let tokenAt = tokenURL(hostAddress: candidate.address, credential: credential,
                                     name: shortHostName(ProcessInfo.processInfo.hostName)) else {
            throw NSError(domain: "Porthole", code: 400, userInfo: [NSLocalizedDescriptionKey:
                "\"\(candidate.address)\" isn't a host address. Use a name or IP, optionally with :port."])
        }
        let (status, data) = try await RouteFinder.fetch(tokenAt, budget: candidate.budget)
        let url: String, token: String
        switch parseTokenReply(status: status, body: data) {
        case .ok(let u, let t): url = u; token = t
        case .unpaired(let why) where RoutePlan.stops(status: status, confirmed: confirmed || candidate.saved):
            throw NSError(domain: "Porthole", code: 403, userInfo: [NSLocalizedDescriptionKey: why])
        case .refused(let why) where RoutePlan.stops(status: status, confirmed: confirmed || candidate.saved):
            throw NSError(domain: "Porthole", code: 401, userInfo: [NSLocalizedDescriptionKey: why])
        case .unpaired(let why), .refused(let why):
            throw NSError(domain: "Porthole", code: 502, userInfo: [NSLocalizedDescriptionKey:
                status == 429 ? why : "\(candidate.address) answered HTTP \(status) and couldn't be confirmed as this host."])
        }
        try await setUpOnce()
        guard !closing else { throw CancellationError() }
        try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: false),
                               roomOptions: RoomOptions(adaptiveStream: false, dynacast: false))
        if closing { await room.disconnect(); throw CancellationError() }
        connectedAt = Date()
        sdkReconnecting = false
        activeAddress = candidate.address
        activeScope = candidate.scope
        activeProven = confirmed && candidate.shouldChallenge
        VLog.info("route: signaling via \(candidate.address) (\(signalingRoute(address: candidate.address)?.kind.label ?? "unknown"))\(confirmed ? "" : ", unconfirmed")")
        setRoute(signalingRoute(address: candidate.address), media: false)
        watchRoute()
    }

    private var mediaRouteKnown = false

    private func setRoute(_ info: RouteInfo?, media: Bool) {
        if !media && mediaRouteKnown { return }
        if media { mediaRouteKnown = true }
        guard info != route else { return }
        route = info
        if media, let info { VLog.info("route: \(info.text), signaling via \(activeAddress ?? hostAddress)") }
        onRoute?(info)
    }

    private func watchRoute() {
        guard routeTask == nil else { return }
        routeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.checkRoute() else { return }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    private func checkRoute() async -> UInt64? {
        guard !closing else { return nil }
        await refreshMediaRoute()
        return mediaRouteKnown ? 15 : 2
    }

    private func refreshMediaRoute() async {
        guard !sdkReconnecting, !reconnecting else { return }
        let tracks = hostParticipant?.trackPublications.values.compactMap { ($0 as? RemoteTrackPublication)?.track as? RemoteVideoTrack } ?? []
        guard let track = tracks.first, let info = await RouteFinder.mediaRoute(of: track) else { return }
        setRoute(info, media: true)
    }

    private func forgetRoute() {
        mediaRouteKnown = false
        activeAddress = nil
        activeScope = nil
        activeProven = false
        setRoute(nil, media: false)
    }

    private func setUpOnce() async throws {
        guard !handlersReady else { return }
        room.add(delegate: self)
        try await room.registerTextStreamHandler(for: clipboardTopic) { [weak self] reader, identity in
            guard identity.stringValue == "host" else { return }
            let text = try await reader.readAll()
            Task { @MainActor [weak self] in self?.onClipboard?(text) }
        }
        try await room.registerByteStreamHandler(for: iconTopic) { [weak self] reader, identity in
            guard identity.stringValue == "host", let win = AppIcon.window(from: reader.info.attributes) else { return }
            let png = try await reader.readAll()
            guard AppIcon.isAcceptable(png) else { return }
            Task { @MainActor [weak self] in self?.onIcon?(win, png) }
        }
        try await room.registerByteStreamHandler(for: thumbTopic) { [weak self] reader, identity in
            guard identity.stringValue == "host", let win = AppIcon.window(from: reader.info.attributes) else { return }
            let jpeg = try await reader.readAll()
            guard WindowThumbnail.isAcceptable(jpeg) else { return }
            Task { @MainActor [weak self] in self?.onThumb?(win, jpeg) }
        }
        handlersReady = true
    }

    nonisolated private static func kind(of error: LiveKitError?) -> DisconnectKind {
        guard let error else { return .byViewer }
        switch error.type {
        case .cancelled: return .byViewer
        case .participantRemoved: return .removed
        case .duplicateIdentity: return .replaced
        case .roomDeleted: return .roomGone
        default: return .lost
        }
    }

    private func reconnect(dropFirst: Bool = false) async {
        guard !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        if dropFirst { await room.disconnect() }
        forgetRoute()
        onLink?(.reconnecting)
        VLog.info("lost the connection to \(hostAddress); reconnecting")
        onError?("Lost the connection to the host. Reconnecting…")
        attempt = nextReconnectAttempt(previous: attempt, upFor: connectedAt.map { Date().timeIntervalSince($0) })
        connectedAt = nil
        while !closing, let delay = reconnectDelay(after: .lost, attempt: attempt) {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !closing else { return }
            do {
                try await connect()
                if closing { await room.disconnect(); return }
                let queued = pending
                pending = [:]
                openedReplies = [:]
                listening = SharedUse()
                VLog.info("reconnected to \(hostAddress)")
                onReconnected?()
                for (id, then) in queued where pending[id] == nil { open(id, then: then) }
                return
            } catch let err as NSError where err.domain == "Porthole" && (err.code == 401 || err.code == 403) {
                onLink?(.disconnected(err.localizedDescription))
                onError?(err.localizedDescription)
                return
            } catch {
                if closing { return }
                attempt = nextReconnectAttempt(previous: attempt, upFor: nil)
            }
        }
        guard !closing else { return }
        let text = "Disconnected from host. Reconnect from the Porthole menu."
        VLog.warn("gave up reconnecting to \(hostAddress)")
        onLink?(.disconnected(text))
        onError?(text)
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

    func unlock(password: String) {
        var m = Message(.unlock)
        m.s = password
        VLog.info("unlock: asking \(hostAddress) to type the password into its lock screen")
        send(m)
    }

    func sendClipboard(_ text: String) {
        let opts = StreamTextOptions(topic: clipboardTopic, destinationIdentities: [Participant.Identity(from: "host")])
        Task { _ = try? await room.localParticipant.sendText(text, options: opts) }
    }

    func disconnect() async {
        closing = true
        routeTask?.cancel()
        outbox.finish()
        await room.disconnect()
    }

    private var listAnswered = false

    func requestList() {
        listAnswered = false
        Task {
            for _ in 0..<RetryPolicy.list.times where !listAnswered {
                send(Message(.list))
                try? await Task.sleep(nanoseconds: UInt64(RetryPolicy.list.every * 1_000_000_000))
            }
        }
    }

    func open(_ id: UInt32, then: @escaping (VideoTrack, Message) -> Void) {
        VLog.info("open window \(id) on \(hostAddress)")
        pending[id] = then
        var m = Message(.open); m.win = id
        if let screen = NSScreen.main?.frame.size { m.sw = screen.width; m.sh = screen.height; m.ss = NSScreen.main.map { Double($0.backingScaleFactor) } }
        streamSettings().apply(to: &m)
        Task {
            for _ in 0..<RetryPolicy.open.times where pending[id] != nil && openedReplies[id] == nil {
                send(m)
                try? await Task.sleep(nanoseconds: UInt64(RetryPolicy.open.every * 1_000_000_000))
            }
        }
    }

    func requestThumbnails() {
        send(Message(.thumb))
    }

    func requestIcon(_ id: UInt32) {
        var m = Message(.icon); m.win = id
        send(m)
    }

    func close(_ id: UInt32) {
        VLog.info("close window \(id) on \(hostAddress)")
        var m = Message(.close); m.win = id
        send(m)
        if let pub = publication(named: Message.trackName(for: id)) {
            Task { try? await pub.set(subscribed: false) }
        }
        if let audio = listening.owners[id], listening.remove(id), let pub = publication(named: audio) {
            Task { try? await pub.set(subscribed: false) }
        }
    }

    private func publication(named name: String) -> RemoteTrackPublication? {
        hostParticipant?.trackPublications.values.first(where: { $0.name == name }) as? RemoteTrackPublication
    }

    private func listen(_ id: UInt32, to audio: String) {
        guard listening.add(id, to: audio) else { return }
        subscribeAudioIfPublished(audio)
    }

    private func subscribeAudioIfPublished(_ name: String) {
        guard listening.keys.contains(name), let pub = publication(named: name) else { return }
        if pub.track is RemoteAudioTrack { applyVolume() } else { Task { try? await pub.set(subscribed: true) } }
    }

    private func applyVolume() {
        for name in listening.keys {
            (publication(named: name)?.track as? RemoteAudioTrack)?.volume = muted ? 0 : 1
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
        if let audio = reply.audio { listen(id, to: audio) }
        cb(track, reply)
    }


    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
                          forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == portholeTopic, participant?.identity?.stringValue == "host", let m = Message.decode(data) else { return }
        Task { @MainActor in
            switch m.t {
            case .windows:
                self.listAnswered = true
                if !(m.list ?? []).isEmpty { self.hostLocked = false }
                self.onWindows?(m.list ?? [])
            case .opened:
                guard let id = m.win else { return }
                self.openedReplies[id] = m
                self.subscribeIfPublished(id)
            case .closed: if let id = m.win { self.onClosed?(id) }
            case .sized: self.onSized?(m)
            case .companion: self.onCompanion?(m)
            case .unlock:
                VLog.info("unlock: \(m.on == true ? "unlocked" : "not unlocked"): \(m.msg ?? "")")
                if m.on == true { self.hostLocked = false }
                self.onUnlock?(m)
            case .error:
                if UnlockPrompt.isLockNotice(m.msg) { self.hostLocked = true }
                if let id = m.win, self.isCompanion(id) {
                    self.pending[id] = nil
                    self.onOpenError?(id, m.msg ?? "Unknown error")
                    return
                }
                if let id = m.win, self.pending.removeValue(forKey: id) != nil {
                    VLog.warn("host refused window \(id): \(m.msg ?? "unknown error")")
                    self.onOpenError?(id, m.msg ?? "Unknown error")
                }
                self.onError?(m.msg ?? "Unknown error")
            default: break
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        if Message.isAudioTrackName(publication.name) {
            let name = publication.name
            Task { @MainActor in self.subscribeAudioIfPublished(name) }
            return
        }
        guard let id = Message.windowID(fromTrackName: publication.name) else { return }
        Task { @MainActor in if self.pending[id] != nil { self.subscribeIfPublished(id) } }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if Message.isAudioTrackName(publication.name) {
            Task { @MainActor in self.applyVolume() }
            return
        }
        guard let id = Message.windowID(fromTrackName: publication.name), let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in self.deliver(id, track) }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let kind = Self.kind(of: error)
        let text = "Disconnected from host\(error.map { ": \($0.localizedDescription)" } ?? ".")"
        Task { @MainActor in
            guard !self.closing, !self.reconnecting else { return }
            VLog.info("disconnected from \(self.hostAddress): \(kind)")
            if reconnectDelay(after: kind, attempt: 1) != nil { await self.reconnect(); return }
            self.onLink?(.disconnected(text))
            self.onError?(text)
        }
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor in
            guard !self.closing else { return }
            self.sdkReconnecting = true
            self.onLink?(.reconnecting)
            self.checkLocalRouteStillThere()
        }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor in
            self.sdkReconnecting = false
            if !self.closing { self.onLink?(.connected) }
        }
    }

    private func checkLocalRouteStillThere() {
        guard let address = activeAddress, activeScope == .local, activeProven else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.sdkReconnecting, !self.closing, !self.reconnecting, self.activeAddress == address else { return }
            if case .confirmed = await RouteFinder.challenge(address, credential: self.credential, expectedID: self.hostID.flatMap { DeviceIdentity.isValidID($0) ? $0 : nil },
                                                             budget: RoutePlan.localBudget) { return }
            guard self.sdkReconnecting, !self.closing, !self.reconnecting, self.activeAddress == address else { return }
            VLog.info("route: \(address) stopped answering while reconnecting; picking a route again")
            self.sdkReconnecting = false
            await self.reconnect(dropFirst: true)
        }
    }
}
