import AppKit
import PortholeCore

@MainActor
final class WholeMacUI {
    let prompt = WholeMacPrompt()
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
        Log.info("whole mac: \(host.wholeMac.mode().rawValue)")
    }
}
