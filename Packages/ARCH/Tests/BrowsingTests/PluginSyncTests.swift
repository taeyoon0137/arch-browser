// Tests incoming plugin installs without a network or a windowed engine.
import ARCHEngine
import Foundation
import Plugins
import Testing
@testable import Browsing

@MainActor @Suite struct PluginSyncTests {
    @MainActor private final class Fixture {
        let directory: URL
        let package: URL
        let session: BrowserSession
        let source = URL(string: "https://example.org/plugin.zip")!
        let id = "org.example.synced"

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPluginSyncTests-\(UUID())")
            package = directory.appendingPathComponent("Package")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let manifest = #"{"id":"org.example.synced","name":"Synced","version":"1","apiVersion":1,"summary":"Fixture","background":"background.js","source":"https://example.org/plugin.zip","contributes":{"settings":[{"key":"label","title":"Label","type":"text","default":"Initial"},{"key":"token","title":"Token","type":"secret"}]}}"#
            try Data(manifest.utf8).write(to: package.appendingPathComponent("plugin.json"))
            try Data().write(to: package.appendingPathComponent("background.js"))
            let registry = EngineRegistry()
            registry.register(SessionTestEngine())
            session = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil,
                                         sessionSeal: .fixture, removeLiveFolderKeychainItems: {})
        }

        func item(source: PluginSyncSource? = nil, enabled: Bool = true) -> PluginSyncItem {
            PluginSyncItem(id: id, manifestID: id, name: "Synced", kind: PluginKind.script.rawValue, source: source,
                           isEnabled: enabled, settings: ["label": .string("From another Mac")])
        }

        func close() {
            session.setPluginSyncActive(false)
            for persona in session.personas { session.plugins(in: persona.id).close() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test func arrivalInstallsFromItsSourceAndChangesStayWithinThePersona() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let session = fixture.session
        let other = session.addPersona(named: "Other")
        let item = fixture.item(source: .url(fixture.source))
        var requested: [PluginSyncSource?] = []
        session.pluginSync.stagePackage = { item, manager in
            requested.append(item.source)
            return try await manager.stage(fixture.package, origin: .file(fixture.source))
        }
        let scoped = PersonaPluginSyncItem(personaID: other.id, item: item)
        session.setPluginSyncActive(true)
        try session.applyPluginSync([scoped], deleted: [])
        let manager = session.plugins(in: other.id)
        try await waitUntil { manager.plugins.contains { $0.id.rawValue == fixture.id } }
        #expect(requested == [.url(fixture.source)])
        #expect(session.plugins(in: Persona.defaultID).plugins.isEmpty)
        let installed = try #require(manager.plugins.first)
        #expect(installed.isEnabled)
        let label = try #require(installed.manifest.contributions.settings.first { $0.key == "label" })
        #expect(manager.value(of: label, for: installed.id) == .string("From another Mac"))
        var changed = item
        changed.isEnabled = false
        changed.settings["label"] = .string("Changed")
        try session.applyPluginSync([.init(personaID: other.id, item: changed)], deleted: [])
        #expect(manager.plugins.first?.isEnabled == false)
        #expect(manager.value(of: label, for: installed.id) == .string("Changed"))
        try session.applyPluginSync([], deleted: [scoped])
        #expect(manager.plugins.isEmpty && manager.syncItems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try #require(installed.packageURL).path))
    }

    @Test func missingSourcePersistsForManualInstallationAndRemovalNotifiesSync() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let session = fixture.session
        let item = fixture.item()
        session.pluginSync.stagePackage = { _, _ in Issue.record("Source-less plugin was downloaded"); throw URLError(.unsupportedURL) }
        session.setPluginSyncActive(true)
        try session.applyPluginSync([.init(personaID: Persona.defaultID, item: item)], deleted: [])
        let manager = session.plugins(in: Persona.defaultID)
        #expect(manager.pendingSyncItems == [item] && manager.plugins.isEmpty)
        let reloaded = PluginManager(persona: Persona.defaultID, directory: fixture.directory, builtIns: [])
        #expect(reloaded.pendingSyncItems == [item])
        reloaded.close()
        var notified = false
        session.onPluginSyncChange = { notified = true }
        try manager.applySyncItems([], deleting: [item.id])
        try await waitUntil { notified }
        #expect(manager.pendingSyncItems.isEmpty && session.pluginSyncItems.isEmpty)
    }

    @Test func disablingSyncCancelsAnInstallEvenIfStagingCompletesAfterward() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let session = fixture.session
        let item = fixture.item(source: .url(fixture.source))
        let manager = session.plugins(in: Persona.defaultID)
        let staged = try await manager.stage(fixture.package, origin: .file(fixture.source))
        var gate: CheckedContinuation<Void, Never>?
        var returned = false
        session.pluginSync.stagePackage = { _, _ in
            await withCheckedContinuation { gate = $0 }
            returned = true
            return staged
        }
        try session.applyPluginSync([.init(personaID: Persona.defaultID, item: item)], deleted: [])
        #expect(gate == nil && manager.plugins.isEmpty)
        session.setPluginSyncActive(true)
        try await waitUntil { gate != nil }
        session.setPluginSyncActive(false)
        gate?.resume()
        try await waitUntil { returned }
        #expect(manager.plugins.isEmpty && manager.pendingSyncItems == [item])
        #expect(session.pluginSync.installing.isEmpty && session.pluginSync.failures.isEmpty)
    }

    @Test func deletionDuringStagingCannotReinstallTheRemovedPlugin() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let session = fixture.session
        let item = fixture.item(source: .url(fixture.source))
        let scoped = PersonaPluginSyncItem(personaID: Persona.defaultID, item: item)
        let manager = session.plugins(in: Persona.defaultID)
        let staged = try await manager.stage(fixture.package, origin: .file(fixture.source))
        var gate: CheckedContinuation<Void, Never>?
        var returned = false
        session.pluginSync.stagePackage = { _, _ in
            await withCheckedContinuation { gate = $0 }
            returned = true
            return staged
        }
        session.setPluginSyncActive(true)
        try session.applyPluginSync([scoped], deleted: [])
        try await waitUntil { gate != nil }
        try session.applyPluginSync([], deleted: [scoped])
        gate?.resume()
        try await waitUntil { returned }
        #expect(manager.plugins.isEmpty && manager.pendingSyncItems.isEmpty)
    }

    @Test func failedDownloadStaysPendingAndCanBeRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let session = fixture.session
        let item = fixture.item(source: .url(fixture.source))
        session.pluginSync.stagePackage = { _, _ in throw URLError(.notConnectedToInternet) }
        session.setPluginSyncActive(true)
        try session.applyPluginSync([.init(personaID: Persona.defaultID, item: item)], deleted: [])
        try await waitUntil { session.pluginSync.failures[Persona.defaultID]?[item.id] != nil }
        #expect(session.plugins(in: Persona.defaultID).pendingSyncItems == [item])
        session.pluginSync.stagePackage = { _, manager in try await manager.stage(fixture.package, origin: .file(fixture.source)) }
        session.retryPluginSync(item, in: Persona.defaultID)
        try await waitUntil { session.plugins(in: Persona.defaultID).plugins.count == 1 }
        #expect(session.pluginSync.failures[Persona.defaultID]?[item.id] == nil)
    }
}
