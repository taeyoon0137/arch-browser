// Data that macOS keeps under the app's bundle identifier, moved once from the previous identifier at launch. `Application Support/Arch` and `Caches/Arch` are named by the app's name, so they stay where they are.
import Foundation
import Security

/// Moves the preferences, WebKit's website data, the cookies and HTTP storage, and the AI provider keys from the previous bundle identifier to the current one, and deletes the previous identifier's caches. An item moves only while the previous one exists and the current one does not, and the previous one goes only once the current one exists, so a run that stopped partway finishes at the next launch and a finished run finds nothing to do. macOS ties permissions and the default browser setting to the identifier, so they cannot move.
public struct BundleIdentifierMigration {
    /// Items in folders of `~/Library` named by the identifier and a suffix: WebKit's website data, which holds the default store and each Persona's, and the cookies and HTTP storage beside it.
    static let movedItems: [(folder: String, suffix: String)] = [("WebKit", ""), ("HTTPStorages", ""), ("HTTPStorages", ".binarycookies")]
    /// Keychain services named by the identifier and a suffix: the AI module's provider keys (`AIKeychain.service`).
    static let keychainServiceSuffixes = [".ai"]

    var previousIdentifier: String
    var identifier: String
    /// The user's Library folder.
    var library: URL
    /// The defaults whose persistent domain is `identifier`.
    var defaults: UserDefaults

    /// The app calls it before any engine starts and before anything reads a preference. A build without a bundle has no identifier and never had the previous one's data.
    public static func runAtLaunch() {
        let previousIdentifier = "local.arch.browser"
        guard let identifier = Bundle.main.bundleIdentifier, identifier != previousIdentifier else { return }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let migration = BundleIdentifierMigration(previousIdentifier: previousIdentifier, identifier: identifier, library: library, defaults: .standard)
        migration.movePreferences()
        migration.moveFiles()
        migration.removeCaches()
        migration.moveKeychainItems()
    }

    /// Copies each preference of the previous domain that the current domain lacks, then removes the previous domain.
    func movePreferences() {
        guard let previous = defaults.persistentDomain(forName: previousIdentifier), !previous.isEmpty else { return }
        let current = defaults.persistentDomain(forName: identifier) ?? [:]
        for (key, value) in previous where current[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.removePersistentDomain(forName: previousIdentifier)
    }

    /// Renames each of `movedItems` that has no counterpart under the current identifier. A rename within one folder leaves no partial copy.
    func moveFiles() {
        let manager = FileManager.default
        for item in Self.movedItems {
            let folder = library.appendingPathComponent(item.folder, isDirectory: true)
            let source = folder.appendingPathComponent(previousIdentifier + item.suffix)
            let destination = folder.appendingPathComponent(identifier + item.suffix)
            guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.moveItem(at: source, to: destination)
        }
    }

    /// Deletes the previous identifier's caches, which the system and WebKit fill again under the current one.
    func removeCaches() {
        let caches = library.appendingPathComponent("Caches", isDirectory: true).appendingPathComponent(previousIdentifier, isDirectory: true)
        guard FileManager.default.fileExists(atPath: caches.path) else { return }
        try? FileManager.default.removeItem(at: caches)
    }

    /// Adds each item of the previous services under the current one, with the attributes `AIKeychain` gives a new item, then deletes the previous item. The previous item's access list names the app of the previous identifier, so reading its key can show the login keychain prompt once. An item whose key cannot be read stays for the next launch.
    func moveKeychainItems() {
        for suffix in Self.keychainServiceSuffixes {
            let previousService = previousIdentifier + suffix, service = identifier + suffix
            for account in Self.accounts(of: previousService) {
                if Self.item(service: service, account: account, withKey: false) == nil {
                    guard let previous = Self.item(service: previousService, account: account, withKey: true), let key = previous[kSecValueData as String] else { continue }
                    var item = Self.query(service: service, account: account)
                    item[kSecValueData as String] = key
                    item[kSecAttrLabel as String] = previous[kSecAttrLabel as String]
                    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { continue }
                }
                SecItemDelete(Self.query(service: previousService, account: account) as CFDictionary)
            }
        }
    }

    private static func query(service: String, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Reading attributes alone never asks for the keychain password.
    private static func accounts(of service: String) -> [String] {
        var query = Self.query(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// The item's attributes, and its key under `kSecValueData` when asked for.
    private static func item(service: String, account: String, withKey: Bool) -> [String: Any]? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = withKey
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
}
