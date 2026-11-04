import AppKit
import LiveKit
import PortholeCore

@MainActor
final class HostTrust: NSObject, RoomDelegate {
    let desk: PairingDesk
    let store = TrustStore(directory: HostConfig.directory)
    let identity = DeviceIdentity.loadOrCreate(in: HostConfig.directory)
    let localSecret = LocalSecret.create(in: HostConfig.directory)
    private var revoked = RevokedDevices()
    private let config: HostConfig
    private weak var host: HostRoom?
    private var pairingWindow: PairingWindow?
    private var pairedWindow: PairedMacsWindow?

    init(desk: PairingDesk, config: HostConfig) {
        self.desk = desk
        self.config = config
    }

    func attach(to host: HostRoom) {
        self.host = host
        host.room.add(delegate: self)
        host.accepts = { [weak self] who in self?.accepts(who) ?? false }
    }

    private var window: PairingWindow {
        let w = pairingWindow ?? PairingWindow(desk: desk)
        pairingWindow = w
        return w
    }

    func presentNewCode() { window.present() }

    nonisolated func requested(by who: PairRequester, code: String) {
        print("Pairing request from \(who.name) (\(who.id)): code \(displayPairingCode(code))")
        fflush(stdout)
        Log.info("pairing request from \(who.name) (\(who.id))")
        guard showsPairingWindow() else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Power.wakeDisplay()
                self.window.presentRequest()
            }
        }
    }

    nonisolated func unpaired(_ device: PairedDevice) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.revoke(device) } }
    }

    func showPaired() {
        let w = pairedWindow ?? PairedMacsWindow(trust: self)
        pairedWindow = w
        w.present()
    }

    func unpair(_ device: PairedDevice) {
        guard case .found(let gone) = store.unpair(device.id) else { pairedWindow?.reload(); return }
        revoke(gone)
    }

    func accepts(_ identity: String) -> Bool {
        revoked.accepts(identity, isPaired: store.isPaired)
    }

    private func revoke(_ device: PairedDevice) {
        revoked.revoke(device.id)
        Log.info("unpaired \(device.name) (\(device.id))")
        pairedWindow?.reload()
        guard let host else { return }
        let ids = identities(host.room.remoteParticipants.keys.map(\.stringValue), of: device.id)
        for who in ids { Task { await remove(who) } }
    }

    private func remove(_ identity: String) async {
        let keys = AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret)
        var attempt = 0
        while true {
            let token = keys.make(identity: "host-admin", room: "porthole", canPublish: false, ttl: 60, roomAdmin: true)
            guard let req = removeParticipantRequest(livekitPort: config.livekitPort, token: token, room: "porthole", identity: identity) else { return }
            let status = (try? await URLSession.shared.data(for: req)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            attempt += 1
            guard let delay = removeRetryDelay(status: status, attempt: attempt) else {
                Log.info("disconnected \(identity) after unpairing (status \(status.map(String.init) ?? "none"), \(attempt) \(attempt == 1 ? "try" : "tries"))")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard let who = participant.identity?.stringValue, let device = deviceID(fromIdentity: who) else { return }
        Task { @MainActor in
            guard !self.store.isPaired(device) else { return }
            self.revoked.revoke(device)
            Log.info("\(who) belongs to an unpaired Mac; disconnecting it")
            await self.remove(who)
        }
    }
}
