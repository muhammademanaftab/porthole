import CryptoKit
import Foundation
import PortholeCore

func rawGet(_ target: String, host: String = "mini:7878") -> String { "GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n" }

func statusCode(_ r: HTTPResponse) -> Int { Int(r.status.prefix(3)) ?? 0 }

struct PairRun {
    var start: HTTPResponse
    var finish: HTTPResponse?
    var reply: PairReply?
    var error: String? { ((try? JSONSerialization.jsonObject(with: (finish ?? start).body)) as? [String: Any])?["error"] as? String }
}

func pairOverRoutes(_ routes: WebRoutes, code: String, device: String, name: String = "Air") -> PairRun {
    guard let half = PairExchange.begin(code: code, device: device) else { return PairRun(start: HTTPResponse("500 x", "text/plain", "")) }
    let start = routes.respond(to: rawGet("/pair/start?device=\(device)&name=\(name)&v=\(half.share)"))
    guard let h = parsePairStart(status: statusCode(start), body: start.body).share,
          let key = PairExchange.key(half, peer: h, device: device, viewerShare: half.share, hostShare: h) else { return PairRun(start: start) }
    let finish = routes.respond(to: rawGet("/pair/finish?device=\(device)&name=\(name)&tag=\(PairExchange.viewerTag(key: key, device: device))"))
    return PairRun(start: start, finish: finish, reply: parsePairFinish(status: statusCode(finish), body: finish.body, key: key))
}

func deviceToken(_ routes: WebRoutes, device: String, secret: String, name: String = "air", host: String = "mini:7878") -> (response: HTTPResponse, reply: TokenReply) {
    guard let req = tokenRequest(hostAddress: host, credential: .device(id: device, secret: secret), name: name) else {
        return (HTTPResponse("500 x", "text/plain", ""), .refused("no request"))
    }
    let target = req.url.path + "?" + (req.url.query ?? "")
    let r = routes.respond(to: rawGet(target, host: host))
    return (r, parseTokenReply(status: statusCode(r), body: r.body, openKey: req.openKey))
}

func secureTests() {
    let device = "0123456789abcdef"
    guard let a = PairExchange.begin(code: "123456", device: device), let b = PairExchange.begin(code: "123 456", device: device) else {
        check("pair exchange: both sides can begin", false); return
    }
    let ka = PairExchange.key(a, peer: b.share, device: device, viewerShare: a.share, hostShare: b.share)
    let kb = PairExchange.key(b, peer: a.share, device: device, viewerShare: a.share, hostShare: b.share)
    check("pair exchange: the same code gives both sides the same key", ka != nil && ka == kb)
    check("pair exchange: the code itself is not in what is sent", !a.share.contains("123456") && a.share.utf8.count == 64)
    let wrong = PairExchange.begin(code: "123457", device: device)!
    let kw = PairExchange.key(wrong, peer: a.share, device: device, viewerShare: a.share, hostShare: wrong.share)
    let kv = PairExchange.key(a, peer: wrong.share, device: device, viewerShare: a.share, hostShare: wrong.share)
    check("pair exchange: a different code gives different keys", kw != nil && kv != nil && kw != kv)
    let other = PairExchange.begin(code: "123456", device: "fedcba9876543210")!
    check("pair exchange: the code is bound to the device ID",
          PairExchange.key(other, peer: a.share, device: device, viewerShare: a.share, hostShare: other.share)
          != PairExchange.key(a, peer: other.share, device: device, viewerShare: a.share, hostShare: other.share))
    check("pair exchange: a malformed share is refused", PairExchange.key(a, peer: "zz", device: device, viewerShare: a.share, hostShare: "zz") == nil
          && PairExchange.key(a, peer: String(repeating: "f", count: 64), device: device, viewerShare: a.share, hostShare: "") == nil)
    if let ka {
        check("pair exchange: the viewer's tag verifies only under the shared key",
              PairExchange.tagMatches(PairExchange.viewerTag(key: ka, device: device), key: ka, device: device)
              && !PairExchange.tagMatches(PairExchange.viewerTag(key: ka, device: device), key: SymmetricKey(size: .bits256), device: device))
        let sealed = Sealed.sealJSON(["secret": "s3"], key: ka)
        expect("sealed: opens under the same key", Sealed.openJSON(sealed, key: ka)?["secret"] as? String, "s3")
        check("sealed: another key opens nothing", Sealed.openJSON(sealed, key: SymmetricKey(size: .bits256)) == nil)
        check("sealed: the plain text is not in the sealed text", sealed?.contains("s3") == false)
        check("sealed: junk opens nothing", Sealed.openJSON("not base64!", key: ka) == nil && Sealed.openJSON(nil, key: ka) == nil)
    }

    let cred = ViewerCredential.device(id: device, secret: "device-secret")
    let hash = secretDigest("device-secret")
    let nonce = String(repeating: "ab", count: 16)
    let q = Dictionary(uniqueKeysWithValues: TokenProof.query(credential: cred, name: "air", nonce: nonce) ?? [])
    check("token proof: the secret is never in the request", !q.values.contains { $0.contains("device-secret") || $0 == hash })
    check("token proof: verifies against the stored hash", TokenProof.verify(query: q, secretHash: { $0 == device ? hash : nil }) != nil)
    check("token proof: another secret is refused", TokenProof.verify(query: q, secretHash: { _ in secretDigest("other") }) == nil)
    check("token proof: an unknown device is refused", TokenProof.verify(query: q, secretHash: { _ in nil }) == nil)
    var renamed = q; renamed["name"] = "evil"
    check("token proof: the name is covered", TokenProof.verify(query: renamed, secretHash: { _ in hash }) == nil)
    var replayed = q; replayed["nonce"] = String(repeating: "cd", count: 16)
    check("token proof: the nonce is covered", TokenProof.verify(query: replayed, secretHash: { _ in hash }) == nil)
    check("token proof: a password credential has none", TokenProof.query(credential: .password("p"), name: "a", nonce: nonce) == nil)
    let url = tokenRequest(hostAddress: "mini:9000", credential: cred, name: "air", nonce: nonce)?.url.absoluteString ?? ""
    check("token request: device, name, nonce and mac only", url.hasPrefix("http://mini:9000/token?device=\(device)&name=air&nonce=\(nonce)&mac=") && !url.contains("secret"))
    expect("token request: a password credential is the plain URL", tokenRequest(hostAddress: "mini", credential: .password("p w"), name: "air")?.url,
           tokenURL(hostAddress: "mini", password: "p w", name: "air"))
    let key = TokenProof.openKey(credential: cred, nonce: nonce)!
    let good = Data(#"{"sealed":"\#(Sealed.sealJSON(["url": "ws://m:7880", "token": "t"], key: key) ?? "")"}"#.utf8)
    expect("token reply: a sealed answer opens", parseTokenReply(status: 200, body: good, openKey: key), .ok(url: "ws://m:7880", token: "t"))
    expect("token reply: a plain answer to a paired Mac is refused",
           parseTokenReply(status: 200, body: Data(#"{"url":"ws://evil:7880","token":"t"}"#.utf8), openKey: key),
           .refused("The answer didn't come from the Mac this one is paired with."))
    expect("token reply: an answer sealed under another key is refused",
           parseTokenReply(status: 200, body: good, openKey: SymmetricKey(size: .bits256)),
           .refused("The answer didn't come from the Mac this one is paired with."))
}
