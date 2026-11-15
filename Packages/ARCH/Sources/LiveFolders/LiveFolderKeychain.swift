// Private feed addresses in the login keychain (live folder rule 8): a feed address with a query can carry a token, so the whole address lives only in a Keychain item, and `session.json` keeps it without the query. An address is read once per launch, at its folder's first refresh, and kept in memory.
import Foundation
import Security

/// Where private feed addresses live. Tests use `InMemoryLiveFolderKeychain`, so they never touch the Keychain.
public protocol LiveFolderAddressStore: AnyObject, Sendable {
    func address(for folder: UUID) async throws -> URL?
    func setAddress(_ address: URL, for folder: UUID, folderName: String) async throws
    /// Gives a folder's item the label of the folder's new name; a folder without an item gets none.
    func setFolderName(_ folderName: String, for folder: UUID) async throws
    func removeAddress(for folder: UUID) async throws
}

/// One generic password item per folder: service `xyz.taeyoon.arch.live-folders`, account the folder's ID, label `Arch Live Folder: <folder name>`, accessible when unlocked, not synchronizable. Like `AIKeychain`, it uses the login keychain, since the data protection keychain needs entitlements the bundle does not have.
public final class LiveFolderKeychain: LiveFolderAddressStore, @unchecked Sendable {
    public static let service = "xyz.taeyoon.arch.live-folders"

    public static func label(forFolderNamed name: String) -> String {
        "Arch Live Folder: \(name)"
    }

    /// Runs every Keychain call, one at a time, off the main thread and the cooperative threads, since a call can wait while macOS asks for the login keychain password.
    private let queue = DispatchQueue(label: "xyz.taeyoon.arch.live-folders.keychain")
    private let lock = NSLock()
    /// Addresses read or written this launch. A cached nil means the Keychain has no item.
    private var cache: [UUID: URL?] = [:]

    public init() {}

    public func address(for folder: UUID) async throws -> URL? {
        if let cached = cached(folder) { return cached }
        return try await onQueue {
            if let cached = self.cached(folder) { return cached }
            var query = Self.query(folder)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            let address: URL?
            switch status {
            case errSecSuccess: address = (result as? Data).flatMap { URL(string: String(decoding: $0, as: UTF8.self)) }
            case errSecItemNotFound: address = nil
            default: throw LiveFolderError.keychain(Self.message(status))
            }
            self.remember(address, for: folder)
            return address
        }
    }

    public func setAddress(_ address: URL, for folder: UUID, folderName: String) async throws {
        try await onQueue {
            let data = Data(address.absoluteString.utf8)
            let label = Self.label(forFolderNamed: folderName)
            let update = [kSecValueData as String: data, kSecAttrLabel as String: label] as [String: Any]
            var status = SecItemUpdate(Self.query(folder) as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var item = Self.query(folder)
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = label
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw LiveFolderError.keychain(Self.message(status)) }
            self.remember(address, for: folder)
        }
    }

    /// Changes only the label, so the address is not read.
    public func setFolderName(_ folderName: String, for folder: UUID) async throws {
        try await onQueue {
            let update = [kSecAttrLabel as String: Self.label(forFolderNamed: folderName)] as [String: Any]
            let status = SecItemUpdate(Self.query(folder) as CFDictionary, update as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LiveFolderError.keychain(Self.message(status)) }
        }
    }

    public func removeAddress(for folder: UUID) async throws {
        try await onQueue {
            let status = SecItemDelete(Self.query(folder) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LiveFolderError.keychain(Self.message(status)) }
            self.remember(nil, for: folder)
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    private func cached(_ folder: UUID) -> URL?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[folder]
    }

    private func remember(_ address: URL?, for folder: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cache[folder] = .some(address)
    }

    private static func query(_ folder: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: folder.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// The system's message for a status. It never contains the address.
    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
    }
}

/// Addresses in memory, for tests and for code that must not reach the Keychain.
public final class InMemoryLiveFolderKeychain: LiveFolderAddressStore, @unchecked Sendable {
    private let lock = NSLock()
    private var addresses: [UUID: (address: URL, label: String)] = [:]

    public init() {}

    public func address(for folder: UUID) async throws -> URL? {
        locked { addresses[folder]?.address }
    }

    public func setAddress(_ address: URL, for folder: UUID, folderName: String) async throws {
        locked { addresses[folder] = (address, LiveFolderKeychain.label(forFolderNamed: folderName)) }
    }

    public func setFolderName(_ folderName: String, for folder: UUID) async throws {
        locked { addresses[folder]?.label = LiveFolderKeychain.label(forFolderNamed: folderName) }
    }

    public func removeAddress(for folder: UUID) async throws {
        locked { addresses[folder] = nil }
    }

    /// The label each item would have in the Keychain.
    public func label(for folder: UUID) -> String? {
        locked { addresses[folder]?.label }
    }

    /// The folders that have an address.
    public var folders: Set<UUID> {
        locked { Set(addresses.keys) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
