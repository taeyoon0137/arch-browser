// API keys in the login keychain: one generic password item per HTTP provider. A key is read once per launch, when the first request to its provider starts, and kept in memory until quit or until the user replaces or removes it.
import Foundation
import Security

/// Where provider keys live. Tests use an in-memory store so they never touch the Keychain.
protocol AIKeyStore: AnyObject, Sendable {
    func key(for provider: AIProviderID) async throws -> String?
    func setKey(_ key: String, for provider: AIProviderID, label: String) async throws
    func removeKey(for provider: AIProviderID) async throws
}

/// Service `xyz.taeyoon.arch.ai`, account the provider ID, label `Arch AI: <provider name>`, accessible when unlocked, not synchronizable. The data protection keychain needs entitlements the bundle does not have, so items go to the login keychain. Builds signed with the same Apple Development identity keep access to the items; an ad hoc signed build changes its code signature with each rebuild, so macOS asks for the keychain password once after each rebuild.
final class AIKeychain: AIKeyStore, @unchecked Sendable {
    static let service = "xyz.taeyoon.arch.ai"

    /// Runs every Keychain call, one at a time, off the main thread and the cooperative threads, since a call can wait while macOS asks for the login keychain password. Requests that start together for a provider whose key is not read yet thus read it once, and a read that a write or removal follows caches its key before the write's.
    private let queue = DispatchQueue(label: "xyz.taeyoon.arch.ai.keychain")
    private let lock = NSLock()
    /// Keys read or written this launch. A cached nil means the Keychain has no item.
    private var cache: [AIProviderID: String?] = [:]

    func key(for provider: AIProviderID) async throws -> String? {
        if let cached = cached(provider) { return cached }
        return try await onQueue {
            // A read that waited behind another for the same provider finds the key that one cached.
            if let cached = self.cached(provider) { return cached }
            var query = self.baseQuery(provider)
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
            self.remember(key, for: provider)
            return key
        }
    }

    func setKey(_ key: String, for provider: AIProviderID, label: String) async throws {
        try await onQueue {
            let data = Data(key.utf8)
            let update = [kSecValueData as String: data, kSecAttrLabel as String: label] as [String: Any]
            var status = SecItemUpdate(self.baseQuery(provider) as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var item = self.baseQuery(provider)
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = label
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw AIKeychainError(status: status) }
            self.remember(key, for: provider)
        }
    }

    func removeKey(for provider: AIProviderID) async throws {
        try await onQueue {
            let status = SecItemDelete(self.baseQuery(provider) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AIKeychainError(status: status) }
            self.remember(nil, for: provider)
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
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
