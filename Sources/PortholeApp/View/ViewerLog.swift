import AppKit
import PortholeCore

enum VLog {
    static let writer = LogWriter(role: "viewer", echo: false, verbose: verboseFromEnvironment(ProcessInfo.processInfo.environment))

    static func info(_ s: String) { writer.write(LogLevel.infer(s), .viewer, s) }
    static func warn(_ s: String) { writer.write(.warn, .viewer, s) }
    static func flush() { writer.flush() }
}

enum ViewerRecents {
    static func opened(_ info: WindowInfo, host: String, name: String) {
        let entry = RecentPortal(host: host, hostName: name, windowID: info.id, title: info.title, app: info.app, bundle: info.bundle, time: Date())
        RecentPortals.record(entry, in: portholeSupportDirectory())
        VLog.info("portal opened: window \(info.id) of \(info.app) on \(name) (\(host))")
    }
}

@MainActor
enum Sounds {
    static var gate = SoundGate()
    static var cache: [SoundCue: NSSound] = [:]

    static var enabled: Bool {
        let ui = UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled")
        return SoundEffects.enabled(setting: ViewerPrefs.current.soundEffects) && SoundEffects.systemAllows(ui)
    }

    static func play(_ cue: SoundCue) {
        guard enabled, gate.shouldPlay(cue, now: Date()) else { return }
        guard let sound = cache[cue] ?? NSSound(contentsOfFile: SoundEffects.soundPath(cue), byReference: true) else { return }
        cache[cue] = sound
        sound.volume = cue.volume
        sound.stop()
        sound.play()
        VLog.info("sound cue \(cue.rawValue)")
    }
}
