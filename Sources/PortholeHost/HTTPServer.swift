import Foundation
import Network
import PortholeCore
import SystemConfiguration

final class HTTPServer {
    private let listener: NWListener
    private let config: HostConfig
    private let routes: WebRoutes
    private let queue = DispatchQueue(label: "porthole.http")

    init(config: HostConfig, pairing: PairingDesk? = nil) throws {
        self.config = config
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.httpPort)!)
        let name = HTTPServer.computerName
        routes = WebRoutes(password: config.password, livekitPort: config.livekitPort,
                           tokens: AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret),
                           webRoot: HTTPServer.locateWebRoot(), pairing: pairing, hostName: name)
        let txt = BonjourTXT.make(name: name, tailscaleIP: tailscaleAddress(), localHost: HTTPServer.localHostName,
                                 port: Int(config.httpPort))
        listener.service = NWListener.Service(name: name, type: portholeServiceType, domain: nil, txtRecord: NWTXTRecord(txt))
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
            Log.info("web server state: \(state)")
            if case .failed(let err) = state {
                Log.info("web server failed: \(err)")
                DispatchQueue.main.async { self?.onFailure?("Port \(self?.config.httpPort ?? 0) is busy or blocked") }
            }
        }
        listener.serviceRegistrationUpdateHandler = { change in
            if case .add(let endpoint) = change { Log.info("advertising \(endpoint) on Bonjour") }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            conn.send(content: self.respond(to: req).serialized, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    func respond(to request: String) -> HTTPResponse {
        routes.respond(to: request)
    }
}
