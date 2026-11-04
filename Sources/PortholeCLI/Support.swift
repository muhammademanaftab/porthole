import AppKit
import Darwin
import Foundation
import PortholeCore
import SystemConfiguration

enum Paths {
    static var support: URL { portholeSupportDirectory() }
    static var logs: URL { LogFiles.directory() }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var marker: URL { support.appendingPathComponent("exit-marker") }
    static var watchdogPid: URL { support.appendingPathComponent("watchdog.pid") }
    static var heartbeat: URL { support.appendingPathComponent("heartbeat") }
    static var crashReports: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports") }

    static var executable: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    static var containingApp: URL? {
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

func say(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }

func fail(_ s: String) { say("porthole: \(s)") }

func printJSON(_ obj: Any, pretty: Bool = true) {
    let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: opts) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func readText(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

func savedConfig() -> HostConfig? {
    (try? Data(contentsOf: Paths.config)).flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }
}

func savedIdentity() -> String? {
    (try? Data(contentsOf: Paths.support.appendingPathComponent(DeviceIdentity.fileName)))
        .flatMap { try? JSONDecoder().decode(DeviceIdentity.self, from: $0) }?.id
}

func knownSecrets() -> [String] {
    var out: [String] = []
    if let c = savedConfig() { out += [c.password, c.apiKey, c.apiSecret] }
    if let s = LocalSecret.read(in: Paths.support) { out.append(s) }
    return out
}

enum LocalHost {
    static func status(timeout: TimeInterval = 3) -> [String: Any]? {
        guard let config = savedConfig(), let url = localURL(port: config.httpPort, path: "/local/status") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(LocalSecret.read(in: Paths.support) ?? "", forHTTPHeaderField: localRouteHeader)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: [String: Any]?
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200, let data {
                out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return out
    }
}

enum Procs {
    static func all() -> [(pid: Int32, path: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        return pids.prefix(Int(max(n, 0))).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
            return (pid, String(cString: buf))
        }
    }

    static func arguments(_ pid: pid_t) -> ProcessArguments {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        let none = ProcessArguments(arguments: [], environment: [:])
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return none }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return none }
        return ProcessArguments(procargs: Array(buf.prefix(size)))
    }

    static func named(_ name: String) -> [(pid: Int32, path: String)] {
        all().filter { URL(fileURLWithPath: $0.path).lastPathComponent == name }
    }

    static func hosts() -> [Int32] {
        named("porthole-host").map(\.pid).filter { arguments($0).isHostApp }
    }

    static func watchdogs() -> [Int32] {
        named("porthole-host").map(\.pid).filter { arguments($0).isWatchdog }
    }

    static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

func portListening(_ port: Int, host: String = "127.0.0.1", timeout: Int32 = 500) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET, host, &addr.sin_addr)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if r == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, timeout) == 1 else { return false }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0
}

enum Tools {
    static let hostBundleID = "io.github.muhammademanaftab.porthole"
    static let viewerBundleID = "io.github.muhammademanaftab.porthole.view"

    static func app(bundleID: String, name: String, accept: (URL) -> Bool = { _ in true }) -> URL? {
        var candidates: [URL] = []
        if let here = Paths.containingApp {
            candidates.append(here)
            candidates.append(here.deletingLastPathComponent().appendingPathComponent("\(name).app"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/\(name).app"))
        if let ls = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { candidates.append(ls) }
        return candidates.first { accept($0) && Bundle(url: $0)?.bundleIdentifier == bundleID }
    }

    static var oneApp: URL? { app(bundleID: hostBundleID, name: OneApp.appName, accept: OneApp.isInstalledOneApp) }

    static var oldHostApp: URL? {
        OneApp.oldHostApps().first { Bundle(url: $0)?.bundleIdentifier == hostBundleID }
    }

    static var oldViewerApp: URL? { app(bundleID: viewerBundleID, name: OneApp.appName) }

    static func locate(_ tool: CLITool) -> URL? {
        let sibling = Paths.executable.deletingLastPathComponent().appendingPathComponent(tool.rawValue)
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        let candidates = [oneApp?.appendingPathComponent("Contents/MacOS/\(CLITool.host.rawValue)"),
                          (tool == .host ? oldHostApp : oldViewerApp)?.appendingPathComponent("Contents/MacOS/\(tool.rawValue)")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func exec(_ tool: CLITool, _ args: [String]) -> Int32 {
        guard let exe = locate(tool) else {
            fail("Porthole isn't installed on this Mac (looked next to porthole, in /Applications and with Launch Services).")
            return 1
        }
        let argv = [exe.path] + args
        var cargs = argv.map { strdup($0) } + [nil]
        execv(exe.path, &cargs)
        fail("couldn't run \(exe.path): \(String(cString: strerror(errno)))")
        return 1
    }
}

enum SystemFacts {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static var model: String { sysctlString("hw.model") ?? "Mac" }
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" + (sysctlString("kern.osversion").map { " (\($0))" } ?? "")
    }
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? shortHostName(ProcessInfo.processInfo.hostName)
    }
    static var bundleVersion: String? {
        Paths.containingApp.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    }
}

let tailscaleCLIs = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

func tailscaleStatus() -> (cli: String?, status: TailscaleStatus?) {
    guard let exe = tailscaleCLIs.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return (nil, nil) }
    guard let r = Shell.run(exe, ["status", "--json"], timeout: 5) else { return (exe, nil) }
    return (exe, TailscaleStatus.parse(Data(r.out.utf8)))
}

func appDefaults() -> UserDefaults? {
    Bundle.main.bundleIdentifier == Tools.hostBundleID ? .standard : UserDefaults(suiteName: Tools.hostBundleID)
}

func savedHosting() -> Bool? {
    appDefaults()?.object(forKey: HostingSwitch.settingKey) as? Bool
}

func viewerDefaults() -> UserDefaults? {
    Bundle.main.bundleIdentifier == Tools.viewerBundleID ? .standard : UserDefaults(suiteName: Tools.viewerBundleID)
}

func readLogs(roles: [String] = LogFiles.roles) -> [LogLine] {
    LogFiles.readAll(in: Paths.logs, roles: roles)
}
