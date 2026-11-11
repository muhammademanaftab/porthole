import Foundation
import LocalAuthentication
import PortholeCore
import Security

enum PasswordStore {
    static let service = OneApp.bundleID

    static let defaults: UserDefaults = Bundle.main.bundleIdentifier == service ? .standard : UserDefaults(suiteName: service) ?? .standard

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    static func password(for address: String) -> String? {
        guard let key = savedPasswordKey(address) else { return nil }
        return KeychainCache.read(key)
    }

    @discardableResult
    static func save(_ password: String, for address: String) -> Bool {
        guard let key = savedPasswordKey(address) else { return false }
        return KeychainCache.write(key, value: password, label: "Porthole host \(address)")
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

    private static func secretKey(_ hostID: String) -> String { "paired:\(hostID)" }

    static func secret(forHost hostID: String) -> String? {
        KeychainCache.read(secretKey(hostID))
    }

    @discardableResult
    static func savePairing(hostID: String, name: String, address: String, secret: String) -> Bool {
        guard KeychainCache.write(secretKey(hostID), value: secret, label: "Porthole pairing with \(name)") else { return false }
        var t = trust
        t.remember(id: hostID, name: name, address: address)
        trust = t
        return true
    }

    static func forgetPairing(hostID: String) {
        KeychainCache.delete(secretKey(hostID))
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

    static func base(_ key: String) -> [String: Any] { query(key) }
}

enum KeychainCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [String: String] = [:]
    nonisolated(unsafe) private static var warming = false
    nonisolated(unsafe) static var mainMayPrompt = true

    private static func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    static var nonInteractive: Bool { Thread.isMainThread && !locked { mainMayPrompt } }

    static func read(_ key: String) -> String? {
        if let v = locked({ values[key] }) { return v }
        let quiet = nonInteractive
        switch fetch(key, interactive: !quiet) {
        case .found(let v):
            locked { values[key] = v }
            return v
        case .needsPrompt:
            VLog.info("keychain: \(kind(key)) needs a Keychain prompt; not asking on the main thread while sharing this Mac")
            warm()
            return nil
        case .missing:
            return nil
        }
    }

    @discardableResult
    static func write(_ key: String, value: String, label: String) -> Bool {
        let ok = store(key, value: value, label: label)
        if ok { locked { values[key] = value } }
        return ok
    }

    static func delete(_ key: String) {
        SecItemDelete(PasswordStore.base(key) as CFDictionary)
        _ = locked { values.removeValue(forKey: key) }
    }

    enum Fetch { case found(String), missing, needsPrompt }

    static func fetch(_ key: String, interactive: Bool) -> Fetch {
        var q = PasswordStore.base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty { return .found(s) }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { return .needsPrompt }
        return .missing
    }

    static func store(_ key: String, value: String, label: String) -> Bool {
        let data = Data(value.utf8)
        let removed = SecItemDelete(PasswordStore.base(key) as CFDictionary)
        if removed == errSecSuccess || removed == errSecItemNotFound {
            var q = PasswordStore.base(key)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = label
            let added = SecItemAdd(q as CFDictionary, nil)
            if added == errSecSuccess { return true }
            if added != errSecDuplicateItem {
                VLog.warn("keychain: adding \(kind(key)) failed (\(added))")
                return false
            }
        } else {
            VLog.info("keychain: deleting \(kind(key)) was refused (\(removed)); updating it in place")
        }
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let updated = SecItemUpdate(PasswordStore.base(key) as CFDictionary, update as CFDictionary)
        if updated != errSecSuccess { VLog.warn("keychain: updating \(kind(key)) failed (\(updated))") }
        return updated == errSecSuccess
    }

    static func accounts() -> [(account: String, label: String)]? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: PasswordStore.service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return (account, item[kSecAttrLabel as String] as? String ?? "Porthole")
        }
    }

    static func kind(_ key: String) -> String { key.hasPrefix("paired:") ? "a pairing" : "a saved password" }

    static func warm() {
        let start = locked { () -> Bool in
            guard !warming else { return false }
            warming = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            load()
            locked { warming = false }
        }
    }

    private static func load() {
        guard let items = accounts() else {
            VLog.warn("keychain: listing the saved passwords and pairings failed")
            return
        }
        var read: [String: String] = [:]
        for item in items {
            if case .found(let value) = fetch(item.account, interactive: true) { read[item.account] = value }
        }
        locked { values.merge(read) { _, new in new } }
    }
}
