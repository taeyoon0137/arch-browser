import ARCHEngine
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Plugins

@MainActor @Suite struct PluginSyncTests {
    private let folder = TemporaryFolder()
    private let persona = UUID()
    private let secrets = MemorySecretStore()
    private let identifier = PluginID(rawValue: "org.example.synced")!

    private func manager(runtimes: [any PluginRuntime] = []) -> PluginManager {
        PluginManager(persona: persona, directory: folder.url, builtIns: [], runtimes: runtimes, secretStore: secrets)
    }

    private func package(source: String? = nil) throws -> URL {
        let root = folder.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["id": identifier.rawValue, "name": "Synced", "version": "1", "apiVersion": 1, "summary": "Test",
                                     "contributes": ["settings": [["key": "label", "title": "Label", "type": "text", "default": "Default"],
                                                                  ["key": "token", "title": "Token", "type": "secret"]]]]
        manifest["source"] = source
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("plugin.json"))
        return root
    }

    @Test func projectsDeclaredSettingsWithoutSecretsStorageOrPaths() async throws {
        let manager = manager()
        let package = try await manager.stage(package())
        try manager.install(package, grant: PluginGrant(requestedBy: package.manifest), isEnabled: false)
        let storageURL = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/\(identifier.rawValue)/storage.json")
        try JSONEncoder().encode(["private": PluginValue.string("private-storage"), "arch.setting:obsolete": .string("undeclared-setting")]).write(to: storageURL)
        let label = try #require(package.manifest.contributions.settings.first { $0.key == "label" })
        let token = try #require(package.manifest.contributions.settings.first { $0.key == "token" })
        try manager.setValue(.string("Shared"), of: label, for: identifier)
        try await manager.setSecret("keychain-secret", of: token, for: identifier)
        let item = try #require(manager.syncItems.first)
        #expect(item.settings == ["label": .string("Shared")])
        #expect(item.source == nil)
        let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        #expect(!encoded.contains("keychain-secret") && !encoded.contains("private-storage") && !encoded.contains("undeclared-setting"))
        #expect(!encoded.contains("file:") && secrets.readsOnMainThread == 0)
        var incoming = item
        incoming.settings = ["label": .string("Remote"), "token": .string("injected-secret"), "private": .string("injected-storage")]
        try manager.applySyncItems([incoming], deleting: [])
        #expect(manager.syncItems.first?.settings == ["label": .string("Remote")])
        #expect(secrets.items.values.contains("keychain-secret"))
        let stored = try JSONDecoder().decode([String: PluginValue].self, from: Data(contentsOf: storageURL))
        #expect(stored["private"] == .string("private-storage") && stored["arch.setting:token"] == nil)
    }

    @Test func missingInstallSurvivesRestartThenInstallsAndDeletes() async throws {
        let source = URL(string: "https://example.org/plugin.zip")!
        let item = PluginSyncItem(id: identifier.rawValue, manifestID: identifier.rawValue, name: "Synced", kind: "script",
                                  source: .url(source), isEnabled: true, settings: ["label": .string("Remote")])
        try manager().applySyncItems([item], deleting: [])
        let restored = manager()
        #expect(restored.pendingSyncItems == [item])
        let staged = try await restored.stage(package(), origin: .file(source))
        try restored.installSynced(staged, for: item)
        #expect(restored.pendingSyncItems.isEmpty && restored.plugins.first?.isEnabled == true)
        #expect(restored.syncItems.first?.settings == ["label": .string("Remote")])
        var disabled = try #require(restored.syncItems.first)
        disabled.isEnabled = false
        try restored.applySyncItems([disabled], deleting: [])
        #expect(restored.plugins.first?.isEnabled == false)
        try restored.applySyncItems([], deleting: [item.id])
        #expect(restored.plugins.isEmpty && restored.syncItems.isEmpty && manager().syncItems.isEmpty)
    }

    @Test func ignoresAnInstallThatWasRemovedWhileDownloading() async throws {
        let manager = manager()
        let item = PluginSyncItem(id: identifier.rawValue, manifestID: identifier.rawValue, name: "Synced", kind: "script", isEnabled: false)
        try manager.applySyncItems([item], deleting: [])
        let staged = try await manager.stage(package())
        try manager.applySyncItems([], deleting: [item.id])
        #expect(throws: PluginError.stopped) { try manager.installSynced(staged, for: item) }
        #expect(manager.plugins.isEmpty)
        manager.discard(staged)
    }

    @Test func usesManifestPackageSourceAndRejectsCredentialSources() async throws {
        let manager = manager()
        let source = "https://example.org/plugin.zip"
        let staged = try await manager.stage(package(source: source))
        try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: false)
        #expect(manager.syncItems.first?.source == .url(URL(string: source)!))
        for unsafe in ["http://example.org/plugin.zip", "https://user:password@example.org/plugin.zip", "https://example.org/plugin.zip?token=secret", "file:///private/plugin.zip"] {
            #expect(!PluginSyncSource.accepts(URL(string: unsafe)!))
            await #expect(throws: (any Error).self) { _ = try await manager.stage(package(source: unsafe)) }
        }
    }

    @Test func manualInstallDiscoversItsPackageSource() async throws {
        let manager = manager()
        let item = PluginSyncItem(id: identifier.rawValue, manifestID: identifier.rawValue, name: "Synced", kind: "script", isEnabled: false)
        try manager.applySyncItems([item], deleting: [])
        let source = "https://example.org/plugin.zip"
        let staged = try await manager.stage(package(source: source))
        try manager.installSynced(staged, for: item)
        #expect(manager.pendingSyncItems.isEmpty)
        #expect(manager.syncItems.first?.source == .url(URL(string: source)!))
        let restored = self.manager()
        #expect(restored.pendingSyncItems.isEmpty && restored.syncItems.first?.source == .url(URL(string: source)!))
    }

    @Test func sourceReplacementDisablesTheOldPackageBeforeDownload() async throws {
        let manager = manager()
        let source = URL(string: "https://example.org/original.zip")!
        let staged = try await manager.stage(package(), origin: .file(source))
        try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: true)
        var replacement = try #require(manager.syncItems.first)
        replacement.source = .url(URL(string: "https://example.org/replacement.zip")!)
        replacement.isEnabled = false
        replacement.settings["label"] = .string("Replacement")
        try manager.applySyncItems([replacement], deleting: [])
        #expect(manager.plugins.first?.isEnabled == false)
        #expect(manager.pendingSyncItems == [replacement])
        let label = try #require(staged.manifest.contributions.settings.first { $0.key == "label" })
        #expect(manager.value(of: label, for: identifier) == .string("Default"))
    }

    @Test func incompleteInstallStaysPendingAcrossRestartUntilSettingsSave() async throws {
        let manager = manager()
        let source = URL(string: "https://example.org/plugin.zip")!
        let item = PluginSyncItem(id: identifier.rawValue, manifestID: identifier.rawValue, name: "Synced", kind: "script",
                                  source: .url(source), isEnabled: true, settings: ["label": .string("Remote")])
        let staged = try await manager.stage(package(), origin: .file(source))
        let label = try #require(staged.manifest.contributions.settings.first { $0.key == "label" })
        // Load the storage before placing a folder at its path, so the next operation is its failed write.
        #expect(manager.value(of: label, for: identifier) == .string("Default"))
        let storage = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/\(identifier.rawValue)/storage.json")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try manager.applySyncItems([item], deleting: [])
        #expect(throws: (any Error).self) { try manager.installSynced(staged, for: item) }
        #expect(manager.plugins.first?.isEnabled == false)
        #expect(manager.pendingSyncItems == [item] && manager.syncItems == [item])
        manager.close()
        try FileManager.default.removeItem(at: storage)
        let restored = self.manager()
        #expect(restored.pendingSyncItems == [item] && restored.syncItems == [item])
        let retry = try await restored.stage(package(), origin: .file(source))
        try restored.installSynced(retry, for: item)
        #expect(restored.pendingSyncItems.isEmpty && restored.plugins.first?.isEnabled == true)
        #expect(restored.syncItems == [item])
        #expect(self.manager().pendingSyncItems.isEmpty)
    }

    @Test func failedLocalSettingWriteDoesNotEnterLaterSyncProjection() async throws {
        let manager = manager()
        let staged = try await manager.stage(package())
        try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: false)
        let label = try #require(staged.manifest.contributions.settings.first { $0.key == "label" })
        let storage = folder.url.appendingPathComponent("Plugins/\(persona.uuidString)/\(identifier.rawValue)/storage.json")
        let saved = storage.appendingPathExtension("saved")
        for previous in [nil, PluginValue.string("Saved")] {
            try manager.setValue(previous, of: label, for: identifier)
            try FileManager.default.moveItem(at: storage, to: saved)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try manager.setValue(.string("Unsaved"), of: label, for: identifier) }
            manager.setEnabled(!(manager.plugins.first?.isEnabled ?? false), for: identifier)
            #expect(manager.syncItems.first?.settings == ["label": previous ?? .string("Default")])
            try FileManager.default.removeItem(at: storage)
            try FileManager.default.moveItem(at: saved, to: storage)
            // A subsequent successful write keeps absence distinct from an explicit default value.
            try manager.setValue(previous, of: label, for: identifier)
            let stored = try JSONDecoder().decode([String: PluginValue].self, from: Data(contentsOf: storage))
            #expect(stored["arch.setting:label"] == previous)
        }
    }

    @Test func engineVersionsArriveInEitherOrderAndKeepTheirScope() async throws {
        let runtime = SyncTestRuntime()
        let manager = manager(runtimes: [runtime])
        let root = folder.url.appendingPathComponent("extension")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("manifest.json"))
        let webkit = PluginSyncItem(id: identifier.rawValue, manifestID: identifier.rawValue, name: "Synced", kind: "webExtension", isEnabled: true,
                                    engine: "webKit", counterpartID: identifier.rawValue + ".chromium")
        let chromium = PluginSyncItem(id: identifier.rawValue + ".chromium", manifestID: identifier.rawValue, name: "Synced", kind: "webExtension", isEnabled: true,
                                      engine: "chromium", counterpartID: identifier.rawValue)
        try manager.applySyncItems([webkit, chromium], deleting: [])
        try manager.installSynced(await manager.stage(root), for: chromium)
        #expect(manager.plugins.first?.pairEngine == .chromium)
        #expect(manager.plugins.first?.engines == [.chromium])
        try manager.installSynced(await manager.stage(root), for: webkit)
        #expect(manager.engineVersions.count == 1)
        #expect(manager.plugins.first { $0.id.rawValue == webkit.id }?.engines == [.webKit])
        #expect(manager.plugins.first { $0.id.rawValue == chromium.id }?.engines == [.chromium])
        let restored = self.manager(runtimes: [SyncTestRuntime()])
        #expect(restored.engineVersions.count == 1 && restored.pendingSyncItems.isEmpty)
    }

    @Test func unrelatedArrivalsDoNotUndoALocalPair() async throws {
        let manager = manager(runtimes: [SyncTestRuntime()])
        let otherID = PluginID(rawValue: "org.example.other")!
        for id in [identifier, otherID] {
            let root = folder.url.appendingPathComponent(id.rawValue)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["id": id.rawValue]).write(to: root.appendingPathComponent("manifest.json"))
            let staged = try await manager.stage(root)
            try manager.install(staged, grant: PluginGrant(requestedBy: staged.manifest), isEnabled: false)
        }
        try manager.applySyncItems(manager.syncItems, deleting: [])
        let pair = PluginEngineVersions([.webKit: identifier, .chromium: otherID])
        try manager.join(pair)
        try manager.applySyncItems([], deleting: [])
        #expect(manager.engineVersions == [pair])
        let unrelated = PluginSyncItem(id: "org.example.missing", manifestID: "org.example.missing", name: "Missing", kind: "script", isEnabled: false)
        try manager.applySyncItems([unrelated], deleting: [])
        #expect(manager.engineVersions == [pair])
    }
}

