import AppKit
import PortholeCore

enum HostCLI {
    static func run(_ args: [String]) -> Int32? {
        if args.first == "curtain-preview" { return curtainPreview(args.dropFirst().first) }
        if args.first == "gallery-snapshots" { return gallerySnapshots(args.dropFirst().first) }
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

    private static func gallerySnapshots(_ path: String?) -> Int32 {
        guard let path else { fail("gallery-snapshots needs an output folder"); return 2 }
        let written = MainActor.assumeIsolated { () -> [String] in
            NSApplication.shared.setActivationPolicy(.prohibited)
            return Gallery.snapshots(into: URL(fileURLWithPath: path))
        }
        written.forEach { print($0) }
        return written.isEmpty ? 1 : 0
    }

    private static func curtainPreview(_ path: String?) -> Int32 {
        guard let path else { fail("curtain-preview needs an output .png path"); return 2 }
        let png = MainActor.assumeIsolated {
            CurtainView.png(size: CGSize(width: 1512, height: 982), notice: CurtainNotice(viewer: "Sam's MacBook Pro", blocking: true))
        }
        guard let png, (try? png.write(to: URL(fileURLWithPath: path))) != nil else { fail("could not render the curtain"); return 1 }
        print(path)
        return 0
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
        req.setValue(LocalSecret.read(in: HostConfig.directory) ?? "", forHTTPHeaderField: localRouteHeader)
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
        guard let config = HostConfig.saved() else { fail("Porthole has never shared this Mac."); return 1 }
        let (status, body) = ask(config.httpPort, "/local/paircode")
        guard let status else { fail("Porthole isn't sharing this Mac (nothing answers on port \(config.httpPort))."); return 1 }
        guard status == 200, let code = body?["code"] as? String else {
            fail(status == 404 ? "The running Porthole refused the local request. It may be an older version, or run as another user; restart it after updating."
                 : "The host answered HTTP \(status).")
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
        var running = false
        if let config = HostConfig.saved() {
            let (status, body) = ask(config.httpPort, "/local/unpair", ["who": who])
            running = status != nil
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
        case .found(let d) where running:
            print("Unpaired \(d.name) (\(d.id)) in \(TrustStore.fileName); it can't get a new token.")
            fail("The running Porthole refused the local request, so a viewer already connected from \(d.name) stays until it disconnects. Restart Porthole to drop it now.")
            return 1
        case .found(let d):
            print("Unpaired \(d.name) (\(d.id)). Porthole isn't running, so there was nothing to disconnect.")
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
