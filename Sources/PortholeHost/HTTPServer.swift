import Foundation
import Network
import PortholeCore

final class HTTPServer {
    private let listener: NWListener
    private let config: HostConfig
    private let routes: WebRoutes
    private let queue = DispatchQueue(label: "porthole.http")

    init(config: HostConfig) throws {
        self.config = config
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.httpPort)!)
        routes = WebRoutes(password: config.password, livekitPort: config.livekitPort,
                           tokens: AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret),
                           webRoot: HTTPServer.locateWebRoot())
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
            if case .failed(let err) = state {
                Log.info("web server failed: \(err)")
                DispatchQueue.main.async { self?.onFailure?("Port \(self?.config.httpPort ?? 0) is busy or blocked") }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let (status, type, body) = self.respond(to: req)
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    func respond(to request: String) -> (String, String, Data) {
        routes.respond(to: request)
    }
}
