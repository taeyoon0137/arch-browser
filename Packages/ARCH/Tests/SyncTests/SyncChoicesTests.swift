import ARCHEngine
import Browsing
import CloudKit
import Foundation
import Plugins
import Testing
@testable import Sync

@MainActor @Suite struct SyncChoicesTests {
    enum Item: CaseIterable, Equatable, Sendable { case sidebar, settings, siteRules, plugins }

    private final class State: SyncedSidebar, SyncedPlugins {
        let defaultEngine = EngineKind.webKit
        let needsFullSidebarSync = false
        var onSidebarSyncSave: ((SidebarSyncState) -> Void)?
        var onOpenTabsSyncSave: (([OpenTabsSpace]) -> Void)?
        var onShowRemoteTabsChange: ((Bool) -> Void)?
        var onPluginSyncChange: (() -> Void)?
        var remoteTabGroups: [RemoteTabGroup] = []
        var showRemoteTabs = true
        var isSidebarSyncEnabled = false
        var active = false
        var hasOpenTabs = false
        var sidebarSyncState = SidebarSyncState(personas: [Persona(id: Persona.defaultID, name: "Default")],
            spaces: [Space(name: "Personal")], folders: [], favorites: [], pinnedTabs: [])
        var pluginSyncItems: [PersonaPluginSyncItem] = []
        var openTabsSyncState: [OpenTabsSpace] {
            sidebarSyncState.spaces.map { space in
                .init(personaID: space.resolvedPersonaID, spaceID: space.id, tabs: hasOpenTabs ? [
                    RemoteTab(url: URL(string: "https://example.test/open")!, title: "Open", engine: .webKit, order: 0)
                ] : [])
            }
        }
        func finishSidebarSyncRecovery() {}
        func saveNow() -> Result<Void, Error> {
            onSidebarSyncSave?(sidebarSyncState)
            onOpenTabsSyncSave?(openTabsSyncState)
            return .success(())
        }
        func applyFirstSidebarSync(_ incoming: SidebarSyncState, replacements: SidebarSyncReplacements) {
            applySidebarSync(incoming, deletions: SidebarSyncDeletions())
        }
        func applySidebarSync(_ incoming: SidebarSyncState, deletions: SidebarSyncDeletions) {
            func merged<T: Identifiable>(_ current: [T], _ incoming: [T], removing deleted: Set<UUID>) -> [T] where T.ID == UUID {
                let names = Set(incoming.map(\.id))
                return (incoming + current.filter { !names.contains($0.id) }).filter { !deleted.contains($0.id) }
            }
            let old = sidebarSyncState
            sidebarSyncState = .init(personas: merged(old.personas, incoming.personas, removing: deletions.personas),
                spaces: merged(old.spaces, incoming.spaces, removing: deletions.spaces),
                folders: merged(old.folders, incoming.folders, removing: deletions.folders),
                favorites: merged(old.favorites, incoming.favorites, removing: deletions.favorites),
                pinnedTabs: merged(old.pinnedTabs, incoming.pinnedTabs, removing: deletions.tabs),
                siteRules: merged(old.siteRules, incoming.siteRules, removing: deletions.siteRules))
        }
        func setPluginSyncActive(_ active: Bool) { self.active = active }
        func applyPluginSync(_ items: [PersonaPluginSyncItem], deleted: [PersonaPluginSyncItem]) throws {
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
        let database = SyncDatabase(containerIdentifier: "test.sync.choices", environment: "Development")
        let state = State()
        let defaults: UserDefaults
        var controller: SyncController!
        var engines: [FakeSyncEngine] = []
        var nextFetch: [SyncEvent] = []
        var server: [String: CKRecord] = [:]
        var now = Date(timeIntervalSinceReferenceDate: 100_000)
        init() { defaults = UserDefaults(suiteName: suite)!; makeController() }
        func makeController() {
            controller = SyncController(sidebar: state, plugins: state, directory: directory, defaults: defaults,
                notifications: NotificationCenter(), check: { [weak self] in
                    self.map { .available($0.database) } ?? .unavailable(.temporarilyUnavailable)
                }, factory: FakeSyncEngine.factory { [weak self] engine in
                    guard let self else { return }
                    engines.append(engine); engine.fetchScript = nextFetch; nextFetch = []
                    engine.onSavedBatch = { [weak self] batch in
                        for row in batch.records { self?.server[row.recordID.recordName] = row }
                        for name in batch.deletedRecordNames { self?.server[name] = nil }
                    }
                }, now: { [weak self] in self?.now ?? .distantPast }, remoteDebounce: .milliseconds(5), remoteDeviceName: { "Desk" })
        }
        var mirror: SyncMirror { SyncMirror.read(from: directory.appendingPathComponent(SyncMirror.fileName), database: database) }
        func start() async throws -> FakeSyncEngine {
            await controller.setEnabled(true)
            let engine = try #require(engines.last)
            try await engine.sendChanges()
            return engine
        }
        func set(_ item: Item, _ enabled: Bool) async {
            switch item {
            case .sidebar: await controller.setSidebarEnabled(enabled)
            case .settings: await controller.setSettingsEnabled(enabled)
            case .siteRules: await controller.setSiteRulesEnabled(enabled)
            case .plugins: await controller.setPluginsEnabled(enabled)
            }
        }
        func enabled(_ item: Item) -> Bool {
            switch item {
            case .sidebar: controller.isSidebarEnabled
            case .settings: controller.isSettingsEnabled
            case .siteRules: controller.isSiteRulesEnabled
            case .plugins: controller.isPluginsEnabled
            }
        }
        func edit(_ item: Item, value: String, id: UUID) {
            let old = state.sidebarSyncState
            switch item {
            case .sidebar:
                var favorites = old.favorites.filter { $0.id != id }
                favorites.append(Favorite(id: id, url: URL(string: "https://example.test/favorite")!, title: value, personaID: Persona.defaultID))
                state.sidebarSyncState = .init(personas: old.personas, spaces: old.spaces, folders: old.folders,
                    favorites: favorites, pinnedTabs: old.pinnedTabs, siteRules: old.siteRules)
            case .settings: defaults.set(value, forKey: "ARCHAppearance")
            case .siteRules:
                var rules = old.siteRules.filter { $0.id != id }
                rules.append(SiteRule(id: id, host: "example.test", pathPrefix: "/\(value)", spaceID: old.spaces[0].id,
                    personaID: Persona.defaultID, modifiedAt: now))
                state.sidebarSyncState = .init(personas: old.personas, spaces: old.spaces, folders: old.folders,
                    favorites: old.favorites, pinnedTabs: old.pinnedTabs, siteRules: rules)
            case .plugins:
                state.pluginSyncItems = [.init(personaID: Persona.defaultID,
                    item: PluginSyncItem(id: "org.example.choices", manifestID: "org.example.choices", name: value, kind: "script", isEnabled: true))]
            }
        }
        func notify(_ item: Item) throws {
            switch item {
            case .sidebar, .siteRules: try state.saveNow().get()
            case .settings: controller.settingsChanged()
            case .plugins: state.onPluginSyncChange?()
            }
        }
        func value(_ item: Item, id: UUID) -> String? {
            switch item {
            case .sidebar: state.sidebarSyncState.favorites.first { $0.id == id }?.title
            case .settings: defaults.string(forKey: "ARCHAppearance")
            case .siteRules: state.sidebarSyncState.siteRules.first { $0.id == id }?.pathPrefix.dropFirst().description
            case .plugins: state.pluginSyncItems.first?.item.name
            }
        }
        func record(_ item: Item, id: UUID) throws -> SyncRecord {
            switch item {
            case .sidebar: return try #require(SidebarRecords.records(from: state.sidebarSyncState, foundAt: now).first { $0.recordType == .favorite && $0.recordName == id.uuidString })
            case .siteRules: return try #require(SidebarRecords.records(from: state.sidebarSyncState, foundAt: now).first { $0.recordType == .siteRule && $0.recordName == id.uuidString })
            case .settings: return SyncRecord(recordType: .setting, recordName: "ARCHAppearance",
                fields: ["value": .text(defaults.string(forKey: "ARCHAppearance")!)], modifiedAt: now)
            case .plugins: return try #require(PluginRecords.records(from: state.pluginSyncItems, foundAt: now).first)
            }
        }
        func changed(_ row: SyncRecord, item: Item, to value: String) -> SyncRecord {
            var result = row
            let field: SyncField
            let text: String
            switch item {
            case .sidebar: field = .title; text = value
            case .settings: field = .value; text = value
            case .siteRules: field = .pathPrefix; text = "/\(value)"
            case .plugins: field = .name; text = value
            }
            result[field] = .text(text)
            result.fieldModifiedAt[field.rawValue] = now
            result.modifiedAt = now
            return result
        }
        func waitUntil(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func clean() {
            controller?.applicationWillTerminate()
            controller = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func allChoicesDefaultOnAndPersistOnlyOnThisMac() async {
        let f = Fixture(); defer { f.clean() }
        #expect(Item.allCases.allSatisfy(f.enabled))
        #expect(f.controller.showRemoteTabs)
        for item in Item.allCases { await f.set(item, false) }
        f.controller.setShowRemoteTabs(false)
        f.makeController()
        #expect(Item.allCases.allSatisfy { !f.enabled($0) })
        #expect(!f.controller.showRemoteTabs && !f.state.showRemoteTabs)
        let keys = f.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("ARCHSync") || $0 == SyncController.showRemoteTabsKey }
        #expect(!keys.isEmpty)
        #expect(keys.allSatisfy { SyncedSettings.setting(forKey: $0) == nil })
        #expect(f.engines.isEmpty)
    }

    @Test func sidebarWarningsFollowOnlyTheMainAndSidebarChoices() async throws {
        let f = Fixture(); defer { f.clean() }
        #expect(!f.state.isSidebarSyncEnabled)
        _ = try await f.start()
        #expect(f.state.isSidebarSyncEnabled)
        for item in [Item.settings, .siteRules, .plugins] {
            await f.set(item, false)
            #expect(f.state.isSidebarSyncEnabled)
        }
        f.controller.setShowRemoteTabs(false)
        #expect(f.state.isSidebarSyncEnabled)
        await f.set(.sidebar, false)
        #expect(!f.state.isSidebarSyncEnabled)
        await f.set(.sidebar, true)
        #expect(f.state.isSidebarSyncEnabled)
        await f.controller.setEnabled(false)
        #expect(!f.state.isSidebarSyncEnabled)
        await f.controller.setEnabled(true)
        #expect(f.state.isSidebarSyncEnabled)
    }

    @Test(arguments: Item.allCases)
    func disabledItemFiltersUploadsAndArrivalsThenResumesFromServer(item: Item) async throws {
        let f = Fixture(); defer { f.clean() }
        let id = UUID()
        f.edit(item, value: "light", id: id)
        let engine = try await f.start()
        let original = try f.record(item, id: id)
        #expect(f.server[original.recordName] != nil)
        await f.set(item, false)
        f.now.addTimeInterval(100)
        f.edit(item, value: "dark", id: id)
        try f.notify(item)
        let server = f.changed(original, item: item, to: "system")
        f.server[server.recordName] = SyncCloudKitRecords.ckRecord(from: server)
        engine.fetchScript = [.fetchedChanges(.init(records: [SyncCloudKitRecords.ckRecord(from: server)]))]
        await f.controller.refresh()
        try await engine.sendChanges()
        #expect(f.value(item, id: id) == "dark")
        #expect(f.mirror.unapplied.contains(server.recordName))
        #expect(!engine.pendingChanges.contains(.saveRecord(server.recordName)))
        #expect(!engine.pendingChanges.contains(.deleteRecord(server.recordName)))
        let pausedCloud = try #require(f.server[server.recordName])
        #expect(SyncCloudKitRecords.syncRecord(from: pausedCloud) == server)
        let fetches = engine.fetchCount
        await f.set(item, true)
        #expect(engine.fetchCount > fetches)
        #expect(f.value(item, id: id) == "system")
        #expect(!f.mirror.unapplied.contains(server.recordName))
        f.now.addTimeInterval(100)
        f.edit(item, value: "light", id: id)
        try f.notify(item)
        try await engine.sendChanges()
        let sentCloud = try #require(f.server[server.recordName])
        let sent = try #require(SyncCloudKitRecords.syncRecord(from: sentCloud))
        let local = try f.record(item, id: id)
        #expect(sent.fields.filter { $0.key != "order" } == local.fields.filter { $0.key != "order" })
        let incoming = f.changed(server, item: item, to: "dark")
        engine.fetchScript = [.fetchedChanges(.init(records: [SyncCloudKitRecords.ckRecord(from: incoming)]))]
        await f.controller.refresh()
        #expect(f.value(item, id: id) == "dark")
    }

    @Test(arguments: [Item.sidebar, .siteRules, .plugins])
    func pausedDeletionSurvivesRelaunchAndAppliesOnlyWhenEnabled(item: Item) async throws {
        let f = Fixture(); defer { f.clean() }
        let id = UUID()
        f.edit(item, value: "light", id: id)
        let engine = try await f.start()
        let row = try f.record(item, id: id)
        await f.set(item, false)
        engine.fetchScript = [.fetchedChanges(.init(deletions: [.init(recordID: SyncCloudKitRecords.recordID(named: row.recordName), recordType: row.recordType.rawValue)]))]
        await f.controller.refresh()
        #expect(f.value(item, id: id) == "light")
        await f.controller.setEnabled(false)
        f.makeController()
        let restarted = try await f.start()
        #expect(f.value(item, id: id) == "light")
        #expect(!restarted.batches.contains { $0.records.contains { $0.recordID.recordName == row.recordName } })
        await f.set(item, true)
        #expect(f.value(item, id: id) == nil)
        #expect(!restarted.pendingChanges.contains(.saveRecord(row.recordName)))
    }

    @Test(arguments: Item.allCases)
    func disabledBeforeFirstSyncKeepsLocalAndCloudValuesUntilEnabled(item: Item) async throws {
        let f = Fixture(); defer { f.clean() }
        let id = UUID()
        f.edit(item, value: "light", id: id)
        let row = try f.record(item, id: id)
        f.server[row.recordName] = SyncCloudKitRecords.ckRecord(from: row)
        f.nextFetch = [.fetchedChanges(.init(records: [SyncCloudKitRecords.ckRecord(from: row)]))]
        await f.set(item, false)
        f.edit(item, value: "dark", id: id)
        let engine = try await f.start()
        #expect(f.value(item, id: id) == "dark")
        #expect(f.mirror.unapplied.contains(row.recordName))
        #expect(!engine.batches.contains { $0.records.contains { $0.recordID.recordName == row.recordName } || $0.deletedRecordNames.contains(row.recordName) })
        await f.set(item, true)
        #expect(f.value(item, id: id) == "light")
    }

    @Test(arguments: [Item.sidebar, .siteRules, .plugins])
    func disabledRelaunchDiscardsRestoredDeletesWithoutRemovingCloudRows(item: Item) async throws {
        let f = Fixture(); defer { f.clean() }
        let id = UUID()
        f.edit(item, value: "light", id: id)
        let engine = try await f.start()
        let row = try f.record(item, id: id)
        let old = f.state.sidebarSyncState
        f.state.sidebarSyncState = .init(personas: old.personas, spaces: old.spaces, folders: old.folders,
            favorites: item == .sidebar ? [] : old.favorites, pinnedTabs: old.pinnedTabs,
            siteRules: item == .siteRules ? [] : old.siteRules)
        if item == .plugins { f.state.pluginSyncItems = [] }
        try f.notify(item)
        #expect(engine.pendingChanges.contains(.deleteRecord(row.recordName)))
        engine.deliver([.stateUpdate(engine.stateSerialization)])
        await f.controller.setEnabled(false)
        await f.set(item, false)
        f.makeController()
        let restarted = try await f.start()
        #expect(!restarted.batches.contains { $0.deletedRecordNames.contains(row.recordName) })
        #expect(f.server[row.recordName] != nil && f.value(item, id: id) == nil)
        await f.set(item, true)
        #expect(f.value(item, id: id) == "light")
    }

    @Test(arguments: [Item.sidebar, .siteRules])
    func localDeletionWhilePausedDoesNotDeleteTheCloudCopyOnResume(item: Item) async throws {
        let f = Fixture(); defer { f.clean() }
        let id = UUID()
        f.edit(item, value: "light", id: id)
        let engine = try await f.start()
        let row = try f.record(item, id: id)
        await f.set(item, false)
        let old = f.state.sidebarSyncState
        f.state.sidebarSyncState = .init(personas: old.personas, spaces: old.spaces, folders: old.folders,
            favorites: item == .sidebar ? [] : old.favorites, pinnedTabs: old.pinnedTabs,
            siteRules: item == .siteRules ? [] : old.siteRules)
        try f.notify(item)
        try await engine.sendChanges()
        #expect(f.server[row.recordName] != nil)
        await f.set(item, true)
        #expect(f.value(item, id: id) == "light")
        #expect(!engine.pendingChanges.contains(.deleteRecord(row.recordName)))
    }

    @Test func sidebarOffHoldsRulesAndPluginsWhoseDestinationsAreOnlyInCloud() async throws {
        let f = Fixture(); defer { f.clean() }
        await f.controller.setSidebarEnabled(false)
        let owner = Persona(name: "Work")
        let space = Space(name: "Projects", personaID: owner.id)
        let rule = SiteRule(host: "work.example.test", spaceID: space.id, personaID: owner.id)
        let plugin = PersonaPluginSyncItem(personaID: owner.id,
            item: PluginSyncItem(id: "org.example.remote", manifestID: "org.example.remote", name: "Remote", kind: "script", isEnabled: true))
        let rows = try SidebarRecords.records(from: .init(personas: [owner], spaces: [space], folders: [], favorites: [], pinnedTabs: [], siteRules: [rule]), foundAt: f.now)
            + PluginRecords.records(from: [plugin], foundAt: f.now)
        f.nextFetch = [.fetchedChanges(.init(records: rows.map { SyncCloudKitRecords.ckRecord(from: $0) }))]
        let engine = try await f.start()
        #expect(!f.state.sidebarSyncState.personas.contains { $0.id == owner.id })
        #expect(f.state.sidebarSyncState.siteRules.isEmpty && f.state.pluginSyncItems.isEmpty)
        let held = Set(rows.filter { $0.recordType == .siteRule || $0.recordType == .plugin }.map(\.recordName))
        #expect(held.isSubset(of: f.mirror.unapplied))
        #expect(!engine.batches.contains { batch in batch.deletedRecordNames.contains { held.contains($0) } })
        await f.controller.setSidebarEnabled(true)
        #expect(f.state.sidebarSyncState.personas.contains { $0.id == owner.id })
        #expect(f.state.sidebarSyncState.siteRules.contains { $0.id == rule.id })
        #expect(f.state.pluginSyncItems.contains(plugin))
    }

    @Test func deletingALocalPersonaStillDeletesItsPluginAcrossSeparateBatches() async throws {
        let f = Fixture(); defer { f.clean() }
        let owner = Persona(name: "Work")
        let space = Space(name: "Projects", personaID: owner.id)
        let plugin = PersonaPluginSyncItem(personaID: owner.id,
            item: PluginSyncItem(id: "org.example.owned", manifestID: "org.example.owned", name: "Owned", kind: "script", isEnabled: true))
        let initial = f.state.sidebarSyncState
        f.state.sidebarSyncState = .init(personas: initial.personas + [owner], spaces: initial.spaces + [space],
            folders: [], favorites: [], pinnedTabs: [])
        f.state.pluginSyncItems = [plugin]
        let engine = try await f.start()
        let pluginRows = try PluginRecords.records(from: [plugin], foundAt: f.now)
        let pluginName = try #require(pluginRows.first).recordName
        #expect(f.server[pluginName] != nil)
        engine.batchLimit = 1
        f.state.sidebarSyncState = initial
        f.state.pluginSyncItems = []
        try f.state.saveNow().get()
        #expect(engine.pendingChanges.contains(.deleteRecord(pluginName)))
        try await engine.sendChanges()
        let deleted = engine.batches.flatMap(\.deletedRecordNames)
        #expect(deleted.contains(owner.id.uuidString) && deleted.contains(space.id.uuidString) && deleted.contains(pluginName))
        #expect(f.server[owner.id.uuidString] == nil && f.server[space.id.uuidString] == nil && f.server[pluginName] == nil)
        #expect(!engine.pendingChanges.contains(.deleteRecord(pluginName)))
    }

    @Test func openTabsSwitchDeletesOnlyThisMacAndRefetchesBeforeResuming() async throws {
        let f = Fixture(); defer { f.clean() }
        f.state.hasOpenTabs = true
        let other = UUID().uuidString
        let otherRows = RemoteTabsRecords.records(from: f.state.openTabsSyncState, deviceID: other, deviceName: "Laptop", at: f.now)
        for row in otherRows { f.server[row.recordName] = SyncCloudKitRecords.ckRecord(from: row) }
        f.nextFetch = [.fetchedChanges(.init(records: otherRows.map { SyncCloudKitRecords.ckRecord(from: $0) }))]
        let engine = try await f.start()
        let own = try #require(f.defaults.string(forKey: SyncController.remoteDeviceIDKey))
        func ownRows() -> [SyncRecord] {
            f.server.values.compactMap(SyncCloudKitRecords.syncRecord(from:)).filter { RemoteTabsRecords.owns($0, deviceID: own) }
        }
        await f.waitUntil { !ownRows().isEmpty }
        #expect(!ownRows().isEmpty && f.state.remoteTabGroups.count == 1)
        f.state.onShowRemoteTabsChange?(false)
        await f.waitUntil { ownRows().isEmpty }
        #expect(!f.controller.showRemoteTabs && f.state.remoteTabGroups.isEmpty && ownRows().isEmpty)
        #expect(otherRows.allSatisfy { f.server[$0.recordName] != nil })
        let fetches = engine.fetchCount
        f.controller.setShowRemoteTabs(true)
        await f.waitUntil { engine.fetchCount > fetches && !ownRows().isEmpty }
        #expect(engine.fetchCount > fetches && !ownRows().isEmpty)
        #expect(f.state.remoteTabGroups.count == 1)
        #expect(!engine.batches.contains { batch in batch.deletedRecordNames.contains { name in otherRows.contains { $0.recordName == name } } })
    }

    @Test func immediatelyDisablingRemoteTabsAgainReleasesTheFetchHold() async throws {
        let f = Fixture(); defer { f.clean() }
        let engine = try await f.start()
        f.controller.setShowRemoteTabs(false)
        let fetches = engine.fetchCount
        f.controller.setShowRemoteTabs(true)
        f.controller.setShowRemoteTabs(false)
        await f.waitUntil { engine.fetchCount > fetches && f.controller.canSendRecords }
        #expect(engine.fetchCount > fetches && f.controller.canSendRecords)
        #expect(!f.controller.showRemoteTabs && !f.state.showRemoteTabs)
        f.edit(.settings, value: "dark", id: UUID())
        try f.notify(.settings)
        try await engine.sendChanges()
        let sent = try #require(f.server["ARCHAppearance"])
        #expect(SyncCloudKitRecords.syncRecord(from: sent)?[.value] == .text("dark"))
    }
}
