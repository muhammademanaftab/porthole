import AppKit
import CryptoKit
import PortholeCore

@MainActor
final class TileManager {
    var onActivate: ((UInt32) -> Void)?
    var onQuit: ((UInt32) -> Void)?
    private var tokens: [UInt32: String] = [:]
    private var running: [UInt32: NSRunningApplication] = [:]
    private var observer: NSObjectProtocol?
    private let builder = TileBuilder()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porthole/Tiles", isDirectory: true)
    }

    static var helper: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(TileBundle.executable)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(TileBundle.executable),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    init() {
        let me = String(ProcessInfo.processInfo.processIdentifier)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(TileEvent.notification), object: me, queue: .main) { [weak self] note in
            guard let event = TileEvent(userInfo: note.userInfo) else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: TileEvent) {
        guard let win = tokens.first(where: { $0.value == event.token })?.key else { return }
        switch event.kind {
        case .activate: onActivate?(win)
        case .quit:
            tokens[win] = nil
            running[win] = nil
            onQuit?(win)
        }
    }

    func show(win: UInt32, app: String, icon: Data?) {
        remove(win)
        guard let helper = Self.helper else { return }
        let token = UUID().uuidString
        tokens[win] = token
        let dir = Self.directory
        let builder = self.builder
        Task.detached {
            do {
                let url = try await builder.prepare(app: app, icon: icon, helper: helper, in: dir)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.createsNewApplicationInstance = true
                config.addsToRecentItems = false
                config.arguments = TileArguments.make(token: token, viewer: ProcessInfo.processInfo.processIdentifier)
                let launched = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                await MainActor.run {
                    guard self.tokens[win] == token else { launched.terminate(); return }
                    self.running[win] = launched
                }
            } catch {
                NSLog("Porthole: no Dock tile for \(app): \(error.localizedDescription)")
            }
        }
    }

    func remove(_ win: UInt32) {
        tokens[win] = nil
        running.removeValue(forKey: win)?.terminate()
    }

    func removeAll() {
        for win in Array(tokens.keys) { remove(win) }
    }
}

actor TileBuilder {
    func prepare(app: String, icon: Data?, helper: URL, in dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = dir.appendingPathComponent(TileBundle.fileName(forApp: app), isDirectory: true)
        let exe = try Data(contentsOf: helper)
        let digest = SHA256.hash(data: exe).map { String(format: "%02x", $0) }.joined()
        let plist = TileBundle.infoPlistData(forApp: app, helperDigest: digest) ?? Data()
        let icns = icon.flatMap(ICNS.make(fromPNG:))
        let paths = (plist: "Contents/Info.plist", exe: "Contents/MacOS/\(TileBundle.executableName(forApp: app))",
                     icon: "Contents/Resources/\(TileBundle.iconFile).icns")
        func same(_ path: String, _ data: Data?) -> Bool {
            (try? Data(contentsOf: bundle.appendingPathComponent(path))) == data
        }
        if same(paths.plist, plist), same(paths.icon, icns), Self.isSigned(bundle) {
            return bundle
        }
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        for sub in ["Contents/MacOS", "Contents/Resources"] {
            try fm.createDirectory(at: staging.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try plist.write(to: staging.appendingPathComponent(paths.plist))
        try exe.write(to: staging.appendingPathComponent(paths.exe))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent(paths.exe).path)
        if let icns { try icns.write(to: staging.appendingPathComponent(paths.icon)) }
        guard Self.run("/usr/bin/codesign", ["--force", "--sign", "-", staging.path]) else {
            throw NSError(domain: "Porthole", code: 5, userInfo: [NSLocalizedDescriptionKey: "codesign failed for \(bundle.lastPathComponent)"])
        }
        if fm.fileExists(atPath: bundle.path) {
            _ = try fm.replaceItemAt(bundle, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: bundle)
        }
        return bundle
    }

    private static func isSigned(_ bundle: URL) -> Bool {
        run("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
    }

    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
