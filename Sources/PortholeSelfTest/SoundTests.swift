import Foundation
import PortholeCore

func soundTests() {
    check("sounds: on by default with nothing stored", SoundEffects.setting(nil))
    check("sounds: a stored false turns them off", !SoundEffects.setting(false))
    check("sounds: a stored non-bool keeps the default", SoundEffects.setting("no"))
    check("sounds: the setting decides without the env flag", !SoundEffects.enabled(setting: false, environment: [:]))
    check("sounds: PORTHOLE_SOUNDS=0 silences an enabled setting", !SoundEffects.enabled(setting: true, environment: ["PORTHOLE_SOUNDS": "0"]))
    check("sounds: PORTHOLE_SOUNDS=1 plays with the setting off", SoundEffects.enabled(setting: false, environment: ["PORTHOLE_SOUNDS": "1"]))
    check("sounds: another PORTHOLE_SOUNDS value changes nothing", SoundEffects.enabled(setting: true, environment: ["PORTHOLE_SOUNDS": "yes"])
          && !SoundEffects.enabled(setting: false, environment: ["PORTHOLE_SOUNDS": "yes"]))
    check("sounds: macOS UI sound effects unset allows cues", SoundEffects.systemAllows(nil))
    check("sounds: macOS UI sound effects 0 silences cues", !SoundEffects.systemAllows(NSNumber(value: 0)))
    check("sounds: macOS UI sound effects 1 allows cues", SoundEffects.systemAllows(NSNumber(value: 1)))
    check("sounds: every cue names a system sound that exists",
          SoundCue.allCases.allSatisfy { FileManager.default.fileExists(atPath: SoundEffects.soundPath($0)) })
    check("sounds: cues are quiet", SoundCue.allCases.allSatisfy { $0.volume > 0 && $0.volume <= 0.5 })
    expect("sounds: opening and closing sound different", SoundCue.portalOpened.systemSound == SoundCue.portalClosed.systemSound, false)

    var gate = SoundGate(minimumGap: 0.15)
    let t = Date(timeIntervalSince1970: 100)
    check("sound gate: the first cue plays", gate.shouldPlay(.portalClosed, now: t))
    check("sound gate: the same cue 0.1 s later is dropped", !gate.shouldPlay(.portalClosed, now: t.addingTimeInterval(0.1)))
    check("sound gate: a different cue at once plays", gate.shouldPlay(.portalOpened, now: t.addingTimeInterval(0.1)))
    check("sound gate: the same cue 0.2 s later plays", gate.shouldPlay(.portalClosed, now: t.addingTimeInterval(0.2)))

    let s = ViewerSettings(lookup: { _ in nil })
    check("viewer settings: sound effects on by default", s.soundEffects)
    let off = ViewerSettings(lookup: { $0 == SoundEffects.settingKey ? false : nil })
    check("viewer settings: sound effects read from general.soundEffects", !off.soundEffects)
    check("viewer settings: sound effects stored under general.soundEffects", (off.stored[SoundEffects.settingKey] ?? nil) as? Bool == false)
    check("env flags: PORTHOLE_SOUNDS is documented", EnvFlags.all.contains { $0.name == "PORTHOLE_SOUNDS" })
}
