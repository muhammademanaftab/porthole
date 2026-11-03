import Foundation
import Network
import PortholeCore

@MainActor
final class HostDiscovery {
    var onChange: (() -> Void)?
    private(set) var scanning = false
    private(set) var tailscaleRunning = false
    private var browser: NWBrowser?
    private var bonjour: [DiscoveredHost] = []
    private var tailscale: [DiscoveredHost] = []

    var hosts: [DiscoveredHost] {
        mergeHosts(PasswordStore.knownHosts.compactMap(\.asDiscovered) + bonjour + tailscale)
    }

    func start() {
        if browser == nil { startBonjour() }
        refresh()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        bonjour = []
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        onChange?()
        Task {
            let found = await Self.scanTailscale()
            tailscaleRunning = found.running
            tailscale = found.hosts
            scanning = false
            onChange?()
        }
    }

    private func startBonjour() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: portholeServiceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { r -> DiscoveredHost? in
                guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata else { return nil }
                return BonjourTXT.host(serviceName: name, txt: txt.dictionary)
            }
            MainActor.assumeIsolated {
                self?.bonjour = hosts
                self?.onChange?()
            }
        }
        b.start(queue: .main)
        browser = b
    }

    nonisolated static let tailscaleCLIs = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    nonisolated static func scanTailscale() async -> (running: Bool, hosts: [DiscoveredHost]) {
        guard let data = await tailscaleStatusJSON(), let status = TailscaleStatus.parse(data) else { return (false, []) }
        let hosts = await withTaskGroup(of: DiscoveredHost?.self) { group in
            for peer in status.probeTargets {
                guard let ip = peer.ipv4 else { continue }
                group.addTask {
                    switch await probe(host: ip, port: Int(HostConfig.defaultHTTPPort)) {
                    case .porthole(let hello):
                        return DiscoveredHost(name: hello.name, tailscaleIP: ip, status: .online, viaTailscale: true, hostID: hello.id)
                    case .olderPorthole:
                        return DiscoveredHost(name: peerDisplayName(peer), tailscaleIP: ip, status: .older, viaTailscale: true)
                    case .notPorthole:
                        return nil
                    }
                }
            }
            var out: [DiscoveredHost] = []
            for await h in group { if let h { out.append(h) } }
            return out
        }
        return (status.running && status.selfIPv4 != nil, hosts)
    }

    nonisolated static func tailscaleStatusJSON() async -> Data? {
        guard let exe = tailscaleCLIs.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["status", "--json"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: kill)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                kill.cancel()
                cont.resume(returning: data)
            }
        }
    }

    nonisolated static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    nonisolated static func fetch(_ url: URL) async -> (Int?, Data?) {
        guard let (data, resp) = try? await session.data(from: url) else { return (nil, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode, data)
    }

    nonisolated static func probe(host: String, port: Int) async -> ProbeVerdict {
        guard let hello = URL(string: "http://\(host):\(port)/hello"), let page = URL(string: "http://\(host):\(port)/") else {
            return .notPorthole
        }
        let (helloStatus, helloBody) = await fetch(hello)
        var root: (Int?, Data?) = (nil, nil)
        if helloStatus == 404 { root = await fetch(page) }
        return probeVerdict(helloStatus: helloStatus, helloBody: helloBody, rootStatus: root.0, rootBody: root.1)
    }

    nonisolated static func pair(address: String, code: String, device: String, name: String) async -> PairReply {
        guard let url = pairURL(hostAddress: address, code: code, device: device, name: name) else {
            return .refused("\"\(address)\" isn't a host address. Use a name or IP, optionally with :port.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else {
            return .refused("Couldn't reach \(address). Is Porthole Host running there?")
        }
        return parsePairReply(status: http.statusCode, body: data)
    }

    nonisolated static func requestPairing(address: String, device: String, name: String) async -> PairRequestReply {
        guard let url = pairRequestURL(hostAddress: address, device: device, name: name) else {
            return .refused("\"\(address)\" isn't a host address. Use a name or IP, optionally with :port.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else {
            return .refused("Couldn't reach \(address). Is Porthole Host running there?")
        }
        return parsePairRequestReply(status: http.statusCode, body: data)
    }
}
