// The bundle identifier migration on a temporary Library folder and defaults suites named for each test, so the user's own data is never read or moved.
import Foundation
import Testing
@testable import Browsing

@Suite struct BundleIdentifierMigrationTests {
    @Test func preferencesMoveAndThoseOfTheCurrentIdentifierWin() throws {
        // macOS keeps an empty file for a removed domain, so this test reuses its names on every run.
        let fixture = try Fixture(name: "test.arch.migration")
        defer { fixture.remove() }
        let previous = try #require(UserDefaults(suiteName: fixture.migration.previousIdentifier))
        previous.set("bing", forKey: "ARCHSearchEngine")
        previous.set(320.0, forKey: "ARCHSidebarWidth")
        fixture.migration.defaults.set(280.0, forKey: "ARCHSidebarWidth")
        fixture.migration.movePreferences()
        #expect(fixture.migration.defaults.string(forKey: "ARCHSearchEngine") == "bing")
        #expect(fixture.migration.defaults.double(forKey: "ARCHSidebarWidth") == 280)
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
