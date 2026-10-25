// The plugin identifier migration on a temporary Application Support folder, Keychain services named for each test, and a defaults suite of its own, so the user's own plugins, secrets, and shortcuts are never read or moved.
import Foundation
import Testing
@testable import Plugins

@MainActor
@Suite struct PluginIdentifierMigrationTests {
    /// macOS keeps an empty file for a removed domain, so the tests reuse these names on every run. Tests run in parallel, so each test that writes preferences has a suite of its own.
    nonisolated private static let suiteName = "test.arch.plugin-migration"
    nonisolated private static let secretsSuiteName = "test.arch.plugin-migration.secrets"

    private let folder = TemporaryFolder()
    private let persona = UUID()

    private var personaFolder: URL {
        folder.url.appendingPathComponent("Plugins/\(persona.uuidString)", isDirectory: true)
    }

    /// A migration of the temporary folder, with Keychain services that start with a name of their own and the defaults suite `suiteName`.
    private func migration(suiteName: String = Self.suiteName) throws -> PluginIdentifierMigration {
        let services = "test.arch.plugin-migration.\(UUID().uuidString.lowercased())"
        return PluginIdentifierMigration(directory: folder.url, previousServicePrefix: "\(services).previous.plugin.", servicePrefix: "\(services).current.plugin.",
                                         defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    @Test func pluginsKeepTheirDataUnderTheNewIdentifiers() throws {
        let uuid = UUID().uuidString.lowercased()
        let previous = "local.arch.generated.\(uuid)", current = "xyz.taeyoon.arch.generated.\(uuid)"
        // Page Address's setting and a plugin that AI wrote, with its package as the composer writes it and its storage, as an earlier build kept them.
        try write(#"{"arch.setting:markdown": true}"#, to: "local.arch.browser.page-address/storage.json")
        let manifest: [String: PluginValue] = [
            "id": .string(previous), "name": .string("Copier"), "version": .string("1.0"), "apiVersion": .number(1), "summary": .string("Copies."),
            "permissions": .array([.string("clipboard")]), "background": .string("background.js"),
            "contributes": .object(["commands": .array([.object(["id": .string("copy"), "title": .string("Copy It")])])]),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(String(decoding: try encoder.encode(PluginValue.object(manifest)), as: UTF8.self), to: "\(previous)/package/plugin.json")
        try write(#"arch.commands.onRun("copy", () => arch.ui.copy("text"));"#, to: "\(previous)/package/background.js")
        try write(#"{"runs": 2}"#, to: "\(previous)/storage.json")
        let composition = PluginComposition(requests: ["Copy some text"], model: "Provider \u{2014} model")
        let list = PluginListFile(choices: [.init(id: "local.arch.browser.page-address", isEnabled: false), .init(id: previous, isEnabled: true)], installed: [
            .readable(.init(id: previous, origin: .generated(composition), grant: PluginGrant(permissions: [.clipboard], sites: []), installedAt: Date(timeIntervalSinceReferenceDate: 0), engineChecks: nil)),
            .unreadable(.object(["id": .string("local.arch.generated.newer"), "grant": .string("newer")])),
        ])
        try write(String(decoding: try JSONEncoder().encode(list), as: UTF8.self), to: "plugins.json")
        let migration = try migration()
        for _ in 0..<2 { migration.moveFiles() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: personaFolder.path).sorted() == ["plugins.json", current, "xyz.taeyoon.arch.page-address"])
        // The manifest keeps everything but its identifier, and the install this build cannot read takes its new identifier too.
        let renamed = try JSONDecoder().decode(PluginValue.self, from: Data(contentsOf: personaFolder.appendingPathComponent("\(current)/package/plugin.json")))
        #expect(renamed == .object(manifest.merging(["id": .string(current)]) { $1 }))
        let file = try JSONDecoder().decode(PluginListFile.self, from: Data(contentsOf: personaFolder.appendingPathComponent("plugins.json")))
        #expect(file.choices.map(\.id) == ["xyz.taeyoon.arch.page-address", current])
        #expect(file.installed?.map(\.id) == [current, "xyz.taeyoon.arch.generated.newer"])
        // The manager finds each plugin with its choice, grant, origin, settings, and storage.
        let manager = PluginManager(persona: persona, directory: folder.url, builtIns: [PageAddressPlugin.self], secretStore: MemorySecretStore())
        #expect(manager.plugins.map(\.id.rawValue) == ["xyz.taeyoon.arch.page-address", current] && manager.plugins.map(\.isEnabled) == [false, true])
        let pageAddress = PageAddressPlugin.manifest
        #expect(manager.value(of: pageAddress.contributions.settings[0], for: pageAddress.id) == .bool(true))
        let generated = try #require(manager.plugins.last)
        #expect(generated.origin == .generated(composition) && generated.grant.permissions == [.clipboard])
        #expect(manager.makeContext(for: generated).storage.value(forKey: "runs") == .number(2))
    }

    @Test func dataUnderTheNewIdentifierWinsAndThePreviousFolderStays() throws {
        try write("previous", to: "local.arch.browser.page-address/storage.json")
        try write("current", to: "xyz.taeyoon.arch.page-address/storage.json")
        let list = PluginListFile(choices: [.init(id: "local.arch.browser.page-address", isEnabled: false), .init(id: "xyz.taeyoon.arch.page-address", isEnabled: true)], installed: nil)
        try write(String(decoding: try JSONEncoder().encode(list), as: UTF8.self), to: "plugins.json")
        try migration().moveFiles()
        for (path, contents) in [("local.arch.browser.page-address/storage.json", "previous"), ("xyz.taeyoon.arch.page-address/storage.json", "current")] {
            #expect(try String(contentsOf: personaFolder.appendingPathComponent(path), encoding: .utf8) == contents)
        }
        let file = try JSONDecoder().decode(PluginListFile.self, from: Data(contentsOf: personaFolder.appendingPathComponent("plugins.json")))
        #expect(file.choices.map(\.id) == ["xyz.taeyoon.arch.page-address"] && file.choices.map(\.isEnabled) == [true] && file.installed == nil)
    }

    @Test func aFolderWhoseManifestCannotChangeKeepsItsNameUntilItCan() throws {
        let previous = "local.arch.generated.abc", current = "xyz.taeyoon.arch.generated.abc"
        try write(#"{"apiVersion": 1, "id": "\#(previous)", "name": "Copier", "summary": "Copies.", "version": "1.0"}"#, to: "\(previous)/package/plugin.json")
        let list = PluginListFile(choices: [], installed: [
            .readable(.init(id: previous, origin: .generated(PluginComposition(requests: ["Copy"], model: "model")), grant: PluginGrant(permissions: [], sites: []),
                            installedAt: Date(timeIntervalSinceReferenceDate: 0), engineChecks: nil)),
        ])
        try write(String(decoding: try JSONEncoder().encode(list), as: UTF8.self), to: "plugins.json")
        // A package folder that takes no new file, as on a full disk, keeps plugin.json from taking the new identifier.
        let packages = [previous, current].map { personaFolder.appendingPathComponent("\($0)/package").path }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: packages[0])
        defer {
            for path in packages { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        }
        let migration = try migration()
        migration.moveFiles()
        #expect(try FileManager.default.contentsOfDirectory(atPath: personaFolder.path).sorted() == [previous, "plugins.json"])
        // A later launch whose write succeeds moves the folder, and the manager finds the plugin.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packages[0])
        migration.moveFiles()
        #expect(try FileManager.default.contentsOfDirectory(atPath: personaFolder.path).sorted() == ["plugins.json", current])
        let manager = PluginManager(persona: persona, directory: folder.url, builtIns: [], secretStore: MemorySecretStore())
        #expect(manager.plugins.map(\.id.rawValue) == [current])
    }

    @Test func secretsMoveToTheServicesOfTheNewIdentifiers() throws {
        let migration = try migration(suiteName: Self.secretsSuiteName)
        let keychain = PluginKeychain()
        defer {
            migration.defaults.removePersistentDomain(forName: Self.secretsSuiteName)
            for prefix in [migration.previousServicePrefix, migration.servicePrefix] {
                for item in (try? keychain.items(withServicePrefix: prefix)) ?? [] {
                    try? keychain.setSecret(nil, service: item.service, account: item.account)
                }
            }
        }
        let account = "\(persona.uuidString)/key"
        for (id, secret) in [("local.arch.browser.page-address", "one"), ("local.arch.generated.abc", "two"), ("org.example.sample", "three"), ("org.example.kept", "previous")] {
            try keychain.setSecret(secret, service: migration.previousServicePrefix + id, account: account)
        }
        try keychain.setSecret("current", service: migration.servicePrefix + "org.example.kept", account: account)
        for _ in 0..<2 { migration.moveSecrets() }
        #expect(try keychain.items(withServicePrefix: migration.previousServicePrefix).isEmpty)
        let moved = try ["xyz.taeyoon.arch.page-address", "xyz.taeyoon.arch.generated.abc", "org.example.sample", "org.example.kept"].map {
            try keychain.secret(service: migration.servicePrefix + $0, account: account)
        }
        #expect(moved == ["one", "two", "three", "current"])
        // Once none is left, later runs leave the Keychain alone.
        #expect(migration.defaults.bool(forKey: PluginIdentifierMigration.secretsMovedKey))
        try keychain.setSecret("later", service: migration.previousServicePrefix + "org.example.later", account: account)
        migration.moveSecrets()
        #expect(try keychain.secret(service: migration.previousServicePrefix + "org.example.later", account: account) == "later")
    }

    @Test func secretsNotMovedYetGoWithTheirPluginAndPersona() throws {
        let previousPrefix = "test.arch.plugin-migration.\(UUID().uuidString.lowercased()).previous.plugin."
        let keychain = PluginKeychain(previousServicePrefix: previousPrefix)
        defer {
            for item in (try? keychain.items(withServicePrefix: previousPrefix)) ?? [] {
                try? keychain.setSecret(nil, service: item.service, account: item.account)
            }
        }
        // Items the migration left under the previous services, as when the user refused the keychain prompt.
        let other = UUID()
        for (id, owner) in [("local.arch.generated.abc", persona), ("org.example.sample", persona), ("org.example.sample", other)] {
            try keychain.setSecret("secret", service: previousPrefix + id, account: "\(owner.uuidString)/key")
        }
        func left() throws -> Set<String> {
            Set(try keychain.items(withServicePrefix: previousPrefix).map { "\($0.service.dropFirst(previousPrefix.count)) \($0.account)" })
        }
        // Removing a plugin takes its items in the Persona under the service they move to, and deleting the Persona takes the rest of its items.
        try ScopedPluginSecrets(store: keychain, pluginID: try #require(PluginID(rawValue: "xyz.taeyoon.arch.generated.abc")), personaID: persona).removeAll()
        #expect(try left() == ["org.example.sample \(persona.uuidString)/key", "org.example.sample \(other.uuidString)/key"])
        #expect(PluginManager.removeData(ofPersona: persona, in: folder.url, secretStore: keychain))
        #expect(try left() == ["org.example.sample \(other.uuidString)/key"])
    }

    @Test func shortcutsFollowTheirCommands() throws {
        let migration = try migration()
        defer { migration.defaults.removePersistentDomain(forName: Self.suiteName) }
        migration.defaults.set([
            "runCommand:#local.arch.browser.page-address/copy": ["key": "c"],
            "runCommand:#local.arch.generated.abc/run": ["key": "r"],
            "runCommand:#local.arch.generated.def/run": ["key": "d"],
            "runCommand:#xyz.taeyoon.arch.generated.def/run": ["key": "e"],
            "newTab:": ["key": "t"],
        ], forKey: PluginIdentifierMigration.shortcutsKey)
        for _ in 0..<2 { migration.moveShortcuts() }
        #expect(migration.defaults.dictionary(forKey: PluginIdentifierMigration.shortcutsKey) as? [String: [String: String]] == [
            "runCommand:#xyz.taeyoon.arch.page-address/copy": ["key": "c"],
            "runCommand:#xyz.taeyoon.arch.generated.abc/run": ["key": "r"],
            "runCommand:#xyz.taeyoon.arch.generated.def/run": ["key": "e"],
            "newTab:": ["key": "t"],
        ])
    }

    /// Writes a file in the Persona's folder.
    private func write(_ text: String, to path: String) throws {
        let url = personaFolder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
