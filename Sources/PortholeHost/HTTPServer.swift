import Foundation
import Network
import PortholeCore

final class HTTPServer {
    private let listener: NWListener
    private let config: HostConfig
    private let tokens: AccessToken
    private let webRoot: URL?
    private let queue = DispatchQueue(label: "porthole.http")

    init(config: HostConfig) throws {
        self.config = config
        tokens = AccessToken(apiKey: config.apiKey, apiSecret: config.apiSecret)
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.httpPort)!)
        webRoot = HTTPServer.locateWebRoot()
    }

    static func locateWebRoot() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PORTHOLE_WEB_ROOT"] { candidates.append(URL(fileURLWithPath: env)) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("web")) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    func start() {
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
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: String(parts[1])) else {
            return ("400 Bad Request", "text/plain", Data("bad request".utf8))
        }
        let query = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let hostHeader = lines.first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? "127.0.0.1"

        switch comps.path {
        case "/", "/index.html":
            guard let root = webRoot, let html = try? Data(contentsOf: root.appendingPathComponent("index.html")) else {
                return ("500 Internal Server Error", "text/plain", Data("web viewer missing".utf8))
            }
            return ("200 OK", "text/html; charset=utf-8", html)
        case "/token":
            guard query["pw"] == config.password else {
                return ("401 Unauthorized", "application/json", Data(#"{"error":"wrong password"}"#.utf8))
            }
            let name = (query["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "viewer")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let identity = "view-\(name.prefix(24))-\(randomSecret(bytes: 3))"
            let token = tokens.make(identity: identity, room: "porthole", canPublish: false)
            let body: [String: String] = ["url": "ws://\(Self.hostname(from: hostHeader)):\(config.livekitPort)", "token": token]
            return ("200 OK", "application/json", (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        default:
            return ("404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    static func hostname(from header: String) -> String {
        if header.hasPrefix("["), let end = header.firstIndex(of: "]") { return String(header[...end]) }
        return header.split(separator: ":").first.map(String.init) ?? header
    }
}
