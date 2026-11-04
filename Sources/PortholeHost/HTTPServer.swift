import Foundation
import Network
import PortholeCore
import SystemConfiguration

final class HTTPServer {
    private let listener: NWListener
    private let config: HostConfig
    private let routes: WebRoutes
    private let queue = DispatchQueue(label: "porthole.http")

    private(set) var advertised: String?

    init(config: HostConfig, pairing: PairingDesk? = nil, trust: HostTrust? = nil, guests: HostGuests? = nil,
         allowControl: (@Sendable () -> Bool)? = nil, status: (() -> [String: Any])? = nil) throws {
        self.config = config
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.httpPort)!)
        let name = HTTPServer.computerName
        var routes = WebRoutes(password: config.password, livekitPort: config.livekitPort,
                               tokens: AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret),
                               webRoot: HTTPServer.locateWebRoot(), pairing: pairing, hostName: name,
                               trust: trust?.store, hostID: trust?.identity.id)
        routes.onPairRequest = { [weak trust] who, code in trust?.requested(by: who, code: code) }
        routes.onUnpair = { [weak trust] device in trust?.unpaired(device) }
        routes.localSecret = trust?.localSecret
        routes.localStatus = status
        routes.shares = guests?.store
        routes.guestControl = allowControl
        routes.httpPort = config.httpPort
        routes.ownsAddress = { ownAddresses().contains($0) }
        routes.passwordThrottle = PasswordThrottle()
        routes.resolveWindow = { target in pickWindow(target, in: HTTPServer.listWindowsBlocking()) }
        routes.shareAddresses = { (lanAddress(), tailscaleAddress()) }
        routes.onSharesChanged = { [weak guests] in guests?.changedFromCLI() }
        routes.onUnshare = { [weak guests] link in guests?.revokedFromCLI(link) }
        self.routes = routes
        let txt = BonjourTXT.make(name: name, tailscaleIP: tailscaleAddress(), localHost: HTTPServer.localHostName,
                                 port: Int(config.httpPort), id: trust?.identity.id, lanIP: lanAddress())
        listener.service = NWListener.Service(name: name, type: portholeServiceType, domain: nil, txtRecord: NWTXTRecord(txt))
    }

    static func listWindowsBlocking(timeout: TimeInterval = 5) -> [WindowInfo] {
        let done = DispatchSemaphore(value: 0)
        let box = WindowListBox()
        Task.detached {
            box.set((try? await WindowCatalog.list()) ?? [])
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return box.get()
    }

    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? shortHostName(ProcessInfo.processInfo.hostName)
    }

    static var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    static func locateWebRoot() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PORTHOLE_WEB_ROOT"] { candidates.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("web")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    var onFailure: ((String) -> Void)?

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            Log.info("web server state: \(state)", .net)
            if case .failed(let err) = state {
                Log.error("web server failed: \(err)", .net)
                DispatchQueue.main.async { self?.onFailure?("Port \(self?.config.httpPort ?? 0) is busy or blocked") }
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            if case .add(let endpoint) = change {
                let name = "\(endpoint)"
                DispatchQueue.main.async { self?.advertised = name }
                Log.info("advertising \(endpoint) on Bonjour", .net)
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let loopback = Self.isLoopback(conn.endpoint)
            let source = Self.sourceHost(conn.endpoint)
            conn.send(content: self.routes.respond(to: req, fromLoopback: loopback, source: source).serialized, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    func respond(to request: String) -> HTTPResponse {
        routes.respond(to: request)
    }

    static func sourceHost(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "unknown" }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return a.asIPv4.map { "\($0)" } ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return "unknown"
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        default: return false
        }
    }
}

final class WindowListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [WindowInfo] = []
    func set(_ l: [WindowInfo]) { lock.lock(); list = l; lock.unlock() }
    func get() -> [WindowInfo] { lock.lock(); defer { lock.unlock() }; return list }
}
