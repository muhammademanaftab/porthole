import AppKit
import Foundation
import PortholeCore

@MainActor
enum ViewerTools {
    nonisolated static func fail(_ s: String) {
        FileHandle.standardError.write(Data("porthole-view: \(s)\n".utf8))
    }

    nonisolated static func finish(_ code: Int32) -> Never {
        VLog.flush()
        exit(code)
    }

    static func runLoop(timeout: TimeInterval, _ what: String, _ body: @escaping @MainActor () -> Void) -> Never {
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            fail("timed out after \(Int(timeout)) s \(what)")
            finish(1)
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        dispatchMain()
    }

    static func resolve(_ host: String) -> String {
        resolveHostAddress(host, trust: PasswordStore.trust, known: PasswordStore.knownHosts)
    }

    static func machines(json: Bool) -> Never {
        runLoop(timeout: 20, "looking for hosts") {
            let d = HostDiscovery()
            d.start()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                while d.scanning { try? await Task.sleep(nanoseconds: 200_000_000) }
                let hosts = d.hosts
                let trust = PasswordStore.trust
                if json {
                    let rows = hosts.map { h -> [String: Any] in
                        var o: [String: Any] = ["name": h.name, "port": h.port, "status": "\(h.status)", "bonjour": h.viaBonjour,
                                                "tailscale": h.viaTailscale, "saved": h.saved, "paired": trust.host(for: h) != nil]
                        if let ip = h.tailscaleIP { o["tailscaleIP"] = ip }
                        if let lan = h.lanHost { o["lan"] = lan }
                        if let id = h.hostID { o["id"] = id }
                        return o
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                        FileHandle.standardOutput.write(data + Data("\n".utf8))
                    }
                } else if hosts.isEmpty {
                    print(d.tailscaleRunning ? "No Porthole hosts found on the tailnet or this network." : "No Porthole hosts found on this network (Tailscale isn't running).")
                } else {
                    for h in hosts {
                        var via: [String] = []
                        if h.viaTailscale { via.append("tailnet") }
                        if h.viaBonjour { via.append("bonjour") }
                        if h.saved { via.append("saved") }
                        let address = [h.tailscaleIP, h.lanHost].compactMap { $0 }.joined(separator: ", ")
                        let state = h.status == .online ? "online" : h.status == .older ? "older Porthole" : "not found now"
                        let lock = trust.host(for: h) != nil ? "paired" : "not paired"
                        print("\(h.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(address.padding(toLength: 34, withPad: " ", startingAt: 0)) \(state), \(lock) (\(via.joined(separator: ", ")))")
                    }
                }
                finish(0)
            }
        }
    }

    static func withWindows(_ host: String, _ then: @escaping @MainActor (String, [WindowInfo]) -> Void) -> Never {
        let address = resolve(host)
        guard let (cred, _) = PasswordStore.credential(for: address) else {
            fail("no saved pairing or password for \(address). Pair first: porthole-view request \(address)")
            finish(1)
        }
        runLoop(timeout: 25, "waiting for \(address)'s window list") {
            let c = Connection(hostAddress: address, credential: cred)
            var done = false
            c.onWindows = { list in
                guard !done else { return }
                done = true
                Task { @MainActor in
                    then(address, WindowFilter.sortedForPicker(list))
                    await c.disconnect()
                }
            }
            c.onError = { msg in fail(msg) }
            Task { @MainActor in
                do {
                    try await c.connect()
                    for _ in 0..<50 where c.hostParticipant == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                    c.requestList()
                } catch {
                    fail("couldn't connect to \(address): \(error.localizedDescription)")
                    finish(1)
                }
            }
        }
    }

    static func list(_ host: String, json: Bool) -> Never {
        withWindows(host) { _, list in
            if json {
                let rows = list.map { w -> [String: Any] in
                    var o: [String: Any] = ["id": Int(w.id), "app": w.app, "title": w.title, "w": w.w, "h": w.h]
                    if let b = w.bundle { o["bundle"] = b }
                    return o
                }
                if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                    FileHandle.standardOutput.write(data + Data("\n".utf8))
                }
            } else {
                print(renderWindowList(list))
            }
            finish(0)
        }
    }

    static func open(_ host: String, target: String) -> Never {
        withWindows(host) { address, list in
            switch pickWindow(target, in: list) {
            case .found(let w):
                launch(address, w)
            case .none:
                fail("no window on \(address) matches \"\(target)\". porthole-view ls \(address) lists them.")
                finish(1)
            case .ambiguous(let many):
                fail("\(many.count) windows match \"\(target)\"; use the window ID:")
                print(renderWindowList(many))
                finish(1)
            }
        }
    }

    static func recent(_ n: Int?) -> Never {
        let list = RecentPortals.load(in: portholeSupportDirectory())
        guard let n else {
            print(RecentPortals.render(list))
            finish(0)
        }
        guard n <= list.count else {
            fail(list.isEmpty ? "there are no recent portals yet" : "there are only \(list.count) recent portals")
            finish(1)
        }
        let entry = list[n - 1]
        withWindows(entry.host) { address, windows in
            guard let w = RecentPortals.match(entry, in: windows) else {
                fail("\(entry.app) — \(entry.title) isn't open on \(entry.hostName) any more. porthole-view ls \(address) lists what is.")
                finish(1)
            }
            launch(address, w)
        }
    }

    static func launch(_ address: String, _ w: WindowInfo) {
        print("Opening \(w.app) — \(w.title.isEmpty ? "(untitled)" : w.title) (window \(w.id)) from \(address)")
        VLog.info("cli open: window \(w.id) of \(w.app) on \(address)")
        let env = ["PORTHOLE_OPEN": "id:\(w.id)"]
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = [address]
            cfg.environment = env
            cfg.createsNewApplicationInstance = !NSRunningApplication.runningApplications(withBundleIdentifier: PasswordStore.service).isEmpty
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, error in
                if let error { fail("couldn't open Porthole: \(error.localizedDescription)"); finish(1) }
                finish(0)
            }
            return
        }
        guard let exe = Bundle.main.executableURL else { fail("can't find my own binary"); finish(1) }
        let p = Process()
        p.executableURL = exe
        p.arguments = [address]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { fail("couldn't start \(exe.path): \(error.localizedDescription)"); finish(1) }
        finish(0)
    }
}
