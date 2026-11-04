import Foundation
import PortholeCore
import Security

enum PasswordStore {
    static let service = "io.github.muhammademanaftab.porthole.view"

    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == service ? .standard : UserDefaults(suiteName: service) ?? .standard

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    static func password(for address: String) -> String? {
        guard let key = savedPasswordKey(address) else { return nil }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let pw = String(data: data, encoding: .utf8), !pw.isEmpty {
            return pw
        }
        let d = UserDefaults.standard
        guard let legacyHost = d.string(forKey: "host"), savedPasswordKey(legacyHost) == key else { return nil }
        return d.string(forKey: "password")
    }

    @discardableResult
    static func save(_ password: String, for address: String) -> Bool {
        guard let key = savedPasswordKey(address) else { return false }
        SecItemDelete(query(key) as CFDictionary)
        var q = query(key)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "Porthole host \(address)"
        let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        if ok { UserDefaults.standard.removeObject(forKey: "password") }
        return ok
    }

    static var knownHosts: [KnownHost] {
        get {
            guard let data = defaults.data(forKey: "knownHosts") else { return [] }
            return (try? JSONDecoder().decode([KnownHost].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "knownHosts") }
    }

    static var trust: ViewerTrust {
        get { ViewerTrust.decode(defaults.data(forKey: "pairedHosts")) }
        set { defaults.set(newValue.encoded, forKey: "pairedHosts") }
    }

    static var device: DeviceIdentity { DeviceIdentity.loadOrCreate(in: portholeSupportDirectory()) }

    static var deviceName: String { cleanDeviceName(Host.current().localizedName ?? shortHostName(ProcessInfo.processInfo.hostName)) }

    private static func secretQuery(_ hostID: String) -> [String: Any] {
        query("paired:\(hostID)")
    }

    static func secret(forHost hostID: String) -> String? {
        var q = secretQuery(hostID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func savePairing(hostID: String, name: String, address: String, secret: String) -> Bool {
        SecItemDelete(secretQuery(hostID) as CFDictionary)
        var q = secretQuery(hostID)
        q[kSecValueData as String] = Data(secret.utf8)
        q[kSecAttrLabel as String] = "Porthole pairing with \(name)"
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        var t = trust
        t.remember(id: hostID, name: name, address: address)
        trust = t
        return true
    }

    static func forgetPairing(hostID: String) {
        SecItemDelete(secretQuery(hostID) as CFDictionary)
        var t = trust
        t.forget(id: hostID)
        trust = t
    }

    static func credential(for address: String) -> (ViewerCredential, hostID: String?)? {
        if let paired = trust.host(forAddress: address), let secret = secret(forHost: paired.id) {
            return (.device(id: device.id, secret: secret), paired.id)
        }
        return password(for: address).map { (.password($0), nil) }
    }

    static func hasAccess(_ host: DiscoveredHost, address: String) -> Bool {
        credential(for: address) != nil
    }
}
