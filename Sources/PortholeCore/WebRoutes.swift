import Foundation

public struct WebRoutes {
    public var password: String
    public var livekitPort: Int
    public var tokens: AccessToken
    public var webRoot: URL?
    public var suffix: () -> String

    public init(password: String, livekitPort: Int, tokens: AccessToken, webRoot: URL?,
                suffix: @escaping () -> String = { randomSecret(bytes: 3) }) {
        self.password = password; self.livekitPort = livekitPort; self.tokens = tokens
        self.webRoot = webRoot; self.suffix = suffix
    }

    public func respond(to request: String) -> (String, String, Data) {
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
            guard query["pw"] == password else {
                return ("401 Unauthorized", "application/json", Data(#"{"error":"wrong password"}"#.utf8))
            }
            let identity = Self.viewerIdentity(name: query["name"], suffix: suffix())
            let token = tokens.make(identity: identity, room: "porthole", canPublish: false)
            let body: [String: String] = ["url": "ws://\(Self.hostname(from: hostHeader)):\(livekitPort)", "token": token]
            return ("200 OK", "application/json", (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        default:
            let name = String(comps.path.dropFirst())
            guard let root = webRoot, !name.isEmpty, !name.contains(".."), !name.contains("/"),
                  let body = try? Data(contentsOf: root.appendingPathComponent(name)) else {
                return ("404 Not Found", "text/plain", Data("not found".utf8))
            }
            return ("200 OK", Self.contentType(for: name), body)
        }
    }

    public static func viewerIdentity(name: String?, suffix: String) -> String {
        let clean = (name.flatMap { $0.isEmpty ? nil : $0 } ?? "viewer")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "view-\(clean.prefix(24))-\(suffix)"
    }

    public static func contentType(for name: String) -> String {
        name.hasSuffix(".js") ? "text/javascript" : name.hasSuffix(".css") ? "text/css" : name.hasSuffix(".png") ? "image/png" : "application/octet-stream"
    }

    public static func hostname(from header: String) -> String {
        if header.hasPrefix("["), let end = header.firstIndex(of: "]") { return String(header[...end]) }
        return header.split(separator: ":").first.map(String.init) ?? header
    }
}
