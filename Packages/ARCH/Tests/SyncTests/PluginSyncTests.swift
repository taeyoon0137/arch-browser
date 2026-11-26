import ARCHEngine
import Browsing
import CloudKit
import Foundation
import Plugins
import Testing
@testable import Sync

@MainActor @Suite struct PluginSyncTests {
    private static let date = Date(timeIntervalSinceReferenceDate: 100)

    private func item(_ id: String = "org.example.plugin", enabled: Bool = true,
                      persona: UUID = Persona.defaultID) -> PersonaPluginSyncItem {
        PersonaPluginSyncItem(personaID: persona, item: PluginSyncItem(id: id, manifestID: id, name: "Example", kind: "script",
            source: .url(URL(string: "https://example.org/plugin.zip")!), isEnabled: enabled,
            settings: ["theme": .string("dark")], grant: PluginGrant(permissions: [.clipboard], sites: [])))
    }

    private func record(_ item: PersonaPluginSyncItem, at date: Date = Date(timeIntervalSinceReferenceDate: 100)) throws -> SyncRecord {
        try #require(PluginRecords.records(from: [item], foundAt: date).first)
    }

    @Test func mappingEncryptsOnlyAllowlistedFieldsAndKeepsPersonaIdentity() throws {
        let item = item()
        let record = try record(item)
        #expect(record.schemaVersion == 4)
        #expect(record.recordName.hasPrefix("plugin.default."))
        #expect(record.fields.keys.count == 9)
        #expect(PluginRecords.item(from: record) == item)
        let cloud = SyncCloudKitRecords.ckRecord(from: record)
        #expect((cloud["persona"] as? CKRecord.Reference)?.recordID.recordName == "default")
        for field in ["pluginID", "manifestID", "name", "kind", "source", "enabled", "settings", "grant"] {
            #expect(cloud[field] == nil)
            #expect(cloud.encryptedValues[field] is String)
        }
        for field in ["storage", "secrets", "packageURL", "installedAt", "proof", "keychain"] {
            #expect(cloud[field] == nil && cloud.encryptedValues[field] == nil)
        }
        #expect(PluginRecords.item(from: try #require(SyncCloudKitRecords.syncRecord(from: cloud))) == item)
        let other = self.item(persona: UUID())
        #expect(try self.record(other).recordName != record.recordName)
    }

    @Test func enginePairEntriesHaveIndependentRecordsAndStableIdentity() throws {
        let manifest = "org.example.extension"
        let first = PersonaPluginSyncItem(personaID: Persona.defaultID, item: PluginSyncItem(id: manifest, manifestID: manifest,
            name: "Example", kind: "webExtension", source: .webStore(String(repeating: "a", count: 32)), isEnabled: true,
            engine: "chromium", counterpartID: "\(manifest).webkit"))
        let second = PersonaPluginSyncItem(personaID: Persona.defaultID, item: PluginSyncItem(id: "\(manifest).webkit", manifestID: manifest,
            name: "Example", kind: "webExtension", isEnabled: false, engine: "webKit", counterpartID: manifest))
        let rows = try PluginRecords.records(from: [first, second], foundAt: Self.date)
        #expect(rows.count == 2 && rows[0].recordName != rows[1].recordName)
        #expect(rows.compactMap(PluginRecords.item(from:)) == [first, second])
        var unpaired = first.item
        unpaired.engine = nil; unpaired.counterpartID = nil
        #expect(try record(.init(personaID: first.personaID, item: unpaired)).recordName == rows[0].recordName)
    }

    @Test func unknownOrUnsafeRecordsAreHeldRatherThanApplied() throws {
        let valid = try record(item())
        var changed = valid
        changed[.kind] = .text("futureRuntime")
        #expect(PluginRecords.item(from: changed) == nil)
        changed = valid; changed[.engine] = .text("futureEngine")
        #expect(PluginRecords.item(from: changed) == nil)
        changed = valid; changed[.persona] = .reference(UUID().uuidString)
        #expect(PluginRecords.item(from: changed) == nil)
        changed = valid
        let source = PluginSyncSource.url(URL(string: "https://example.org/plugin.zip?token=private")!)
        changed[.source] = .text(String(decoding: try JSONEncoder().encode(source), as: UTF8.self))
        #expect(PluginRecords.item(from: changed) == nil)
    }

    @Test func settingsAndEnabledStateMergeWithoutMixingPackageIdentity() throws {
        let base = try record(item())
        var local = base, remote = base
        local[.enabled] = .text("false"); local.fieldModifiedAt["enabled"] = Self.date.addingTimeInterval(2)
        remote[.settings] = .text("{\"theme\":\"light\"}"); remote.fieldModifiedAt["settings"] = Self.date.addingTimeInterval(3)
        let merged = SyncMerge.merge(local: local, server: remote, base: .mirror(base)).record
        #expect(merged[.enabled] == .text("false") && merged[.settings] == remote[.settings])
        #expect(PluginRecords.item(from: merged)?.item.isEnabled == false)
    }

