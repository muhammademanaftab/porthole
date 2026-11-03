import CryptoKit
import Foundation
import PortholeCore

private struct Fixture {
    let base: URL
    let root: URL

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-selftest-\(UUID().uuidString)")
        root = base.appendingPathComponent("web")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let files = ["index.html": "<html>idx</html>", "app.js": "js()", "style.css": "a{}", "pic.png": "PNG",
                     "data.bin": "bin", "app.js.map": "{}", "sub/inner.js": "inner"]
        for (name, body) in files { try? Data(body.utf8).write(to: root.appendingPathComponent(name)) }
        try? Data("TOP SECRET".utf8).write(to: base.appendingPathComponent("secret.txt"))
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func request(_ target: String, host: String? = "mac.local:7878", method: String = "GET") -> String {
    var r = "\(method) \(target) HTTP/1.1\r\n"
    if let host { r += "Host: \(host)\r\n" }
    return r + "User-Agent: test\r\n\r\n"
}

private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

private func tokenClaims(_ body: Data) -> [String: Any]? {
    guard let token = json(body)?["token"] as? String else { return nil }
    let parts = token.split(separator: ".").map(String.init)
    guard parts.count == 3 else { return nil }
    return decodeBase64URL(parts[1]).flatMap(json)
}

func webRouteTests() {
    let fx = Fixture()
    defer { fx.remove() }
    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    let routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: fx.root, suffix: { "abcd" })
    let bare = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, suffix: { "abcd" })

    for path in ["/", "/index.html", "/?pw=anything"] {
        let (status, type, body) = routes.respond(to: request(path))
        check("http: \(path) serves index.html as UTF-8 HTML",
              status == "200 OK" && type == "text/html; charset=utf-8" && text(body) == "<html>idx</html>")
    }
    let missingIndex = bare.respond(to: request("/"))
    check("http: / without a web root is a 500", missingIndex.0 == "500 Internal Server Error" && text(missingIndex.2) == "web viewer missing")
    expect("http: static file without a web root is a 404", bare.respond(to: request("/app.js")).0, "404 Not Found")

    let ok = routes.respond(to: request("/token?pw=pw-123&name=browser"))
    check("token route: right password is 200 JSON", ok.0 == "200 OK" && ok.1 == "application/json")
    expect("token route: body has exactly url and token", Set(json(ok.2)?.keys.map { $0 } ?? []), ["url", "token"])
    expect("token route: LiveKit URL uses the Host header name and the LiveKit port", json(ok.2)?["url"] as? String, "ws://mac.local:7880")
    let claims = tokenClaims(ok.2)
    let video = claims?["video"] as? [String: Any]
    check("token route: viewer token is for room porthole, identity view-<name>-<suffix>, cannot publish",
          claims?["sub"] as? String == "view-browser-abcd" && claims?["iss"] as? String == "key"
          && video?["room"] as? String == "porthole" && video?["canPublish"] as? Bool == false)
    if let token = json(ok.2)?["token"] as? String {
        let p = token.split(separator: ".").map(String.init)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(p[0]).\(p[1])".utf8), using: SymmetricKey(data: Data("secret".utf8)))
        expect("token route: token is signed with the configured secret", decodeBase64URL(p[2]), Data(mac))
    } else { check("token route: token is signed with the configured secret", false) }

    let refused: [(String, String)] = [
        ("wrong password", "/token?pw=nope"), ("missing password", "/token"), ("empty password", "/token?pw="),
        ("password is case sensitive", "/token?pw=PW-123"), ("first of duplicate pw wins", "/token?pw=bad&pw=pw-123"),
    ]
    for (name, path) in refused {
        let r = routes.respond(to: request(path))
        check("token route: \(name) is 401 with JSON error",
              r.0 == "401 Unauthorized" && r.1 == "application/json" && text(r.2) == #"{"error":"wrong password"}"#)
    }
    expect("token route: duplicate pw with the right one first is accepted",
           routes.respond(to: request("/token?pw=pw-123&pw=bad")).0, "200 OK")
    let odd = WebRoutes(password: "a b&c+d", livekitPort: 7880, tokens: keys, webRoot: nil, suffix: { "s" })
    expect("token route: percent-encoded password is decoded before comparing",
           odd.respond(to: request("/token?pw=a%20b%26c+d")).0, "200 OK")

    expect("token route: missing name becomes viewer", tokenClaims(routes.respond(to: request("/token?pw=pw-123")).2)?["sub"] as? String,
           "view-viewer-abcd")
    expect("token route: name is percent-decoded then stripped of markup",
           tokenClaims(routes.respond(to: request("/token?pw=pw-123&name=%3Cimg%20src%3Dx%3E")).2)?["sub"] as? String,
           "view-imgsrcx-abcd")

    expect("identity: unicode letters kept, punctuation and spaces dropped",
           WebRoutes.viewerIdentity(name: "Renée's Mac!", suffix: "s"), "view-RenéesMac-s")
    expect("identity: hyphens and digits kept, underscores dropped",
           WebRoutes.viewerIdentity(name: "my-mac_2", suffix: "s"), "view-my-mac2-s")
    expect("identity: nil name becomes viewer", WebRoutes.viewerIdentity(name: nil, suffix: "s"), "view-viewer-s")
    expect("identity: empty name becomes viewer", WebRoutes.viewerIdentity(name: "", suffix: "s"), "view-viewer-s")
    expect("identity: name is cut to 24 characters",
           WebRoutes.viewerIdentity(name: "abcdefghijklmnopqrstuvwxyz1234", suffix: "s"), "view-abcdefghijklmnopqrstuvwx-s")

    let hosts: [(String?, String)] = [
        ("100.101.102.103:7878", "ws://100.101.102.103:7880"),
        ("mini", "ws://mini:7880"),
        ("[fe80::1]:7878", "ws://[fe80::1]:7880"),
        ("[::1]", "ws://[::1]:7880"),
        ("   pc.tail.ts.net:80   ", "ws://pc.tail.ts.net:7880"),
        (nil, "ws://127.0.0.1:7880"),
    ]
    for (header, want) in hosts {
        expect("token route: Host \(header.map { "\"\($0)\"" } ?? "missing") gives \(want)",
               json(routes.respond(to: request("/token?pw=pw-123", host: header)).2)?["url"] as? String, want)
    }
    let lower = "GET /token?pw=pw-123 HTTP/1.1\r\nhost: low.case:1\r\n\r\n"
    expect("token route: header name match is case-insensitive", json(routes.respond(to: lower).2)?["url"] as? String, "ws://low.case:7880")
    let decoy = "GET /token?pw=pw-123 HTTP/1.1\r\nX-Host: evil\r\nHost: real\r\n\r\n"
    expect("token route: only a header named Host counts", json(routes.respond(to: decoy).2)?["url"] as? String, "ws://real:7880")

    expect("hostname: plain name", WebRoutes.hostname(from: "example.com"), "example.com")
    expect("hostname: port dropped", WebRoutes.hostname(from: "example.com:8080"), "example.com")
    expect("hostname: IPv6 keeps brackets and drops the port", WebRoutes.hostname(from: "[2001:db8::7]:7878"), "[2001:db8::7]")

    let statics: [(String, String, String)] = [
        ("/app.js", "text/javascript", "js()"), ("/style.css", "text/css", "a{}"), ("/pic.png", "image/png", "PNG"),
        ("/data.bin", "application/octet-stream", "bin"), ("/app.js.map", "application/octet-stream", "{}"),
    ]
    for (path, type, body) in statics {
        let r = routes.respond(to: request(path))
        check("static: \(path) is served as \(type)", r.0 == "200 OK" && r.1 == type && text(r.2) == body)
    }

    check("static: fixture secret exists one level above the web root",
          FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("../secret.txt").standardized.path))
    let blocked = ["/../secret.txt", "/%2e%2e/secret.txt", "/..%2fsecret.txt", "/%2E%2E%2Fsecret.txt", "/sub/inner.js",
                   "/sub%2finner.js", "/nope.js", "/..", "/index.html/"]
    for path in blocked {
        let r = routes.respond(to: request(path))
        check("static: \(path) is a 404", r.0 == "404 Not Found" && r.1 == "text/plain" && text(r.2) == "not found")
    }

    let bad: [(String, String)] = [
        ("empty request", ""), ("POST", request("/token?pw=pw-123", method: "POST")),
        ("lowercase get", request("/", method: "get")), ("HEAD", request("/", method: "HEAD")),
        ("method without target", "GET\r\nHost: x\r\n\r\n"),
    ]
    for (name, req) in bad {
        let r = routes.respond(to: req)
        check("http: \(name) is 400", r.0 == "400 Bad Request" && r.1 == "text/plain" && text(r.2) == "bad request")
    }
}
