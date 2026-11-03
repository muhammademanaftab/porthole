import Foundation
import PortholeCore

enum ViewerCLI {
    static func run(_ args: [String]) -> Int32? {
        switch viewerCommand(args) {
        case .app: return nil
        case .usage(let error):
            guard let error else { print(viewerUsage); return 0 }
            fail("\(error)\n\(viewerUsage)")
            return 2
        case .request(let host): return request(host)
        case .pair(let host, let code): return pair(host, code)
        }
    }

    private static func fail(_ s: String) {
        FileHandle.standardError.write(Data("porthole-view: \(s)\n".utf8))
    }

    private static func wait<T>(_ work: @escaping @Sendable () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }

    private static func request(_ host: String) -> Int32 {
        let device = PasswordStore.device.id, name = PasswordStore.deviceName
        switch wait({ await HostDiscovery.requestPairing(address: host, device: device, name: name) }) {
        case .shown(let hostName):
            print("\(hostName) is showing a pairing code for this Mac (\(name)).")
            print("Type it with: porthole-view pair \(host) <code>")
            print("On a Mac with no screen, run porthole-host paircode there to see it.")
            return 0
        case .older:
            fail("\(host) runs an older Porthole Host without pairing requests. Choose Pair a New Viewer… on it, then porthole-view pair \(host) <code>.")
            return 1
        case .refused(let why):
            fail(why)
            return 1
        }
    }

    private static func pair(_ host: String, _ code: String) -> Int32 {
        let device = PasswordStore.device.id, name = PasswordStore.deviceName
        switch wait({ await HostDiscovery.pair(address: host, code: code, device: device, name: name) }) {
        case .paired(let secret, let id, let hostName):
            let key = hostKeyForTrust(hostID: id, address: host)
            guard PasswordStore.savePairing(hostID: key, name: hostName ?? host, address: host, secret: secret) else {
                fail("The host accepted the code but the Keychain refused to keep the pairing.")
                return 1
            }
            print("Paired with \(hostName ?? host). This Mac (\(name)) can view it from now on.")
            return 0
        case .password(let pw):
            guard PasswordStore.save(pw, for: host) else { fail("The Keychain refused to keep the password."); return 1 }
            print("\(host) runs an older Porthole Host; its password is now saved in the Keychain.")
            return 0
        case .refused(let why):
            fail(why)
            return 1
        }
    }
}
