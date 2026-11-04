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
    public var trust: TrustStore?
    public var hostID: String?
    public var onPairRequest: ((PairRequester, String) -> Void)?
    public var onUnpair: ((PairedDevice) -> Void)?
    public var localSecret: String?
    public var localStatus: (() -> [String: Any])?
    public var shares: ShareLinkStore?
    public var guestControl: (() -> Bool)?
    public var resolveWindow: ((String) -> WindowPick)?
    public var shareAddresses: (() -> (lan: String?, tailnet: String?))?
    public var httpPort: UInt16 = HostConfig.defaultHTTPPort
    public var onSharesChanged: (() -> Void)?
    public var onUnshare: ((ShareLink) -> Void)?
    public var now: () -> Date = Date.init
    public var ownsAddress: ((String) -> Bool)?
    public static let viewerTokenTTL: TimeInterval = 600

    public static let servedExtensions = [".js", ".css", ".png", ".webmanifest"]
    static let mutatingPaths: Set<String> = ["/pair", "/pair/request", "/local/paircode", "/local/unpair", "/local/share", "/local/unshare"]

    public init(password: String, livekitPort: Int, tokens: AccessToken, webRoot: URL?,
                suffix: @escaping () -> String = { randomSecret(bytes: 3) }, pairing: PairingDesk? = nil, hostName: String = "Mac",
                trust: TrustStore? = nil, hostID: String? = nil) {
        self.password = password; self.livekitPort = livekitPort; self.tokens = tokens
        self.webRoot = webRoot; self.suffix = suffix
        self.pairing = pairing; self.hostName = hostName
        self.trust = trust; self.hostID = hostID
    }

    public func respond(to request: String, fromLoopback: Bool = false) -> HTTPResponse {
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
        if parts[0] == "HEAD" && Self.mutatingPaths.contains(comps.path) {
            return HTTPResponse("405 Method Not Allowed", "text/plain", "method not allowed", headers: [("Allow", "GET")])
        }
        let hostHeader = hostLine.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? ""
        let local = fromLoopback && isLocalHostHeader(hostHeader) && localSecret.map { secret in
            lines.dropFirst().contains { line in
                guard line.lowercased().hasPrefix(localRouteHeader.lowercased() + ":") else { return false }
                return constantTimeEqual(String(line.dropFirst(localRouteHeader.count + 1)).trimmingCharacters(in: .whitespaces), secret)
            }
        } == true
        var response = comps.path.hasPrefix("/local/") ? localRoute(comps, allowed: local) : route(comps, hostHeader: hostHeader)
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
            if let share = query["share"] { return guestToken(share, client: query["cid"], hostHeader: hostHeader) }
            let identity: String
            switch authorizeToken(query: query, password: password, verify: { id, secret in trust?.verify(id: id, secret: secret) }) {
            case .refused:
                return HTTPResponse("403 Forbidden", "application/json", #"{"error":"wrong password"}"#)
            case .unpaired:
                return Self.json("403 Forbidden", ["error": "This Mac isn't paired with \(hostName) any more. Pair it again.", "unpaired": true])
            case .password:
                identity = Self.viewerIdentity(name: query["name"], suffix: suffix())
            case .device(let device):
                identity = pairedIdentity(name: query["name"], suffix: suffix(), device: device.id)
            }
            let token = tokens.make(identity: identity, room: "porthole", canPublish: false, ttl: Self.viewerTokenTTL)
            let body: [String: String] = ["url": "ws://\(Self.hostname(from: hostHeader)):\(livekitPort)", "token": token]
            return HTTPResponse("200 OK", "application/json", (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        case "/hello":
            let hello = HostHello(name: hostName, version: portholeProtocolVersion, id: hostID)
            let trust = self.trust
            guard let proof = HelloProof.answer(query: query, hostHeader: hostHeader, hostID: hostID, password: password,
                                                secretHash: { id in trust?.devices().first { $0.id == id }?.secretHash },
                                                ownsAddress: ownsAddress ?? { _ in false }),
                  var obj = (try? JSONSerialization.jsonObject(with: hello.json)) as? [String: Any] else {
                return HTTPResponse("200 OK", "application/json", hello.json)
            }
            obj["proof"] = proof
            return Self.json("200 OK", obj)
        case "/pair":
            return pair(query["code"] ?? "", device: query["device"], name: query["name"])
        case "/pair/request":
            return pairRequest(device: query["device"] ?? "", name: query["name"])
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

    private func guestToken(_ token: String, client: String?, hostHeader: String) -> HTTPResponse {
        guard let shares, let link = shares.verify(token) else {
            return Self.json("403 Forbidden", ["error": "This link has expired or was turned off. Ask for a new one.", "expired": true])
        }
        let ttl = min(Self.viewerTokenTTL, link.expires.timeIntervalSince(now()))
        guard ttl >= 1 else { return Self.json("403 Forbidden", ["error": "This link has expired. Ask for a new one.", "expired": true]) }
        let identity = GuestIdentity.make(link: link.id, client: client)
        let token = tokens.make(identity: identity, room: "porthole", canPublish: false, ttl: ttl)
        var guest: [String: Any] = ["link": link.id, "label": link.label, "control": RemoteControlSwitch.controlsAtOnce(link, switchOn: guestControl?() ?? false),
                                    "expires": ISO8601DateFormatter().string(from: link.expires), "host": hostName]
        if let w = link.window { guest["window"] = w }
        return Self.json("200 OK", ["url": "ws://\(Self.hostname(from: hostHeader)):\(livekitPort)", "token": token, "guest": guest])
    }

    public func mintShare(window target: String?, control: Bool, wifiOnly: Bool, ttl: TimeInterval?) -> HTTPResponse {
        guard let shares else { return HTTPResponse("404 Not Found", "text/plain", "not found") }
        var window: UInt32?
        var label = ShareLinks.pickerLabel
        if let target, !target.trimmingCharacters(in: .whitespaces).isEmpty {
            switch resolveWindow?(target) ?? .none {
            case .found(let w):
                window = w.id
                label = w.portalTitle
            case .none:
                return Self.json("404 Not Found", ["error": "No shareable window matches \"\(target)\"."])
            case .ambiguous(let list):
                return Self.json("409 Conflict", ["error": "Several windows match \"\(target)\"; use the window ID.",
                                                  "matches": list.map { ["id": $0.id, "app": $0.app, "title": $0.title] }])
            }
        }
        guard let minted = shares.mint(window: window, label: label, control: control, ttl: ttl ?? ShareLinks.defaultTTL) else {
            return Self.json("500 Internal Server Error", ["error": "The host couldn't save the link."])
        }
        let addrs: (lan: String?, tailnet: String?) = shareAddresses?() ?? (nil, nil)
        let urls = ShareURLs.make(token: minted.token, window: window, lan: addrs.lan, tailnet: addrs.tailnet, port: httpPort, wifiOnly: wifiOnly)
        onSharesChanged?()
        var body = Self.linkJSON(minted.link)
        body["links"] = urls.map { ["kind": $0.kind, "url": $0.url] }
        body["allowRemoteControl"] = guestControl?() ?? false
        if urls.isEmpty { body["warning"] = wifiOnly ? "This Mac has no Wi-Fi or local network address." : "This Mac has no local network or tailnet address." }
        return Self.json("200 OK", body)
    }

    static func linkJSON(_ l: ShareLink) -> [String: Any] {
        var o: [String: Any] = ["id": l.id, "label": l.label, "control": l.control,
                                "expires": ISO8601DateFormatter().string(from: l.expires), "created": ISO8601DateFormatter().string(from: l.created)]
        if let w = l.window { o["window"] = w }
        return o
    }

    private func pair(_ code: String, device: String?, name: String?) -> HTTPResponse {
        guard let pairing, let trust else { return HTTPResponse("404 Not Found", "text/plain", "not found") }
        guard let device else {
            return Self.json("400 Bad Request", ["error": "This copy of Porthole is too old to pair with \(hostName). Update it, or use the host's password."])
        }
        guard DeviceIdentity.isValidID(device) else { return Self.json("400 Bad Request", ["error": "That isn't a Porthole device ID."]) }
        let outcome = pairing.redeem(code, device: device)
        guard outcome == .accepted else { return Self.json("403 Forbidden", ["error": pairMessage(outcome) ?? ""]) }
        guard let secret = trust.pair(id: device, name: cleanDeviceName(name)) else {
            return Self.json("500 Internal Server Error", ["error": "The host couldn't save the pairing."])
        }
        var body: [String: Any] = ["secret": secret, "host": hostName]
        if let hostID { body["host_id"] = hostID }
        return Self.json("200 OK", body)
    }

    private func pairRequest(device: String, name: String?) -> HTTPResponse {
        guard let pairing, trust != nil else { return HTTPResponse("404 Not Found", "text/plain", "not found") }
        guard DeviceIdentity.isValidID(device) else { return Self.json("400 Bad Request", ["error": "That isn't a Porthole device ID."]) }
        let who = PairRequester(id: device, name: cleanDeviceName(name))
        switch pairing.request(from: who) {
        case .throttled:
            return Self.json("429 Too Many Requests", ["error": "Too many pairing requests. Wait a few minutes and try again."])
        case .busy(let seconds):
            return Self.json("409 Conflict", ["error": "Another Mac is pairing with \(hostName) right now. Try again in \(seconds) s, or choose Pair a New Viewer… on the host and enter that code."])
        case .paused(let seconds):
            let minutes = (seconds + 59) / 60
            return Self.json("429 Too Many Requests", ["error": "Too many wrong codes on \(hostName). Pairing requests are paused for \(minutes) \(minutes == 1 ? "minute" : "minutes"), or choose Pair a New Viewer… on the host and enter that code."])
        case .issued(let code), .same(let code):
            onPairRequest?(who, code)
            return Self.json("200 OK", ["requested": true, "host": hostName])
        }
    }

    private func localRoute(_ comps: URLComponents, allowed: Bool) -> HTTPResponse {
        guard allowed, let pairing, let trust else { return HTTPResponse("404 Not Found", "text/plain", "not found") }
        let query = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch comps.path {
        case "/local/share":
            return mintShare(window: query["window"], control: query["control"] == "1", wifiOnly: query["wifi"] == "1",
                             ttl: query["ttl"].flatMap(TimeInterval.init))
        case "/local/shares":
            guard let shares else { return HTTPResponse("404 Not Found", "text/plain", "not found") }
            return Self.json("200 OK", ["links": shares.links().map(Self.linkJSON), "allowRemoteControl": guestControl?() ?? false])
        case "/local/unshare":
            guard let shares else { return HTTPResponse("404 Not Found", "text/plain", "not found") }
            let id = query["id"] ?? ""
            if id == "all" {
                let gone = shares.links()
                shares.revokeAll()
                for l in gone { onUnshare?(l) }
                onSharesChanged?()
                return Self.json("200 OK", ["revoked": gone.count])
            }
            guard let gone = shares.revoke(id: id) else { return Self.json("404 Not Found", ["error": "No share link has the ID \"\(id)\"."]) }
            onUnshare?(gone)
            onSharesChanged?()
            return Self.json("200 OK", Self.linkJSON(gone))
        case "/local/paircode":
            let current = pairing.currentOrIssue()
            var body: [String: Any] = ["code": current.code, "seconds": current.secondsLeft]
            if let who = current.requester { body["for"] = who.name; body["device"] = who.id }
            return Self.json("200 OK", body)
        case "/local/status":
            return Self.json("200 OK", localStatus?() ?? [:])
        case "/local/unpair":
            let who = query["who"] ?? ""
            switch trust.unpair(who) {
            case .found(let device):
                onUnpair?(device)
                return Self.json("200 OK", ["id": device.id, "name": device.name])
            case .none:
                return Self.json("404 Not Found", ["error": "No paired Mac matches \"\(who)\"."])
            case .ambiguous(let list):
                return Self.json("409 Conflict", ["error": "Several paired Macs match; use the device ID.",
                                                  "matches": list.map { ["id": $0.id, "name": $0.name] }])
            }
        default:
            return HTTPResponse("404 Not Found", "text/plain", "not found")
        }
    }

    static func json(_ status: String, _ obj: [String: Any]) -> HTTPResponse {
        HTTPResponse(status, "application/json", (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data())
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
