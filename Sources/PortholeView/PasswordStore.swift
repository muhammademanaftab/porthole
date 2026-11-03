import Foundation
import PortholeCore
import Security

enum PasswordStore {
    static let service = "io.github.muhammademanaftab.porthole.view"

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
            guard let data = UserDefaults.standard.data(forKey: "knownHosts") else { return [] }
            return (try? JSONDecoder().decode([KnownHost].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "knownHosts") }
    }
}
