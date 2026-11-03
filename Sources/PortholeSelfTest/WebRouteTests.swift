import CryptoKit
import Foundation
import PortholeCore

private struct Fixture {
    let base: URL
    let root: URL

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-selftest-\(UUID().uuidString)")
        root = base.appendingPathComponent("web")
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        let files = ["index.html": "<html>idx</html>", "app.js": "js()", "style.css": "a{}", "pic.png": "PNG",
                     "site.webmanifest": "{}", "data.bin": "bin", "app.js.map": "{}", "package.json": "{}",
                     ".hidden.js": "h", "other.html": "o", "sub/inner.js": "inner", "tests/core.test.js": "t"]
        for (name, body) in files { try? Data(body.utf8).write(to: root.appendingPathComponent(name)) }
        try? Data("TOP SECRET".utf8).write(to: base.appendingPathComponent("secret.js"))
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

private func request(_ target: String, host: String? = "mac.local:7878", method: String = "GET", version: String = "HTTP/1.1") -> String {
    var r = "\(method) \(target) \(version)\r\n"
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
    guard FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("../secret.js").standardized.path) else {
        check("web route fixture could be created", false)
        return
    }
    let keys = AccessToken(apiKey: "key", apiSecret: "secret")
    let routes = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: fx.root, suffix: { "abcd" })
    let bare = WebRoutes(password: "pw-123", livekitPort: 7880, tokens: keys, webRoot: nil, suffix: { "abcd" })

    for path in ["/", "/index.html", "/?pw=anything"] {
        let r = routes.respond(to: request(path))
        check("http: \(path) serves index.html as UTF-8 HTML",
              r.status == "200 OK" && r.contentType == "text/html; charset=utf-8" && text(r.body) == "<html>idx</html>")
    }
    let missingIndex = bare.respond(to: request("/"))
    check("http: / without a web root is a 500", missingIndex.status == "500 Internal Server Error" && text(missingIndex.body) == "web viewer missing")
    expect("http: static file without a web root is a 404", bare.respond(to: request("/app.js")).status, "404 Not Found")

    let ok = routes.respond(to: request("/token?pw=pw-123&name=browser"))
    check("token route: right password is 200 JSON", ok.status == "200 OK" && ok.contentType == "application/json")
    expect("token route: body has exactly url and token", Set(json(ok.body)?.keys.map { $0 } ?? []), ["url", "token"])
    let claims = tokenClaims(ok.body)
    let video = claims?["video"] as? [String: Any]
    check("token route: viewer token is for room porthole, identity view-<name>-<suffix>, cannot publish",
          claims?["sub"] as? String == "view-browser-abcd" && claims?["iss"] as? String == "key"
          && video?["room"] as? String == "porthole" && video?["canPublish"] as? Bool == false)
    if let token = json(ok.body)?["token"] as? String {
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
        check("token route: \(name) is 403 with JSON error",
              r.status == "403 Forbidden" && r.contentType == "application/json" && text(r.body) == #"{"error":"wrong password"}"#)
    }
    expect("token route: duplicate pw with the right one first is accepted",
           routes.respond(to: request("/token?pw=pw-123&pw=bad")).status, "200 OK")
    let odd = WebRoutes(password: "a b&c+d", livekitPort: 7880, tokens: keys, webRoot: nil, suffix: { "s" })
    expect("token route: percent-encoded password is decoded before comparing",
           odd.respond(to: request("/token?pw=a%20b%26c+d")).status, "200 OK")

    expect("token route: missing name becomes viewer", tokenClaims(routes.respond(to: request("/token?pw=pw-123")).body)?["sub"] as? String,
           "view-viewer-abcd")
    expect("token route: name is percent-decoded then stripped of markup",
           tokenClaims(routes.respond(to: request("/token?pw=pw-123&name=%3Cimg%20src%3Dx%3E")).body)?["sub"] as? String,
           "view-imgsrcx-abcd")

    expect("identity: unicode letters kept, punctuation and spaces dropped",
           WebRoutes.viewerIdentity(name: "Renée's Mac!", suffix: "s"), "view-RenéesMac-s")
    expect("identity: hyphens and digits kept, underscores dropped",
           WebRoutes.viewerIdentity(name: "my-mac_2", suffix: "s"), "view-my-mac2-s")
    expect("identity: nil name becomes viewer", WebRoutes.viewerIdentity(name: nil, suffix: "s"), "view-viewer-s")
    expect("identity: empty name becomes viewer", WebRoutes.viewerIdentity(name: "", suffix: "s"), "view-viewer-s")
    expect("identity: name with no allowed characters becomes viewer", WebRoutes.viewerIdentity(name: "!!! ***", suffix: "s"), "view-viewer-s")
    expect("identity: name is cut to 24 characters",
           WebRoutes.viewerIdentity(name: "abcdefghijklmnopqrstuvwxyz1234", suffix: "s"), "view-abcdefghijklmnopqrstuvwx-s")

    let hosts: [(String?, String, String)] = [
        ("100.101.102.103:7878", "HTTP/1.1", "ws://100.101.102.103:7880"),
        ("mini", "HTTP/1.1", "ws://mini:7880"),
        ("[fe80::1]:7878", "HTTP/1.1", "ws://[fe80::1]:7880"),
        ("[::1]", "HTTP/1.1", "ws://[::1]:7880"),
        ("   pc.tail.ts.net:80   ", "HTTP/1.1", "ws://pc.tail.ts.net:7880"),
        ("", "HTTP/1.1", "ws://127.0.0.1:7880"),
        (":7878", "HTTP/1.1", "ws://127.0.0.1:7880"),
        ("[::1", "HTTP/1.1", "ws://127.0.0.1:7880"),
        ("[]:7878", "HTTP/1.1", "ws://127.0.0.1:7880"),
        (nil, "HTTP/1.0", "ws://127.0.0.1:7880"),
    ]
    for (header, version, want) in hosts {
        expect("token route: \(version) Host \(header.map { "\"\($0)\"" } ?? "missing") gives \(want)",
               json(routes.respond(to: request("/token?pw=pw-123", host: header, version: version)).body)?["url"] as? String, want)
    }
    let noHost = routes.respond(to: request("/token?pw=pw-123", host: nil))
    check("http: HTTP/1.1 without a Host header is 400", noHost.status == "400 Bad Request" && text(noHost.body) == "bad request")
    let lower = "GET /token?pw=pw-123 HTTP/1.1\r\nhost: low.case:1\r\n\r\n"
    expect("token route: header name match is case-insensitive", json(routes.respond(to: lower).body)?["url"] as? String, "ws://low.case:7880")
    let decoy = "GET /token?pw=pw-123 HTTP/1.1\r\nX-Host: evil\r\nHost: real\r\n\r\n"
    expect("token route: only a header named Host counts", json(routes.respond(to: decoy).body)?["url"] as? String, "ws://real:7880")

    let statics: [(String, String, String)] = [
        ("/app.js", "text/javascript", "js()"), ("/style.css", "text/css", "a{}"), ("/pic.png", "image/png", "PNG"),
        ("/site.webmanifest", "application/manifest+json", "{}"),
    ]
    for (path, type, body) in statics {
        let r = routes.respond(to: request(path))
        check("static: \(path) is served as \(type)", r.status == "200 OK" && r.contentType == type && text(r.body) == body && r.sendsBody)
    }

    let blocked = ["/../secret.js", "/%2e%2e/secret.js", "/..%2fsecret.js", "/%2E%2E%2Fsecret.js", "/sub/inner.js",
                   "/sub%2finner.js", "/nope.js", "/..", "/index.html/", "/data.bin", "/app.js.map", "/package.json",
                   "/.hidden.js", "/tests/core.test.js", "/tests", "/other.html", "/.js", "/..%5csecret.js"]
    for path in blocked {
        let r = routes.respond(to: request(path))
        check("static: \(path) is a 404", r.status == "404 Not Found" && r.contentType == "text/plain" && text(r.body) == "not found")
    }

    let headReq = routes.respond(to: request("/app.js", method: "HEAD"))
    check("http: HEAD answers like GET without sending the body",
          headReq.status == "200 OK" && headReq.contentType == "text/javascript" && !headReq.sendsBody
          && headReq.head.contains("Content-Length: 4\r\n") && headReq.serialized == Data(headReq.head.utf8))
    check("http: GET sends the body", routes.respond(to: request("/app.js")).sendsBody)

    for method in ["POST", "PUT", "DELETE", "OPTIONS", "get"] {
        let r = routes.respond(to: request("/token?pw=pw-123", method: method))
        check("http: \(method) is 405 with Allow: GET, HEAD",
              r.status == "405 Method Not Allowed" && r.head.contains("\r\nAllow: GET, HEAD\r\n"))
    }

    let bad: [(String, String)] = [
        ("empty request", ""), ("method without target", "GET\r\nHost: x\r\n\r\n"),
        ("invalid percent escape", request("/%zz")), ("truncated percent escape", request("/app.js%2")),
        ("invalid escape in the query", request("/token?pw=%G1")),
    ]
    for (name, req) in bad {
        let r = routes.respond(to: req)
        check("http: \(name) is 400", r.status == "400 Bad Request" && r.contentType == "text/plain" && text(r.body) == "bad request")
    }
}
