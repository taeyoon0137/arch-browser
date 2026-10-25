// Plugin secrets in the login keychain: one generic password item per key, with the service `local.arch.browser.plugin.<plugin id>` and the account `<persona id>/<key>`, so that each Persona keeps its own secrets for a plugin. Secret settings and the secrets a plugin keeps itself share the items.
import Foundation
import Security

/// Where plugin secrets live. Tests use an in-memory store, so they never touch the Keychain.
protocol PluginSecretStore: AnyObject {
    func secret(service: String, account: String) throws -> String?
    /// nil deletes the item.
    func setSecret(_ secret: String?, service: String, account: String) throws
    /// Whether the item exists. It does not read the secret, which can make macOS ask for the keychain password.
    func containsSecret(service: String, account: String) throws -> Bool
    /// Deletes the items of every plugin whose accounts start with `accountPrefix`. It reads only the items' attributes.
    func removeSecrets(accountPrefix: String) throws
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

    func removeSecrets(accountPrefix: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return }
        guard status == errSecSuccess else { throw PluginKeychainError(status: status) }
        for item in result as? [[String: Any]] ?? [] {
            guard let service = item[kSecAttrService as String] as? String, service.hasPrefix(Self.servicePrefix),
                  let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(accountPrefix) else { continue }
            try setSecret(nil, service: service, account: account)
        }
    }

    static let servicePrefix = "local.arch.browser.plugin."

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// One plugin's secrets in one Persona.
@MainActor
final class ScopedPluginSecrets: PluginSecrets {
    private let store: any PluginSecretStore
    private let service: String
    private let personaID: PersonaID

    init(store: any PluginSecretStore, pluginID: PluginID, personaID: PersonaID) {
        self.store = store
        service = PluginKeychain.servicePrefix + pluginID.rawValue
        self.personaID = personaID
    }

    func secret(forKey key: String) throws -> String? {
        try store.secret(service: service, account: account(key))
    }

    func setSecret(_ secret: String?, forKey key: String) throws {
        try store.setSecret(secret, service: service, account: account(key))
    }

    func containsSecret(forKey key: String) throws -> Bool {
        try store.containsSecret(service: service, account: account(key))
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
