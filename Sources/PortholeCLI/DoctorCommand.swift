import CoreGraphics
import Foundation
import Network
import PortholeCore

enum DoctorCommand {
    static func run(_ o: DoctorOptions) -> Int32 {
        if o.windows { return windows(json: o.json) }
        print(text(quick: o.quick))
        return 0
    }

    static func header() -> String {
        "Porthole doctor: \(SystemFacts.computerName), \(SystemFacts.model), \(SystemFacts.macOS), porthole \(SystemFacts.bundleVersion ?? portholeVersion), \(LogTime.format(Date(), milliseconds: false))"
    }

    static func text(quick: Bool) -> String {
        renderDoctor(checks(quick: quick), header: header())
    }

    static func checks(quick: Bool) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let hostApp = Tools.app(bundleID: Tools.hostBundleID, name: "Porthole Host")
        let viewerApp = Tools.app(bundleID: Tools.viewerBundleID, name: "Porthole")
        let config = savedConfig()
        let viewerDefaults = viewerDefaults()
        let viewerTrust = ViewerTrust.decode(viewerDefaults?.data(forKey: "pairedHosts"))
        let recents = RecentPortals.load(in: Paths.support)
        var roles: [String] = []
        if config != nil || hostApp != nil { roles.append("host" + (hostApp.map { " (\($0.path))" } ?? "")) }
        if viewerApp != nil || !viewerTrust.hosts.isEmpty || !recents.isEmpty { roles.append("viewer" + (viewerApp.map { " (\($0.path))" } ?? "")) }
        out.append(DoctorCheck("This Mac", "roles", roles.isEmpty ? .warn : .info, roles.isEmpty ? "neither Porthole Host nor Porthole is installed or has run here" : roles.joined(separator: "\n")))

        let isHost = config != nil || hostApp != nil
        if isHost { out += hostChecks(config: config, quick: quick) }

