import Foundation
import LiveKit
import Network
import PortholeCore

@MainActor
final class LocalSightings {
    static let shared = LocalSightings()
    private var browser: NWBrowser?
    private var hosts: [DiscoveredHost] = []
    private var startedAt = Date()

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: portholeServiceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata else { return nil }
                return BonjourTXT.host(serviceName: name, txt: txt.dictionary)
            }
            MainActor.assumeIsolated { self?.hosts = found }
        }
        b.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                self?.browser?.cancel()
                self?.browser = nil
            }
        }
        startedAt = Date()
        b.start(queue: .main)
        browser = b
    }

    func current(wait: TimeInterval, until found: ([DiscoveredHost]) -> Bool) async -> [DiscoveredHost] {
        start()
        let deadline = startedAt.addingTimeInterval(wait)
        while !found(hosts) && Date() < deadline && browser != nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        return hosts
    }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
enum RouteFinder {
    static let bonjourWait: TimeInterval = 0.8

    static func mode() -> RouteMode {
        RouteMode.effective(setting: ViewerSettings(lookup: { UserDefaults.standard.object(forKey: $0) }).route)
    }

    static func startBrowsingUnlessTailscaleOnly() {
        if mode() != .tailscale { LocalSightings.shared.start() }
    }

    static func plan(saved: String, hostID: String?, credential: ViewerCredential, mode: RouteMode) async -> [RouteCandidate] {
        guard case .device = credential else {
            return RoutePlan.candidates(mode: mode, saved: saved, hostID: hostID, local: [], known: [], savedOnly: true)
        }
        var hosts: [DiscoveredHost] = []
        if mode != .tailscale {
            hosts = await LocalSightings.shared.current(wait: bonjourWait) { !RoutePlan.matching(hostID, in: $0).isEmpty }
        }
        var resolved: [String: String] = [:]
        for name in RoutePlan.namesToResolve(of: hostID, in: hosts) {
            if let ip = await resolveLocal(name, budget: 1) { resolved[name] = ip }
        }
        let local = RoutePlan.sightings(of: hostID, in: hosts, resolved: resolved)
        let known = PasswordStore.trust.addresses(of: hostID)
        return RoutePlan.candidates(mode: mode, saved: saved, hostID: hostID, local: local, known: known)
    }

    nonisolated static func resolveLocal(_ name: String, budget: TimeInterval) async -> String? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let once = Once()
        return await withCheckedContinuation { cont in
            DispatchQueue.global().asyncAfter(deadline: .now() + budget) { if once.claim() { cont.resume(returning: nil) } }
            DispatchQueue.global().async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                var found: [String] = []
                if getaddrinfo(name, nil, &hints, &res) == 0 {
                    var p = res
                    while let cur = p {
                        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                            found.append(String(cString: buf))
                        }
                        p = cur.pointee.ai_next
                    }
                    freeaddrinfo(res)
                }
                let usable = found.map(bareHost).filter { isIPLiteral($0) && addressScope($0) == .local }
                let pick = usable.first(where: { parseDottedQuad($0) != nil }) ?? usable.first
                if once.claim() { cont.resume(returning: pick) }
            }
        }
    }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.waitsForConnectivity = false
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    nonisolated static func fetch(_ url: URL, budget: TimeInterval) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.timeoutInterval = budget
        let task = Task { try await session.data(for: req) }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            task.cancel()
        }
        defer { timer.cancel() }
        let (data, resp) = try await task.value
        guard let http = resp as? HTTPURLResponse, let got = http.url, got.host == url.host, got.port == url.port, got.path == url.path else {
            throw NSError(domain: "Porthole", code: 502, userInfo: [NSLocalizedDescriptionKey: "\(url.host ?? "The host") answered from somewhere else."])
        }
        return (http.statusCode, data)
    }

    nonisolated static func challenge(_ address: String, credential: ViewerCredential, expectedID: String?, budget: TimeInterval) async -> HelloProof.Answer {
        let nonce = HelloProof.makeNonce()
        guard let (host, _) = splitHostAddress(address), let url = HelloProof.url(hostAddress: address, credential: credential, nonce: nonce),
              let (status, body) = try? await fetch(url, budget: budget) else { return .unconfirmed(nil) }
        return HelloProof.check(status: status, body: body, credential: credential, nonce: nonce, expectedID: expectedID, address: host)
    }

    static func facts(_ c: IceCandidateStatistics?) -> IceCandidateFacts? {
        c.map { IceCandidateFacts(id: $0.id, address: $0.address, type: $0.candidateType?.rawValue) }
    }

    static func mediaRoute(of track: RemoteVideoTrack) async -> RouteInfo? {
        await track.set(reportStatistics: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let stats = track.statistics
        await track.set(reportStatistics: false)
        guard let stats, let remote = facts(stats.remoteIceCandidate), let address = remote.address else { return nil }
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
