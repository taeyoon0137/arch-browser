// API keys in the login keychain: one generic password item per HTTP provider. A key is read once per launch, when the first request to its provider starts, and kept in memory until quit or until the user replaces or removes it.
import Foundation
import Security

/// Where provider keys live. Tests use an in-memory store so they never touch the Keychain.
protocol AIKeyStore: AnyObject, Sendable {
    /// Can block while macOS asks for the login keychain password, so callers stay off the main thread.
    func key(for provider: AIProviderID) throws -> String?
    func setKey(_ key: String, for provider: AIProviderID, label: String) throws
    func removeKey(for provider: AIProviderID) throws
}

/// Service `local.arch.browser.ai`, account the provider ID, label `Arch AI: <provider name>`, accessible when unlocked, not synchronizable. The data protection keychain needs entitlements the bundle does not have, so items go to the login keychain; until the bundle has a stable signing identity, macOS asks for the keychain password once after each rebuild.
final class AIKeychain: AIKeyStore, @unchecked Sendable {
    static let service = "local.arch.browser.ai"

    private let lock = NSLock()
    /// Keys read this launch. A cached nil means the Keychain has no item.
    private var cache: [AIProviderID: String?] = [:]

    func key(for provider: AIProviderID) throws -> String? {
        if let cached = cached(provider) { return cached }
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let key: String?
        switch status {
        case errSecSuccess:
            key = (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            key = nil
        default:
            throw AIKeychainError(status: status)
        }
        remember(key, for: provider)
        return key
    }

    func setKey(_ key: String, for provider: AIProviderID, label: String) throws {
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data, kSecAttrLabel as String: label] as [String: Any]
        var status = SecItemUpdate(baseQuery(provider) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(provider)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIKeychainError(status: status) }
        remember(key, for: provider)
    }

    func removeKey(for provider: AIProviderID) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AIKeychainError(status: status) }
        remember(nil, for: provider)
    }

    private func cached(_ provider: AIProviderID) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[provider]
    }

    private func remember(_ key: String?, for provider: AIProviderID) {
        lock.lock()
        defer { lock.unlock() }
        cache[provider] = .some(key)
    }

    private func baseQuery(_ provider: AIProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// A Keychain failure, described by the system's message for its status. It never contains the key.
struct AIKeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}