        out += networkChecks(status: isHost ? cachedStatus : nil)
        out += pairingChecks(viewerTrust: viewerTrust, isHost: isHost)
        if !recents.isEmpty {
            out.append(DoctorCheck("Viewer", "recent portals", .info, "\(recents.count); newest \(recents[0].app) on \(recents[0].hostName), \(formatDuration(Date().timeIntervalSince(recents[0].time))) ago"))
        }
        let problems = recentProblems(readLogs(), limit: 20)
        out.append(DoctorCheck("Logs", "recent problems", problems.isEmpty ? .ok : .info,
                               "last 20 warnings/errors in \(Paths.logs.path), by event:\n" + renderProblems(problems)))
        return out
    }

    nonisolated(unsafe) static var cachedStatus: [String: Any]?

    static func hostChecks(config: HostConfig?, quick: Bool) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let pids = Procs.hosts()
        let status = pids.isEmpty ? nil : LocalHost.status()
        cachedStatus = status
        out.append(hostRunningCheck(status: status, pids: pids))
        if let status {
            let sr = status["screenRecording"] as? Bool ?? false, ax = status["accessibility"] as? Bool ?? false
            out.append(DoctorCheck("Host", "screen recording", sr ? .ok : .fail,
                                   sr ? "granted (as the host sees it)" : "missing: System Settings > Privacy & Security > Screen & System Audio Recording, turn on Porthole Host"))
            out.append(DoctorCheck("Host", "accessibility", ax ? .ok : .fail,
                                   ax ? "granted (as the host sees it)" : "missing: System Settings > Privacy & Security > Accessibility, turn on Porthole Host; typing and clicks won't arrive"))
            if status["screenLocked"] as? Bool == true {
                out.append(DoctorCheck("Host", "screen", .warn, "locked: a locked screen hides every window from capture"))
            }
        } else if !pids.isEmpty {
            out.append(DoctorCheck("Host", "permissions", .info, "unknown (the host didn't answer the local status request)"))
        }
        out.append(watchdogCheck(status: status))
        let http = Int(config?.httpPort ?? HostConfig.defaultHTTPPort), lk = config?.livekitPort ?? HostConfig.defaultLiveKitPort
        for (name, port) in [("web port", http), ("LiveKit port", lk)] {
            let up = portListening(port)
            let st: CheckStatus = up == !pids.isEmpty ? (up ? .ok : .fail) : (up ? .warn : .fail)
            let detail = up ? (pids.isEmpty ? "\(port) is taken by something other than Porthole Host" : "\(port) listening")
                : "\(port) not listening" + (pids.isEmpty ? " (the host isn't running)" : "")
            out.append(DoctorCheck("Host", name, st, detail))
        }
        out.append(bonjourCheck(status: status, quick: quick))
        if !pids.isEmpty { out.append(stageCheck(status?["stage"] as? [String: Any])) }
        if let shared = status?["shared"] as? [[String: Any]] {
            let lines = shared.map { w in "\(w["id"] as? Int ?? 0)  \(w["app"] as? String ?? "?") — \(w["title"] as? String ?? "")  (\(w["viewers"] as? Int ?? 0) viewer(s))" }
            out.append(DoctorCheck("Host", "shared windows", .info, lines.isEmpty ? "none" : lines.joined(separator: "\n")))
        }
        return out
    }

    static func watchdogCheck(status: [String: Any]?) -> DoctorCheck {
        let label = "gui/\(getuid())/\(LaunchAgent.label)"
        let loaded = Shell.run("/bin/launchctl", ["print", label], timeout: 4)?.status == 0
        let dogs = Procs.watchdogs()
        var parts: [String] = []
        if let s = status?["watchdog"] as? String { parts.append("agent \(s) (ServiceManagement)") }
        parts.append(loaded ? "loaded in launchd" : "not loaded in launchd")
        parts.append(dogs.isEmpty ? "no watchdog process" : "watchdog pid \(dogs.map(String.init).joined(separator: ", "))")
        if let watched = status?["watched"] as? Bool { parts.append(watched ? "watching this run" : "not watching this run (Keep running off or PORTHOLE_WATCHDOG=0)") }
        let enabled = (status?["watchdog"] as? String) == "enabled" || loaded
        let st: CheckStatus = enabled && !dogs.isEmpty ? .ok : (status?["watched"] as? Bool == false ? .info : .warn)
        return DoctorCheck("Host", "watchdog", st, parts.joined(separator: ", "))
    }

    static func bonjourCheck(status: [String: Any]?, quick: Bool) -> DoctorCheck {
        let advertised = status?["bonjour"] as? String
        guard !quick else {
            return DoctorCheck("Host", "Bonjour", advertised == nil ? .info : .ok, advertised.map { "advertising \($0) (browse skipped with --quick)" } ?? "browse skipped with --quick")
        }
        let found = browse(seconds: 4)
        let id = savedIdentity()
        let mine = found.first { ($0.txt["id"] != nil && $0.txt["id"] == id) || $0.name == SystemFacts.computerName }
        let others = found.filter { $0.name != mine?.name }.map(\.name)
        var detail = advertised.map { "advertising \($0)" } ?? "the host reports no advertisement"
        detail += mine != nil ? "; visible on the network as \"\(mine!.name)\"" : "; not visible in a 4 s browse"
        if !others.isEmpty { detail += "\nother Porthole hosts nearby: \(others.joined(separator: ", "))" }
        let st: CheckStatus = mine != nil ? .ok : (status == nil ? .info : .warn)
        return DoctorCheck("Host", "Bonjour", st, detail)
    }

    static func browse(seconds: Double) -> [(name: String, txt: [String: String])] {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: portholeServiceType, domain: nil), using: .tcp)
        let q = DispatchQueue(label: "porthole.doctor.browse")
        nonisolated(unsafe) var found: [(String, [String: String])] = []
        b.browseResultsChangedHandler = { results, _ in
            found = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint else { return nil }
                if case .bonjour(let txt) = r.metadata { return (name, txt.dictionary) }
                return (name, [:])
            }
        }
        b.start(queue: q)
        Thread.sleep(forTimeInterval: seconds)
        b.cancel()
        return q.sync { found.map { (name: $0.0, txt: $0.1) } }
    }

    static func networkChecks(status: [String: Any]?) -> [DoctorCheck] {
        let (cli, ts) = tailscaleStatus()
        guard let cli else { return [DoctorCheck("Network", "Tailscale", .warn, "not installed; only Macs on this local network can be reached")] }
        guard let ts else { return [DoctorCheck("Network", "Tailscale", .warn, "\(cli) didn't answer status --json")] }
        guard ts.running else { return [DoctorCheck("Network", "Tailscale", .warn, "installed but not running (BackendState isn't Running)")] }
        let online = ts.peers.filter(\.online)
        let macs = ts.probeTargets
        var detail = "running, this Mac \(ts.selfIPv4 ?? "has no tailnet IPv4")"
        detail += "; \(online.count) peer(s) online, \(macs.count) of them Macs"
        if let hostIP = status?["tailscaleIP"] as? String, hostIP != ts.selfIPv4 { detail += "\nthe host sees tailnet IP \(hostIP)" }
        return [DoctorCheck("Network", "Tailscale", ts.selfIPv4 == nil ? .warn : .ok, detail)]
    }

    static func pairingChecks(viewerTrust: ViewerTrust, isHost: Bool) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        if let id = savedIdentity() { out.append(DoctorCheck("Pairing", "device ID", .info, "\(shortID(id)) (porthole devices prints it in full)")) }
        if isHost {
            let paired = TrustStore(directory: Paths.support).devices()
            let f = ISO8601DateFormatter()
            out.append(DoctorCheck("Pairing", "may view this Mac", .info,
                                   paired.isEmpty ? "no Macs" : paired.map { "\(shortID($0.id))  \($0.name)  (paired \(f.string(from: $0.pairedAt)))" }.joined(separator: "\n")))
        }
        if !viewerTrust.hosts.isEmpty {
            out.append(DoctorCheck("Pairing", "this Mac may view", .info,
                                   viewerTrust.hosts.map { "\(shortID($0.id))  \($0.name)  at \($0.addresses.joined(separator: ", "))" }.joined(separator: "\n")))
        }
        return out
    }

    static func displays(stageID: UInt32?) -> [DisplayRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).map { id in
            let stage = id == stageID || (CGDisplayVendorNumber(id) == 0x504F && CGDisplayModelNumber(id) == 0x5448)
            return DisplayRect(id: id, bounds: CGDisplayBounds(id), isStage: stage)
        }
    }

    static func windows(json: Bool) -> Int32 {
        let status = Procs.hosts().isEmpty ? nil : LocalHost.status()
        let stageID = ((status?["stage"] as? [String: Any])?["display"] as? Int).map { UInt32($0) }
        let shows = displays(stageID: stageID)
        let raw = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var rows: [[String: Any]] = []
        for w in raw {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary), rect.width >= 40, rect.height >= 40 else { continue }
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let place = placeWindow(rect, displays: shows)
            var row: [String: Any] = ["id": w[kCGWindowNumber as String] as? Int ?? 0, "app": w[kCGWindowOwnerName as String] as? String ?? "?",
                                      "pid": w[kCGWindowOwnerPID as String] as? Int ?? 0, "onscreen": onscreen,
                                      "bounds": [rect.origin.x, rect.origin.y, rect.width, rect.height],
                                      "placement": place.label, "flagged": onscreen && place.flagged]
            if let t = w[kCGWindowName as String] as? String, !t.isEmpty { row["title"] = t }
            rows.append(row)
        }
        if json {
            printJSON(["displays": shows.map { ["id": Int($0.id), "stage": $0.isStage, "bounds": [$0.bounds.origin.x, $0.bounds.origin.y, $0.bounds.width, $0.bounds.height]] },
                       "windows": rows])
            return 0
        }
        print("Displays")
        for d in shows {
            print("  \(d.id)\(d.isStage ? " (Porthole Stage)" : "")  \(Int(d.bounds.origin.x)),\(Int(d.bounds.origin.y)) \(Int(d.bounds.width))x\(Int(d.bounds.height))")
        }
        print("\nWindows (layer 0; titles need Screen Recording for this terminal)")
        let sorted = rows.sorted { ($0["flagged"] as? Bool ?? false) && !($1["flagged"] as? Bool ?? false) }
        for r in sorted {
            let b = r["bounds"] as? [CGFloat] ?? []
            let where_ = b.count == 4 ? "\(Int(b[0])),\(Int(b[1])) \(Int(b[2]))x\(Int(b[3]))" : "?"
            let mark = (r["flagged"] as? Bool ?? false) ? "!" : " "
            let state = (r["onscreen"] as? Bool ?? false) ? r["placement"] as? String ?? "" : "hidden or minimized"
            print("\(mark) \(String(r["id"] as? Int ?? 0).padding(toLength: 7, withPad: " ", startingAt: 0)) \((r["app"] as? String ?? "?").padding(toLength: 22, withPad: " ", startingAt: 0)) \(where_.padding(toLength: 22, withPad: " ", startingAt: 0)) \(state)\((r["title"] as? String).map { "  \"\($0)\"" } ?? "")")
        }
        let flagged = rows.filter { $0["flagged"] as? Bool ?? false }.count
        print("\n\(flagged == 0 ? "No on-screen window is off-display or on the Stage." : "\(flagged) on-screen window(s) are off-display or on the Stage.")")
        return 0
    }
}
