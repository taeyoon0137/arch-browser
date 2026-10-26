// The bundle identifier migration on a temporary Library folder, defaults suites, and login keychain items named for each test, so the user's own data is never read or moved.
import Foundation
import Security
import Testing
@testable import Browsing

@Suite struct BundleIdentifierMigrationTests {
    @Test func preferencesMoveAndThoseOfTheCurrentIdentifierWin() throws {
        // macOS keeps an empty file for a removed domain, so this test reuses its names on every run in a checkout.
        let fixture = try Fixture(name: "test.arch.migration.\(checkoutID)")
        defer { fixture.remove() }
        let previous = try #require(UserDefaults(suiteName: fixture.migration.previousIdentifier))
        previous.set("bing", forKey: "ARCHSearchEngine")
        previous.set(320.0, forKey: "ARCHSidebarWidth")
        previous.set(true, forKey: "ARCHAskedDefaultBrowser")
        fixture.migration.defaults.set(280.0, forKey: "ARCHSidebarWidth")
        fixture.migration.movePreferences()
        #expect(fixture.migration.defaults.string(forKey: "ARCHSearchEngine") == "bing")
        #expect(fixture.migration.defaults.double(forKey: "ARCHSidebarWidth") == 280)
        #expect(fixture.migration.defaults.object(forKey: "ARCHAskedDefaultBrowser") == nil)
        #expect(fixture.migration.defaults.persistentDomain(forName: fixture.migration.previousIdentifier)?.isEmpty ?? true)
        fixture.migration.movePreferences()
        #expect(fixture.migration.defaults.string(forKey: "ARCHSearchEngine") == "bing")
    }

    @Test func websiteDataAndCookiesMoveAndCachesGoOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = fixture.migration.previousIdentifier, current = fixture.migration.identifier
        try fixture.write("WebKit/\(previous)/WebsiteData/Default/salt")
        try fixture.write("WebKit/\(previous)/WebsiteDataStore/persona/store")
        try fixture.write("HTTPStorages/\(previous)/httpstorages.sqlite")
        try fixture.write("HTTPStorages/\(previous).binarycookies")
        try fixture.write("Caches/\(previous)/Cache.db")
        for _ in 0..<2 {
            fixture.migration.moveFiles()
            fixture.migration.removeCaches()
        }
        for path in ["WebKit/\(current)/WebsiteData/Default/salt", "WebKit/\(current)/WebsiteDataStore/persona/store", "HTTPStorages/\(current)/httpstorages.sqlite", "HTTPStorages/\(current).binarycookies"] {
            #expect(fixture.contents(path) == path.replacingOccurrences(of: current, with: previous))
        }
        for path in ["WebKit/\(previous)", "HTTPStorages/\(previous)", "HTTPStorages/\(previous).binarycookies", "Caches/\(previous)"] {
            #expect(!fixture.exists(path))
        }
    }

    @Test func anItemTheCurrentIdentifierHasStaysAndThePreviousOneIsKept() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = fixture.migration.previousIdentifier, current = fixture.migration.identifier
        try fixture.write("WebKit/\(previous)/WebsiteData/Default/salt")
        try fixture.write("WebKit/\(current)/WebsiteData/Default/salt")
        try fixture.write("HTTPStorages/\(previous).binarycookies")
        fixture.migration.moveFiles()
        #expect(fixture.contents("WebKit/\(current)/WebsiteData/Default/salt") == "WebKit/\(current)/WebsiteData/Default/salt")
        #expect(fixture.exists("WebKit/\(previous)/WebsiteData/Default/salt"))
        #expect(fixture.exists("HTTPStorages/\(current).binarycookies"))
    }

    @Test func keychainItemsMoveWithTheirAttributesOnce() throws {
        let fixture = try Fixture()
        let previous = fixture.migration.previousIdentifier, current = fixture.migration.identifier
        let keyService = { (identifier: String) in identifier + BundleIdentifierMigration.keychainServiceSuffixes[0] }
        let masterKeyAccount = { (identifier: String) in BundleIdentifierMigration.webCryptoMasterKeyAccountPrefix + identifier }
        defer {
            fixture.remove()
            for identifier in [previous, current] {
                TestKeychain.delete(service: keyService(identifier), account: "provider")
                TestKeychain.delete(account: masterKeyAccount(identifier))
            }
        }
        // An AI provider key, and the master key that WebKit keeps under an account named by the identifier.
        try TestKeychain.add("provider key", service: keyService(previous), account: "provider", label: "Provider")
        try TestKeychain.add("master key", service: "WebKit WebCrypto", account: masterKeyAccount(previous), label: "WebCrypto Master Key")
        for _ in 0..<2 { fixture.migration.moveKeychainItems() }
        let movedKey = try #require(TestKeychain.item(service: keyService(current), account: "provider"))
        #expect(movedKey.key == "provider key" && movedKey.label == "Provider")
        let movedMasterKey = try #require(TestKeychain.item(account: masterKeyAccount(current)))
        #expect(movedMasterKey.key == "master key" && movedMasterKey.service == "WebKit WebCrypto" && movedMasterKey.label == "WebCrypto Master Key")
        #expect(TestKeychain.item(service: keyService(previous), account: "provider") == nil)
        #expect(TestKeychain.item(account: masterKeyAccount(previous)) == nil)
    }
}

/// Generic password items in the login keychain, where the migration finds them.
private enum TestKeychain {
    static func add(_ key: String, service: String, account: String, label: String) throws {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecAttrLabel as String: label, kSecValueData as String: Data(key.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        try #require(status == errSecSuccess, "SecItemAdd returned \(status)")
    }

    /// The key, service, and label of the item with `account`, and with `service` when it is given.
    static func item(service: String? = nil, account: String) -> (key: String, service: String?, label: String?)? {
        var query = query(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let item = result as? [String: Any],
              let key = item[kSecValueData as String] as? Data else { return nil }
        return (String(decoding: key, as: UTF8.self), item[kSecAttrService as String] as? String, item[kSecAttrLabel as String] as? String)
    }

    static func delete(service: String? = nil, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }

    private static func query(service: String?, account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        if let service { query[kSecAttrService as String] = service }
        return query
    }
}

/// A migration between two identifiers named after `name`, with a temporary Library folder and a defaults suite named by the current identifier. `remove()` deletes the folder and both identifiers' preferences.
private struct Fixture {
    let migration: BundleIdentifierMigration

    init(name: String = "test.arch.migration.\(UUID().uuidString.lowercased())") throws {
        let identifier = "\(name).current"
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        migration = BundleIdentifierMigration(previousIdentifier: "\(name).previous", identifier: identifier, library: library, defaults: try #require(UserDefaults(suiteName: identifier)))
    }

    /// Writes a file whose contents are its own path.
    func write(_ path: String) throws {
        let url = migration.library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: url)
    }

    func contents(_ path: String) -> String? {
        (try? Data(contentsOf: migration.library.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: migration.library.appendingPathComponent(path).path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: migration.library)
        migration.defaults.removePersistentDomain(forName: migration.previousIdentifier)
        migration.defaults.removePersistentDomain(forName: migration.identifier)
    }
}

/// A part of the defaults names that stays the same on every run in a checkout and differs between checkouts, so that runs in two checkouts at the same time keep apart, while SwiftPM runs one command at a time in a checkout's build folder: a hash of this file's path.
private let checkoutID = String(#filePath.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }, radix: 36)
