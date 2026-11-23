// Plugin secrets in the login keychain: one generic password item per key, with the service `xyz.taeyoon.arch.plugin.<plugin id>` and the account `<persona id>/<key>`, so that each Persona keeps its own secrets for a plugin, up to 64 of at most 16 KB each. Secret settings and the secrets a plugin keeps itself share the items.
import Foundation
import Security

/// Where plugin secrets live. The manager's tests use an in-memory store, so they never touch the Keychain. `ScopedPluginSecrets` reads and writes secrets on a queue of its own.
protocol PluginSecretStore: AnyObject, Sendable {
    func secret(service: String, account: String) throws -> String?
    /// nil deletes the item.
    func setSecret(_ secret: String?, service: String, account: String) throws
    /// Whether the item exists. It does not read the secret, which can make macOS ask for the keychain password.
    func containsSecret(service: String, account: String) throws -> Bool
    /// How many of the service's items have accounts that start with `accountPrefix`. It reads only the items' attributes.
    func secretCount(service: String, accountPrefix: String) throws -> Int
    /// Deletes the items whose accounts start with `accountPrefix`: the service's, or for nil those of every plugin. It reads only the items' attributes.
    func removeSecrets(service: String?, accountPrefix: String) throws
}

/// Accessible when unlocked, not synchronizable, in the login keychain, as the AI module keeps provider keys.
final class PluginKeychain: PluginSecretStore {
    /// The start of the services of plugin secrets in earlier builds, from which `PluginIdentifierMigration` moves the items. The tests give their own.
    let previousServicePrefix: String

    init(previousServicePrefix: String = PluginKeychain.previousServicePrefix) {
        self.previousServicePrefix = previousServicePrefix
    }

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

    func secretCount(service: String, accountPrefix: String) throws -> Int {
        var query = Self.query(service: service, account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return 0 }
        guard status == errSecSuccess else { throw PluginKeychainError(status: status) }
        return (result as? [[String: Any]] ?? []).filter { ($0[kSecAttrAccount as String] as? String)?.hasPrefix(accountPrefix) == true }.count
    }

    /// Items under `previousServicePrefix` that the migration has not moved yet, as when the user refused the keychain prompt, count by the service they move to, so that they go with their plugin or Persona rather than come back under the new service at a later launch.
    func removeSecrets(service: String?, accountPrefix: String) throws {
        for item in try items(withServicePrefix: "") where item.account.hasPrefix(accountPrefix) {
            let current = item.service.hasPrefix(previousServicePrefix)
                ? PluginIdentifierMigration.movedService(item.service, from: previousServicePrefix, to: Self.servicePrefix) : item.service
            guard current.hasPrefix(Self.servicePrefix), service.map({ current == $0 }) ?? true else { continue }
            try setSecret(nil, service: item.service, account: item.account)
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
    /// The start of the services of plugin secrets in builds before `servicePrefix`, which the plugin identifier of those builds follows.
    static let previousServicePrefix = "local.arch.browser.plugin."

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

/// One plugin's secrets in one Persona, within limits that keep a plugin from filling the login keychain. Those of a plugin instance's context only read once the instance stops, and writes throw `PluginError.stopped`.
@MainActor
final class ScopedPluginSecrets: PluginSecrets {
    /// The most secrets a plugin keeps in one Persona, its secret settings among them.
    static let countLimit = 64
    /// The most UTF-8 bytes of one secret: 16 KB.
    static let sizeLimit = 16_384

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

    /// Runs the Keychain calls that read or write a secret, one at a time, off the main thread: a call can wait while macOS asks for the login keychain password, as after an ad hoc signed build changed its signature, and the windows stay responsive meanwhile, as for the AI module's keys.
    private nonisolated static let keychainQueue = DispatchQueue(label: "xyz.taeyoon.arch.plugin.keychain")

    func secret(forKey key: String) async throws -> String? {
        let (store, service, account) = (store, service, account(key))
        return try await Self.onKeychainQueue { try store.secret(service: service, account: account) }
    }

    /// Throws `PluginError.quotaExceeded` for a secret longer than `sizeLimit`, and for a new key once the plugin keeps `countLimit` secrets in the Persona.
    func setSecret(_ secret: String?, forKey key: String) async throws {
        guard !hasEnded else { throw PluginError.stopped }
        if let secret, secret.utf8.count > Self.sizeLimit { throw PluginError.quotaExceeded }
        let (store, service, account, accountPrefix, countLimit) = (store, service, account(key), Self.accountPrefix(of: personaID), Self.countLimit)
        try await Self.onKeychainQueue {
            if secret != nil, try !store.containsSecret(service: service, account: account),
               try store.secretCount(service: service, accountPrefix: accountPrefix) >= countLimit {
                throw PluginError.quotaExceeded
            }
            try store.setSecret(secret, service: service, account: account)
        }
    }

    private nonisolated static func onKeychainQueue<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            keychainQueue.async { continuation.resume(with: Result(catching: body)) }
        }
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
        (SecCopyErrorMessageString(status, nil) as String?) ?? localized("Keychain error \(status).")
    }
}