    private final class State: SyncedSidebar, SyncedPlugins {
        let defaultEngine = EngineKind.webKit
        let needsFullSidebarSync = false
        var onSidebarSyncSave: ((SidebarSyncState) -> Void)?
        var onPluginSyncChange: (() -> Void)?
        var sidebarSyncState = SidebarSyncState(personas: [Persona(id: Persona.defaultID, name: "Default")],
            spaces: [Space(name: "Personal")], folders: [], favorites: [], pinnedTabs: [])
        var pluginSyncItems: [PersonaPluginSyncItem] = []
        var active = false
        var failApply = false
        var applied: [PersonaPluginSyncItem] = []
        var removed: [PersonaPluginSyncItem] = []
        func finishSidebarSyncRecovery() {}
        func applySidebarSync(_ state: SidebarSyncState, deletions: SidebarSyncDeletions) { sidebarSyncState = state }
        func applyFirstSidebarSync(_ state: SidebarSyncState, replacements: SidebarSyncReplacements) { sidebarSyncState = state }
        func saveNow() -> Result<Void, Error> { onSidebarSyncSave?(sidebarSyncState); return .success(()) }
        func setPluginSyncActive(_ active: Bool) { self.active = active }
        func applyPluginSync(_ items: [PersonaPluginSyncItem], deleted: [PersonaPluginSyncItem]) throws {
            if failApply { throw CocoaError(.fileWriteOutOfSpace) }
            applied += items; removed += deleted
            for item in items {
                pluginSyncItems.removeAll { $0.personaID == item.personaID && $0.item.id == item.item.id }
                pluginSyncItems.append(item)
            }
            for item in deleted { pluginSyncItems.removeAll { $0.personaID == item.personaID && $0.item.id == item.item.id } }
            onPluginSyncChange?()
        }
    }

    @MainActor private final class Fixture {
        let suite = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = SyncDatabase(containerIdentifier: "test.plugin.sync", environment: "Development")
        let state = State()
        let defaults: UserDefaults
        var controller: SyncController!
        var engines: [FakeSyncEngine] = []
        var nextFetch: [SyncEvent] = []
        init() { defaults = UserDefaults(suiteName: suite)!; makeController() }
        func makeController() {
            controller = SyncController(sidebar: state, plugins: state, directory: directory, defaults: defaults,
                notifications: NotificationCenter(), check: { [weak self] in
                    guard let self else { return .unavailable(.temporarilyUnavailable) }
                    return .available(database)
                },
                factory: FakeSyncEngine.factory { [weak self] engine in
                    guard let self else { return }
                    engines.append(engine); engine.fetchScript = nextFetch; nextFetch = []
                }, now: { PluginSyncTests.date })
        }
        var mirror: SyncMirror { SyncMirror.read(from: directory.appendingPathComponent(SyncMirror.fileName), database: database) }
        func start() async throws -> FakeSyncEngine {
            await controller.setEnabled(true)
            let engine = try #require(engines.last)
            try await engine.sendChanges()
            return engine
        }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    }

    @Test func completedArrivalAppliesAndRemoteUninstallWinsOverLocalEdits() async throws {
        let f = Fixture(); defer { f.clean() }
        let engine = try await f.start()
        let incoming = item()
        let row = try record(incoming)
        engine.deliver([.fetchStarted, .fetchedChanges(.init(records: [SyncCloudKitRecords.ckRecord(from: row)]))])
        #expect(f.state.pluginSyncItems.isEmpty)
        engine.deliver([.fetchEnded(failure: nil)])
        #expect(f.state.pluginSyncItems == [incoming] && f.state.active)
        var changed = incoming.item; changed.isEnabled = false
        f.state.pluginSyncItems = [.init(personaID: incoming.personaID, item: changed)]
        f.state.onPluginSyncChange?()
        engine.fetchScript = [.fetchedChanges(.init(deletions: [.init(recordID: SyncCloudKitRecords.recordID(named: row.recordName), recordType: "Plugin")]))]
        await f.controller.refresh()
        #expect(f.state.pluginSyncItems.isEmpty && f.state.removed == [incoming])
        #expect(!engine.pendingChanges.contains(.saveRecord(row.recordName)))
        #expect(f.mirror.records[row.recordName] == nil)
    }

    @Test func localUninstallQueuesOnlyThePluginDeletion() async throws {
        let f = Fixture(); defer { f.clean() }
        let installed = item(); f.state.pluginSyncItems = [installed]
        let engine = try await f.start()
        let name = try record(installed).recordName
        f.state.pluginSyncItems = []
        f.state.onPluginSyncChange?()
        #expect(engine.pendingChanges == [.deleteRecord(name)])
        try await engine.sendChanges()
        #expect(engine.batches.last?.deletedRecordNames == [name])
        #expect(f.mirror.records[name] == nil && f.state.sidebarSyncState.personas.count == 1)
    }

