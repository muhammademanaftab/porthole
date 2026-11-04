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
        let limit = Timer(timeInterval: timeout, repeats: false) { _ in
            fail("timed out after \(Int(timeout)) s \(what)")
            finish(1)
        }
        RunLoop.main.add(limit, forMode: .common)
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
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

    static func withWindows(_ host: String, unlock: UnlockEnv.Request? = nil, _ then: @escaping @MainActor (String, [WindowInfo]) -> Void) -> Never {
        let address = resolve(host)
        guard let (cred, _) = PasswordStore.credential(for: address) else {
            fail("no saved pairing or password for \(address). Pair first: porthole-view request \(address)")
            finish(1)
        }
        runLoop(timeout: UnlockEnv.cliTimeout(unlock), "waiting for \(address)'s window list") {
            let c = Connection(hostAddress: address, credential: cred)
            var done = false
            var lockedSeen = false
            var unlockTried = false
            c.onWindows = { list in
                guard !done else { return }
                if let unlock, UnlockEnv.shouldAsk(lockedSeen: lockedSeen, listEmpty: list.isEmpty, tried: unlockTried) {
                    unlockTried = true
                    print("\(address) is locked; asking it to type the password into its lock screen in \(unlock.delay) s")
                    VLog.info("cli open: \(address) is locked; \(UnlockEnv.name) asks to unlock it in \(unlock.delay) s")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(unlock.delay) * 1_000_000_000)
                        c.unlock(password: unlock.password)
                    }
                    return
                }
                done = true
                Task { @MainActor in
                    then(address, WindowFilter.sortedForPicker(list))
                    await c.disconnect()
                }
            }
            c.onUnlock = { m in
                let line = "unlock: \(m.on == true ? "unlocked" : "not unlocked"): \(m.msg ?? "")"
                VLog.info("cli open: \(line)")
                guard m.on == true else { fail(line); finish(1) }
                print(line)
                c.requestList()
            }
            c.onError = { msg in
                if unlock != nil, UnlockPrompt.isLockNotice(msg) { lockedSeen = true; return }
                fail(msg)
            }
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
        let unlock = UnlockEnv.parse(ProcessInfo.processInfo.environment[UnlockEnv.name])
        if ProcessInfo.processInfo.environment[UnlockEnv.name] != nil, unlock == nil {
            fail("\(UnlockEnv.name) must be secs:password (secs 0 to \(UnlockEnv.maxDelay)); ignoring it")
        }
        withWindows(host, unlock: unlock) { address, list in
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

    static func runningViewers() -> [NSRunningApplication] {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier == PasswordStore.service || (exe != nil && app.executableURL?.resolvingSymlinksInPath() == exe)
        }
    }

    static func launch(_ address: String, _ w: WindowInfo) {
        print("Opening \(w.app) — \(w.title.isEmpty ? "(untitled)" : w.title) (window \(w.id)) from \(address)")
        let viewers = runningViewers()
        switch ViewerLaunch.decide(viewers: viewers.map(\.processIdentifier), me: ProcessInfo.processInfo.processIdentifier) {
        case .handOff(let pids):
            let request = OpenRequest(address: address, windowID: w.id, token: UUID().uuidString)
            let apps = viewers.filter { pids.contains($0.processIdentifier) }
            handOff(request, to: pids) {
                if apps.contains(where: { $0.activationPolicy == .regular }) {
                    fail("Porthole is running but didn't take the request. Open the window from its picker, or quit Porthole and try again.")
                    finish(1)
                }
                start(address, w)
            }
        case .launch:
            start(address, w)
        }
    }

    static func handOff(_ request: OpenRequest, to pids: [Int32], otherwise: @escaping @MainActor () -> Void) {
        guard let pid = pids.first else { otherwise(); return }
        let center = DistributedNotificationCenter.default()
        let pending = PendingHandOff()
        pending.observer = center.addObserver(forName: Notification.Name(OpenRequest.replyNotification), object: request.token, queue: .main) { note in
            guard let reply = OpenReply(userInfo: note.userInfo), reply.token == request.token else { return }
            MainActor.assumeIsolated {
                guard pending.end() else { return }
                VLog.info("cli open: handed window \(request.windowID) on \(request.address) to Porthole pid \(pid): \(reply.message)")
                if reply.ok {
                    print("Porthole is already running: \(reply.message).")
                    finish(0)
                }
                fail(reply.message)
                finish(1)
            }
        }
        center.postNotificationName(Notification.Name(OpenRequest.notification), object: String(pid),
                                    userInfo: request.userInfo, deliverImmediately: true)
        let wait = Timer(timeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard pending.end() else { return }
                handOff(request, to: Array(pids.dropFirst()), otherwise: otherwise)
            }
        }
        RunLoop.main.add(wait, forMode: .common)
    }

    static func start(_ address: String, _ w: WindowInfo) {
        VLog.info("cli open: window \(w.id) of \(w.app) on \(address)")
        let env = ["PORTHOLE_OPEN": "id:\(w.id)"]
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = [address]
            cfg.environment = env
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

@MainActor
final class PendingHandOff {
    var observer: NSObjectProtocol?
    private var done = false

    func end() -> Bool {
        guard !done else { return false }
        done = true
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        return true
    }
}
