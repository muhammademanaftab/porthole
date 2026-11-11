import Foundation
import PortholeCore

enum ShareCommand {
    static func request(_ path: String, _ query: KeyValuePairs<String, String>, timeout: TimeInterval = 8) -> (status: Int, body: [String: Any])? {
        guard let config = savedConfig(), let url = localURL(port: config.httpPort, path: path, query) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(LocalSecret.read(in: Paths.support) ?? "", forHTTPHeaderField: localRouteHeader)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Int, [String: Any])?
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, _ in
            if let code = (resp as? HTTPURLResponse)?.statusCode {
                out = (code, data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:])
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return out
    }

    static func run(_ o: ShareOptions) -> Int32 {
        let reply: (status: Int, body: [String: Any])?
        if o.list {
            reply = request("/local/shares", [:])
        } else if let id = o.revoke {
            reply = request("/local/unshare", ["id": id])
        } else {
            reply = request("/local/share", ["window": o.window ?? "", "control": o.control ? "1" : "0", "wifi": o.wifiOnly ? "1" : "0",
                                             "ttl": o.ttl.map { String(Int($0)) } ?? ""])
        }
        guard let reply else {
            fail("Porthole isn't sharing this Mac (or doesn't answer on 127.0.0.1). Share links are made by Porthole with Share this Mac on.")
            return 1
        }
        guard reply.status == 200 else {
            if reply.status == 404 && reply.body.isEmpty { fail("this Porthole is too old for share links, or its local secret doesn't match"); return 1 }
            fail(reply.body["error"] as? String ?? "the host answered HTTP \(reply.status)")
            if let matches = reply.body["matches"] as? [[String: Any]] {
                for m in matches { say("  \(m["id"] ?? "")  \(m["app"] ?? "")  \(m["title"] ?? "")") }
            }
            return 1
        }
        if o.json { printJSON(reply.body); return 0 }
        if o.list {
            let links = reply.body["links"] as? [[String: Any]] ?? []
            print(ShareText.list(links, allowControl: reply.body["allowRemoteControl"] as? Bool ?? false))
        } else if o.revoke != nil {
            if let n = reply.body["revoked"] as? Int { print("Revoked \(n) share link\(n == 1 ? "" : "s").") }
            else { print("Revoked \(reply.body["id"] ?? "") (\(reply.body["label"] ?? "")). Its guests were disconnected.") }
        } else {
            print(ShareText.minted(reply.body))
        }
        return 0
    }
}