@MainActor private final class SyncTestRuntime: PluginRuntime {
    nonisolated let kind = PluginKind.webExtension
    nonisolated let manifestFileName = "manifest.json"
    var unavailability: String? { nil }
    var engines: [EngineKind: String] { [.webKit: "1", .chromium: "1"] }
    var onCheck: ((PluginID, [EngineKind: PluginEngineCheck]) -> Void)?
    var onEngineFailure: ((PluginID, EngineKind, String) -> Void)?
    var onEnginesChange: (() -> Void)?
    var runtimeFile: URL?
    nonisolated func manifest(forPackageAt root: URL, source: URL) throws -> PluginManifest {
        let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: String]
        return PluginManifest(id: PluginID(rawValue: fields?["id"] ?? "org.example.synced")!, name: "Synced", version: "1", summary: "", contributions: PluginContributions())
    }
    func check(packageAt root: URL) async -> [EngineKind: PluginEngineCheck] { [.webKit: .runs, .chromium: .runs] }
    func run(_ installed: [InstalledPlugin]) {}
    func makePlugin(_ installed: InstalledPlugin) -> any Plugin { SyncTestPlugin() }
    func remove(_ installed: InstalledPlugin) {}
    func packageTypes(for engine: EngineKind) -> [UTType] { [.folder] }
}

@MainActor private final class SyncTestPlugin: Plugin {
    func activate(in context: any PluginContext) async throws {}
    func run(_ command: String, _ invocation: PluginInvocation) async throws {}
}