    @Test func switchDefaultsOnAndPausedArrivalsAndTombstonesSurviveRelaunch() async throws {
        let f = Fixture(); defer { f.clean() }
        #expect(f.controller.isPluginsEnabled)
        let installed = item(); f.state.pluginSyncItems = [installed]
        let engine = try await f.start()
        let oldName = try record(installed).recordName
        await f.controller.setPluginsEnabled(false)
        #expect(!f.state.active && f.state.pluginSyncItems == [installed])
        let arrival = item("org.example.arrival")
        let arrivalRow = try record(arrival)
        engine.fetchScript = [.fetchedChanges(.init(records: [SyncCloudKitRecords.ckRecord(from: arrivalRow)],
            deletions: [.init(recordID: SyncCloudKitRecords.recordID(named: oldName), recordType: "Plugin")]))]
        await f.controller.refresh()
        #expect(f.state.pluginSyncItems == [installed] && f.state.removed.isEmpty)
        #expect(f.mirror.pluginDeletions.map(\.recordName) == [oldName])
        #expect(f.mirror.unapplied.contains(arrivalRow.recordName))
        try await engine.sendChanges()
        #expect(!engine.batches.contains { $0.deletedRecordNames.contains(arrivalRow.recordName) })
        await f.controller.setEnabled(false)
        f.makeController()
        #expect(!f.controller.isPluginsEnabled)
        _ = try await f.start()
        #expect(f.state.pluginSyncItems == [installed] && !f.state.active)
        await f.controller.setPluginsEnabled(true)
        #expect(f.state.pluginSyncItems == [arrival] && f.state.active)
        #expect(f.mirror.pluginDeletions.isEmpty && !f.mirror.unapplied.contains(arrivalRow.recordName))
    }

    @Test func pausedLaunchRemovesRestoredPluginDeletesFromEngineQueue() async throws {
        let f = Fixture(); defer { f.clean() }
        let installed = item(); f.state.pluginSyncItems = [installed]
        _ = try await f.start()
        let name = try record(installed).recordName
        f.state.pluginSyncItems = []; f.state.onPluginSyncChange?()
        await f.controller.setEnabled(false)
        f.defaults.set(false, forKey: SyncController.pluginsEnabledKey)
        f.makeController()
        let restarted = try await f.start()
        #expect(!restarted.batches.contains { $0.deletedRecordNames.contains(name) })
        #expect(f.mirror.records[name] != nil)
    }

    @Test func failedPluginPersistenceHoldsTheFetchTokenAndUploads() async throws {
        let f = Fixture(); defer { f.clean() }
        let engine = try await f.start()
        let old = f.mirror.engineState
        let incoming = item()
        engine.fetchScript = [.fetchedChanges(.init(records: [SyncCloudKitRecords.ckRecord(from: try record(incoming))]))]
        f.state.failApply = true
        await f.controller.refresh()
        #expect(!f.controller.canSendRecords && f.controller.lastError != nil)
        #expect(f.mirror.engineState == old && f.state.pluginSyncItems.isEmpty)
        f.state.failApply = false
        await f.controller.refresh()
        #expect(f.state.pluginSyncItems == [incoming] && f.controller.canSendRecords)
    }

    @Test func unknownPluginFieldsSurviveAStateChangeAndInvalidSourcesAreNotDeleted() async throws {
        let f = Fixture(); defer { f.clean() }
        let engine = try await f.start()
        var incoming = try record(item())
        incoming.fields["futureSetting"] = .text("keep")
        var unknown = try record(item("org.example.future"))
        unknown[.kind] = .text("futureRuntime")
        engine.fetchScript = [.fetchedChanges(.init(records: [incoming, unknown].map { SyncCloudKitRecords.ckRecord(from: $0) }))]
        await f.controller.refresh()
        #expect(f.state.pluginSyncItems.count == 1 && f.mirror.unapplied.contains(unknown.recordName))
        var changed = try #require(f.state.pluginSyncItems.first).item; changed.isEnabled = false
        f.state.pluginSyncItems = [.init(personaID: Persona.defaultID, item: changed)]
        f.state.onPluginSyncChange?()
        try await engine.sendChanges()
        #expect(f.mirror.records[incoming.recordName]?.encryptedValues["futureSetting"] as? String == "keep")
        #expect(f.mirror.records[unknown.recordName] != nil)
    }

    @Test func anUnsupportedReplacementOfAnInstalledPluginIsNotOverwritten() async throws {
        let f = Fixture(); defer { f.clean() }
        let installed = item(); f.state.pluginSyncItems = [installed]
        let engine = try await f.start()
        var future = try record(installed)
        future[.kind] = .text("futureRuntime")
        engine.fetchScript = [.fetchedChanges(.init(records: [SyncCloudKitRecords.ckRecord(from: future)]))]
        await f.controller.refresh()
        var changed = installed.item; changed.isEnabled = false
        f.state.pluginSyncItems = [.init(personaID: installed.personaID, item: changed)]
        f.state.onPluginSyncChange?()
        #expect(!engine.pendingChanges.contains(.saveRecord(future.recordName)))
        #expect(f.mirror.records[future.recordName]?.encryptedValues["kind"] as? String == "futureRuntime")
        #expect(f.mirror.unapplied.contains(future.recordName))
    }

}
