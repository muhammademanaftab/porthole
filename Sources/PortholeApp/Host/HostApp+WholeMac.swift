import AppKit
import PortholeCore

@MainActor
final class WholeMacUI {
    let screens = CurtainWindows()
    lazy var curtain = CurtainController(tap: EventTapCurtain(), screens: screens)
    let prompt = WholeMacPrompt()
    var timer: Timer?
    var lastLive = 0
    var lastViewer: String?
}

extension HostApp {
    func setUpWholeMac(environment env: [String: String]) {
        let ui = wholeMacUI
        let room = host
        host.wholeMac.mode = { WholeMac.mode(stored: UserDefaults.standard.object(forKey: WholeMac.settingKey), environment: env) }
        host.wholeMac.ask = { [weak self] key, viewer in
            ui.prompt.ask(key: key, viewer: viewer, host: HTTPServer.computerName) { allow in room.answerWholeMac(key, allow: allow) }
            self?.refresh()
        }
        host.wholeMac.settled = { key in ui.prompt.close(key) }
        ui.screens.skip = { [weak room] in
            guard let stage = room?.stage, stage.matched.isEmpty else { return nil }
            return stage.displayID
        }
        ui.curtain.onEscape = { [weak self] in
            Log.info("curtain: taken back on this Mac with \(CurtainFilter.escapeHint)")
            ui.curtain.escape()
            self?.refresh()
        }
        host.wholeMac.liveChanged = { live, viewer in
            ui.lastLive = live
            ui.lastViewer = viewer
            Self.applyCurtain(ui, environment: env)
        }
        Log.info("whole mac: \(host.wholeMac.mode().rawValue); curtain \(CurtainSetting.enabled(stored: UserDefaults.standard.object(forKey: CurtainSetting.settingKey), environment: env) ? "on" : "off")")
    }

    static func applyCurtain(_ ui: WholeMacUI, environment env: [String: String]) {
        let enabled = CurtainSetting.enabled(stored: UserDefaults.standard.object(forKey: CurtainSetting.settingKey), environment: env)
        let wasUp = ui.curtain.isUp
        ui.curtain.update(enabled: enabled, liveScreens: ui.lastLive, viewer: ui.lastViewer, now: ProcessInfo.processInfo.systemUptime)
        if ui.curtain.isUp, ui.timer == nil {
            ui.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    ui.curtain.tick(now: ProcessInfo.processInfo.systemUptime)
                    if !ui.curtain.isUp { ui.timer?.invalidate(); ui.timer = nil }
                }
            }
        }
        if !ui.curtain.isUp { ui.timer?.invalidate(); ui.timer = nil }
        if wasUp != ui.curtain.isUp {
            Log.info(ui.curtain.isUp ? "curtain: raised (blocking input \(ui.curtain.isBlocking))" : "curtain: lifted (\(ui.curtain.lastLift?.rawValue ?? "?"))")
        }
    }

    func liftCurtain() {
        wholeMacUI.curtain.shutdown()
    }
}
