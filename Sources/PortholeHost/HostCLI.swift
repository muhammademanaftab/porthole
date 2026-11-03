import Foundation
import PortholeCore

enum HostCLI {
    static func run(_ args: [String]) -> Int32? {
        switch hostPairCommand(args) {
        case .app: return nil
        case .usage(let error):
            guard let error else { print(hostUsage); return 0 }
            fail("\(error)\n\(hostUsage)")
            return 2
        case .paircode: return paircode()
        case .devices: return devices()
        case .unpair(let who): return unpair(who)
        }
    }

    private static func fail(_ s: String) {
        FileHandle.standardError.write(Data("porthole-host: \(s)\n".utf8))
    }

    private static func note(_ s: String) {
        FileHandle.standardError.write(Data("\(s)\n".utf8))
    }

    private static func ask(_ port: UInt16, _ path: String, _ query: KeyValuePairs<String, String> = [:]) -> (status: Int?, body: [String: Any]?) {
        guard let url = localURL(port: port, path: path, query) else { return (nil, nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.setValue("1", forHTTPHeaderField: localRouteHeader)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        let done = DispatchSemaphore(value: 0)
        var out: (Int?, [String: Any]?) = (nil, nil)
        session.dataTask(with: req) { data, resp, _ in
            out = ((resp as? HTTPURLResponse)?.statusCode, data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    private static func paircode() -> Int32 {
        guard let config = HostConfig.saved() else { fail("Porthole Host has never run on this Mac."); return 1 }
        let (status, body) = ask(config.httpPort, "/local/paircode")
        guard let status else { fail("Porthole Host isn't running on this Mac (nothing answers on port \(config.httpPort))."); return 1 }
        guard status == 200, let code = body?["code"] as? String else {
            fail(status == 404 ? "The running Porthole Host is too old for paircode. Restart it after updating." : "The host answered HTTP \(status).")
            return 1
        }
        print(code)
        let left = body?["seconds"] as? Int ?? 0
        let valid = "valid \(left / 60):\(String(format: "%02d", left % 60))"
        if let who = body?["for"] as? String { note("\(who) asked to pair and is waiting for this code (\(valid)).") }
        else { note("Type it on the other Mac (\(valid), one Mac, \(PairingCodes.maxWrongTries) tries).") }
        return 0
    }

    private static func devices() -> Int32 {
        let dir = HostConfig.directory
        print("This Mac: \(DeviceIdentity.loadOrCreate(in: dir).id)  \(HTTPServer.computerName)")
        let paired = TrustStore(directory: dir).devices()
        guard !paired.isEmpty else { print("No Macs are paired with this one."); return 0 }
        print("Paired Macs that may view this one:")
        let f = ISO8601DateFormatter()
        for d in paired { print("  \(d.id)  \(d.name)  (paired \(f.string(from: d.pairedAt)))") }
        return 0
    }

    private static func unpair(_ who: String) -> Int32 {
        if let config = HostConfig.saved() {
            let (status, body) = ask(config.httpPort, "/local/unpair", ["who": who])
            switch status {
            case 200?:
                print("Unpaired \(body?["name"] as? String ?? who) (\(body?["id"] as? String ?? "?")). It lost access and was disconnected.")
                return 0
            case 404? where body != nil, 409?:
                fail(body?["error"] as? String ?? "Couldn't unpair \(who).")
                for m in body?["matches"] as? [[String: String]] ?? [] { note("  \(m["id"] ?? "")  \(m["name"] ?? "")") }
                return 1
            default:
                break
            }
        }
        switch TrustStore(directory: HostConfig.directory).unpair(who) {
        case .found(let d):
            print("Unpaired \(d.name) (\(d.id)). Porthole Host isn't running, so there was nothing to disconnect.")
            return 0
        case .none:
            fail("No paired Mac matches \"\(who)\". See porthole-host devices.")
            return 1
        case .ambiguous(let list):
            fail("Several paired Macs match \"\(who)\"; use the device ID:")
            for d in list { note("  \(d.id)  \(d.name)") }
            return 1
        }
    }
}
