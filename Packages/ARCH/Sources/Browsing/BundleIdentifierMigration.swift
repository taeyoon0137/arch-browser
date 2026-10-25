// Data that macOS keeps under the app's bundle identifier, moved once from the previous identifier at launch. `Application Support/Arch` and `Caches/Arch` are named by the app's name, so they stay where they are.
import Foundation
import Security

/// Moves the preferences, WebKit's website data, the cookies and HTTP storage, the AI provider keys, and WebKit's WebCrypto master key from the previous bundle identifier to the current one, and deletes the previous identifier's caches. An item moves only while the previous one exists and the current one does not, and the previous one goes only once the current one exists, so a run that stopped partway finishes at the next launch and a finished run finds nothing to do. macOS ties permissions and the default browser setting to the identifier, so they cannot move, and the app asks again to become the default browser.
public struct BundleIdentifierMigration {
    /// Items in folders of `~/Library` named by the identifier and a suffix: WebKit's website data, which holds the default store and each Persona's, and the cookies and HTTP storage beside it.
    static let movedItems: [(folder: String, suffix: String)] = [("WebKit", ""), ("HTTPStorages", ""), ("HTTPStorages", ".binarycookies")]
    /// Keychain services named by the identifier and a suffix: the AI module's provider keys (`AIKeychain.service`).
    static let keychainServiceSuffixes = [".ai"]
    /// The Keychain account, named by this prefix and the identifier, of the key with which WebKit wraps the CryptoKey objects that sites keep in IndexedDB. WebKit makes a new key when it finds none, and the new key cannot unwrap the moved ones.
    static let webCryptoMasterKeyAccountPrefix = "com.apple.WebKit.WebCrypto.master+"
    /// Preferences the current identifier starts without: whether the app asked to become the default browser (`AppDelegate`), since that setting stays with the previous identifier.
    static let unmovedPreferences: Set<String> = ["ARCHAskedDefaultBrowser"]

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

    /// Copies each preference of the previous domain that the current domain lacks, except `unmovedPreferences`, then removes the previous domain.
    func movePreferences() {
        guard let previous = defaults.persistentDomain(forName: previousIdentifier), !previous.isEmpty else { return }
        let current = defaults.persistentDomain(forName: identifier) ?? [:]
        for (key, value) in previous where current[key] == nil && !Self.unmovedPreferences.contains(key) {
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

    /// Adds each item of the previous services under the current one, with the attributes `AIKeychain` gives a new item, and WebKit's WebCrypto master key under the current identifier's account, with the attributes WebKit gave it, then deletes the previous item. The previous item's access list names the app of the previous identifier, so reading its key can show the login keychain prompt once. An item whose key cannot be read stays for the next launch.
    func moveKeychainItems() {
        for suffix in Self.keychainServiceSuffixes {
            let previousService = previousIdentifier + suffix, service = identifier + suffix
            for account in Self.accounts(of: previousService) {
                Self.moveItem(from: Self.query(service: previousService, account: account), to: Self.query(service: service, account: account), copying: [kSecAttrLabel], setting: [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked])
            }
        }
        let prefix = Self.webCryptoMasterKeyAccountPrefix
        Self.moveItem(from: Self.query(account: prefix + previousIdentifier), to: Self.query(account: prefix + identifier), copying: [kSecAttrService, kSecAttrLabel, kSecAttrComment])
    }

    /// When `current` finds no item, adds one with the key and `attributes` of the item `previous` finds and with `values`; then deletes the previous item.
    private static func moveItem(from previous: [String: Any], to current: [String: Any], copying attributes: [CFString], setting values: [String: Any] = [:]) {
        if Self.item(current, withKey: false) == nil {
            guard let previousItem = Self.item(previous, withKey: true), let key = previousItem[kSecValueData as String] else { return }
            var item = current.merging(values) { $1 }
            item[kSecValueData as String] = key
            for attribute in attributes { item[attribute as String] = previousItem[attribute as String] }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return }
        }
        SecItemDelete(previous as CFDictionary)
    }

    private static func query(service: String? = nil, account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: false,
        ]
        if let service { query[kSecAttrService as String] = service }
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

    /// The attributes of the item `query` finds, and its key under `kSecValueData` when asked for.
    private static func item(_ query: [String: Any], withKey: Bool) -> [String: Any]? {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = withKey
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
}
