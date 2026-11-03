import Foundation

public struct HTTPResponse {
    public var status: String
    public var contentType: String
    public var body: Data
    public var headers: [(String, String)]
    public var sendsBody: Bool

    public init(_ status: String, _ contentType: String, _ body: Data, headers: [(String, String)] = [], sendsBody: Bool = true) {
        self.status = status; self.contentType = contentType; self.body = body
        self.headers = headers; self.sendsBody = sendsBody
    }

    public init(_ status: String, _ contentType: String, _ text: String, headers: [(String, String)] = []) {
        self.init(status, contentType, Data(text.utf8), headers: headers)
    }

    public var head: String {
        var h = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { h += "\(name): \(value)\r\n" }
        return h + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
    }

    public var serialized: Data {
        Data(head.utf8) + (sendsBody ? body : Data())
    }
}

public struct WebRoutes {
    public var password: String
    public var livekitPort: Int
    public var tokens: AccessToken
    public var webRoot: URL?
    public var suffix: () -> String
    public var pairing: PairingDesk?
    public var hostName: String

    public static let servedExtensions = [".js", ".css", ".png", ".webmanifest"]

    public init(password: String, livekitPort: Int, tokens: AccessToken, webRoot: URL?,
                suffix: @escaping () -> String = { randomSecret(bytes: 3) }, pairing: PairingDesk? = nil, hostName: String = "Mac") {
        self.password = password; self.livekitPort = livekitPort; self.tokens = tokens
        self.webRoot = webRoot; self.suffix = suffix
        self.pairing = pairing; self.hostName = hostName
    }

    public func respond(to request: String) -> HTTPResponse {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return HTTPResponse("400 Bad Request", "text/plain", "bad request") }
        guard parts[0] == "GET" || parts[0] == "HEAD" else {
            return HTTPResponse("405 Method Not Allowed", "text/plain", "method not allowed", headers: [("Allow", "GET, HEAD")])
        }
        let target = String(parts[1])
        let hostLine = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
        guard Self.hasValidEscapes(target), let comps = URLComponents(string: target),
              hostLine != nil || parts.count < 3 || parts[2] != "HTTP/1.1" else {
            return HTTPResponse("400 Bad Request", "text/plain", "bad request")
        }
        if parts[0] == "HEAD" && comps.path == "/pair" {
            return HTTPResponse("405 Method Not Allowed", "text/plain", "method not allowed", headers: [("Allow", "GET")])
        }
        var response = route(comps, hostHeader: hostLine.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? "")
        if parts[0] == "HEAD" { response.sendsBody = false }
        return response
    }

    private func route(_ comps: URLComponents, hostHeader: String) -> HTTPResponse {
        let query = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch comps.path {
        case "/", "/index.html":
            guard let root = webRoot, let html = try? Data(contentsOf: root.appendingPathComponent("index.html")) else {
                return HTTPResponse("500 Internal Server Error", "text/plain", "web viewer missing")
            }
            return HTTPResponse("200 OK", "text/html; charset=utf-8", html)
        case "/token":
            guard query["pw"] == password else {
                return HTTPResponse("403 Forbidden", "application/json", #"{"error":"wrong password"}"#)
            }
            let identity = Self.viewerIdentity(name: query["name"], suffix: suffix())
            let token = tokens.make(identity: identity, room: "porthole", canPublish: false)
            let body: [String: String] = ["url": "ws://\(Self.hostname(from: hostHeader)):\(livekitPort)", "token": token]
            return HTTPResponse("200 OK", "application/json", (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        case "/hello":
            return HTTPResponse("200 OK", "application/json", HostHello(name: hostName, version: portholeProtocolVersion).json)
        case "/pair":
            return pair(query["code"] ?? "")
        case "/favicon.ico":
            return HTTPResponse("204 No Content", "image/x-icon", Data())
        default:
            let name = String(comps.path.dropFirst())
            guard let root = webRoot, Self.isServable(name),
                  let body = try? Data(contentsOf: root.appendingPathComponent(name)) else {
                return HTTPResponse("404 Not Found", "text/plain", "not found")
            }
            return HTTPResponse("200 OK", Self.contentType(for: name), body)
        }
    }

    private func pair(_ code: String) -> HTTPResponse {
        guard let pairing else { return HTTPResponse("404 Not Found", "text/plain", "not found") }
        let outcome = pairing.redeem(code)
        if outcome == .accepted {
            let body = (try? JSONSerialization.data(withJSONObject: ["password": password])) ?? Data()
            return HTTPResponse("200 OK", "application/json", body)
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["error": pairMessage(outcome) ?? ""])) ?? Data()
        return HTTPResponse("403 Forbidden", "application/json", body)
    }

    public static func isServable(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("..") && !name.contains("/") && !name.contains("\\")
            && servedExtensions.contains { name.hasSuffix($0) && name.count > $0.count }
    }

    public static func hasValidEscapes(_ s: String) -> Bool {
        let u = Array(s.utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "%") {
                guard i + 2 < u.count, isHex(u[i + 1]), isHex(u[i + 2]) else { return false }
                i += 3
            } else { i += 1 }
        }
        return true
    }

    private static func isHex(_ c: UInt8) -> Bool {
        (48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c)
    }

    public static func viewerIdentity(name: String?, suffix: String) -> String {
        let clean = (name ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "view-\(clean.isEmpty ? "viewer" : String(clean.prefix(24)))-\(suffix)"
    }

    public static func contentType(for name: String) -> String {
        if name.hasSuffix(".js") { return "text/javascript" }
        if name.hasSuffix(".css") { return "text/css" }
        if name.hasSuffix(".png") { return "image/png" }
        if name.hasSuffix(".webmanifest") { return "application/manifest+json" }
        return "application/octet-stream"
    }

    public static func hostname(from header: String) -> String {
        if header.hasPrefix("[") {
            guard let end = header.firstIndex(of: "]"), header.distance(from: header.startIndex, to: end) > 1 else { return "127.0.0.1" }
            return String(header[...end])
        }
        let name = header.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return name.isEmpty ? "127.0.0.1" : name
    }
}
