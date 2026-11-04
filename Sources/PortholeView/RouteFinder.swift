import Foundation
import LiveKit
import Network
import PortholeCore

@MainActor
final class LocalSightings {
    static let shared = LocalSightings()
    private var browser: NWBrowser?
    private var hosts: [DiscoveredHost] = []
    private var answered = false
    private var startedAt = Date()

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: portholeServiceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata else { return nil }
                return BonjourTXT.host(serviceName: name, txt: txt.dictionary)
            }
            MainActor.assumeIsolated {
                self?.hosts = found
                self?.answered = true
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                self?.browser?.cancel()
                self?.browser = nil
                self?.answered = true
            }
        }
        startedAt = Date()
        answered = false
        b.start(queue: .main)
        browser = b
    }

    func current(wait: TimeInterval) async -> [DiscoveredHost] {
        start()
        let deadline = startedAt.addingTimeInterval(wait)
        while !answered && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return hosts
    }
}

@MainActor
enum RouteFinder {
    static let bonjourWait: TimeInterval = 0.8

    static func mode() -> RouteMode {
        RouteMode.effective(setting: ViewerSettings(lookup: { UserDefaults.standard.object(forKey: $0) }).route)
    }

    static func plan(saved: String, hostID: String?, mode: RouteMode) async -> [RouteCandidate] {
        let hosts = await LocalSightings.shared.current(wait: mode == .tailscale ? 0 : bonjourWait)
        let local = RoutePlan.sightings(of: hostID, saved: saved, in: hosts)
        let known = PasswordStore.trust.addresses(of: hostID)
        return RoutePlan.candidates(mode: mode, saved: saved, hostID: hostID, local: local, known: known)
    }

    nonisolated static func hello(_ address: String, budget: TimeInterval) async -> HostHello? {
        guard let url = helloURL(hostAddress: address) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = budget
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return HostHello.parse(data)
    }

    static func learn(hostID: String?, address: String) {
        guard let hostID, DeviceIdentity.isValidID(hostID), PasswordStore.trust.host(forAddress: address)?.id != hostID else { return }
        var t = PasswordStore.trust
        guard t.hosts.contains(where: { $0.id == hostID }) else { return }
        t.learn(id: hostID, address: address)
        PasswordStore.trust = t
        VLog.info("route: remembered \(address) as another address of paired host \(hostID)")
    }

    static func facts(_ c: IceCandidateStatistics?) -> IceCandidateFacts? {
        c.map { IceCandidateFacts(id: $0.id, address: $0.address, type: $0.candidateType?.rawValue) }
    }

    static func mediaRoute(_ stats: TrackStatistics) async -> RouteInfo? {
        guard let remote = facts(stats.remoteIceCandidate), let address = remote.address else { return nil }
        var status: TailscaleStatus?
        if addressScope(address) == .tailscale { status = await tailscaleStatus() }
        return routeInfo(remote: remote, local: facts(stats.localIceCandidate), tailscale: status)
    }

    private static var statusCache: (at: Date, status: TailscaleStatus?)?

    static func tailscaleStatus() async -> TailscaleStatus? {
        if let c = statusCache, Date().timeIntervalSince(c.at) < 15 { return c.status }
        let status = await HostDiscovery.tailscaleStatusJSON().flatMap(TailscaleStatus.parse)
        statusCache = (Date(), status)
        return status
    }
}
