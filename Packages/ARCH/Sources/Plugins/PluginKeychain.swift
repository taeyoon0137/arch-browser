// Plugin secrets in the login keychain: one generic password item per key, with the service `xyz.taeyoon.arch.plugin.<plugin id>` and the account `<persona id>/<key>`, so that each Persona keeps its own secrets for a plugin. Secret settings and the secrets a plugin keeps itself share the items.
import Foundation
import Security

/// Where plugin secrets live. The manager's tests use an in-memory store, so they never touch the Keychain.
protocol PluginSecretStore: AnyObject {
    func secret(service: String, account: String) throws -> String?
    /// nil deletes the item.
    func setSecret(_ secret: String?, service: String, account: String) throws
    /// Whether the item exists. It does not read the secret, which can make macOS ask for the keychain password.
    func containsSecret(service: String, account: String) throws -> Bool
    /// Deletes the items whose accounts start with `accountPrefix`: the service's, or for nil those of every plugin. It reads only the items' attributes.
    func removeSecrets(service: String?, accountPrefix: String) throws
}

/// Accessible when unlocked, not synchronizable, in the login keychain, as the AI module keeps provider keys.
final class PluginKeychain: PluginSecretStore {
    func secret(service: String, account: String) throws -> String? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound: return nil
        default: throw PluginKeychainError(status: status)
        }
    }

    func setSecret(_ secret: String?, service: String, account: String) throws {
        let query = Self.query(service: service, account: account)
        guard let secret else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PluginKeychainError(status: status) }
            return
        }
        let data = Data(secret.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Arch plugin \(service.dropFirst(Self.servicePrefix.count)): \(account)"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PluginKeychainError(status: status) }
    }

    func containsSecret(service: String, account: String) throws -> Bool {
        var query = Self.query(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw PluginKeychainError(status: status)
        }
    }

    func removeSecrets(service: String?, accountPrefix: String) throws {
        var query = Self.query(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return }
        guard status == errSecSuccess else { throw PluginKeychainError(status: status) }
        for item in result as? [[String: Any]] ?? [] {
            guard let itemService = item[kSecAttrService as String] as? String, itemService.hasPrefix(Self.servicePrefix),
                  let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(accountPrefix) else { continue }
            try setSecret(nil, service: itemService, account: account)
        }
    }

    /// The service and account of each item whose service starts with `prefix`. It reads only the items' attributes.
    func items(withServicePrefix prefix: String) throws -> [(service: String, account: String)] {
        var query = Self.query(service: nil, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess else { throw PluginKeychainError(status: status) }
        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let service = item[kSecAttrService as String] as? String, service.hasPrefix(prefix),
                  let account = item[kSecAttrAccount as String] as? String else { return nil }
            return (service, account)
        }
    }

    static let servicePrefix = "xyz.taeyoon.arch.plugin."

    /// The service's item for `account`, or all of its items for nil, and the items of every service for a nil service.
    private static func query(service: String?, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: false,
        ]
        query[kSecAttrService as String] = service
        query[kSecAttrAccount as String] = account
        return query
    }
}

/// One plugin's secrets in one Persona. Those of a plugin instance's context only read once the instance stops, and writes throw `PluginError.stopped`.
@MainActor
final class ScopedPluginSecrets: PluginSecrets {
    private let store: any PluginSecretStore
    private let service: String
    private let personaID: PersonaID
    private var hasEnded = false

    init(store: any PluginSecretStore, pluginID: PluginID, personaID: PersonaID) {
        self.store = store
        service = PluginKeychain.servicePrefix + pluginID.rawValue
        self.personaID = personaID
    }

    /// Called when the instance whose context holds the secrets stops.
    func end() {
        hasEnded = true
    }

    func secret(forKey key: String) throws -> String? {
        try store.secret(service: service, account: account(key))
    }

    func setSecret(_ secret: String?, forKey key: String) throws {
        guard !hasEnded else { throw PluginError.stopped }
        try store.setSecret(secret, service: service, account: account(key))
    }

    func containsSecret(forKey key: String) throws -> Bool {
        try store.containsSecret(service: service, account: account(key))
    }

    /// Deletes every secret of the plugin in the Persona, when the user removes the plugin.
    func removeAll() throws {
        try store.removeSecrets(service: service, accountPrefix: Self.accountPrefix(of: personaID))
    }

    /// The start of the accounts of every secret in the Persona.
    nonisolated static func accountPrefix(of personaID: PersonaID) -> String {
        personaID.uuidString + "/"
    }

    private func account(_ key: String) -> String {
        Self.accountPrefix(of: personaID) + key
    }
}

/// A Keychain failure, described by the system's message for its status. It never contains the secret.
struct PluginKeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}
