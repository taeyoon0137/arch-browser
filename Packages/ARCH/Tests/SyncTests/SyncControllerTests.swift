import ARCHEngine
import Browsing
import CloudKit
import Foundation
import Testing
@testable import Sync

@MainActor @Suite struct SyncControllerTests {
    private final class Sidebar: SyncedSidebar {
        let needsFullSidebarSync = false
        let defaultEngine = EngineKind.webKit
        func finishSidebarSyncRecovery() {}
        var sidebarSyncState: SidebarSyncState
        var onSidebarSyncSave: ((SidebarSyncState) -> Void)?
        var firstReplacements: [SidebarSyncReplacements] = []
        var failSave = false
        var beforeSave: (() throws -> Void)?
        var saved: SidebarSyncState?

        init() {
            sidebarSyncState = SidebarSyncState(personas: [Persona(id: Persona.defaultID, name: "Default")],
                                                spaces: [Space(name: "Personal")], folders: [], favorites: [], pinnedTabs: [])
        }

        func applySidebarSync(_ state: SidebarSyncState, deletions: SidebarSyncDeletions) { sidebarSyncState = state }
        func applyFirstSidebarSync(_ state: SidebarSyncState, replacements: SidebarSyncReplacements) {
            firstReplacements.append(replacements)
            sidebarSyncState = state
        }
        @discardableResult func saveNow() -> Result<Void, Error> {
            Result {
                try beforeSave?()
                if failSave { throw CocoaError(.fileWriteOutOfSpace) }
                saved = sidebarSyncState
                onSidebarSyncSave?(sidebarSyncState)
            }
        }
        func renameSpace(_ name: String) {
            let state = sidebarSyncState
            var spaces = state.spaces
            spaces[0].name = name
            sidebarSyncState = .init(personas: state.personas, spaces: spaces, folders: state.folders, favorites: state.favorites, pinnedTabs: state.pinnedTabs)
        }
    }

    @MainActor private final class Fixture {
        let database = SyncDatabase(containerIdentifier: "test.container", environment: "Development")
        let name = UUID().uuidString
        let directory: URL
        let defaults: UserDefaults
        let center = NotificationCenter()
        let sidebar = Sidebar()
        var clock = Date(timeIntervalSinceReferenceDate: 100)
        var engines: [FakeSyncEngine] = []
        var onCreate: ((FakeSyncEngine) -> Void)?
        var checks = 0
        var answer: (() async -> SyncAvailability.Status)?
        var controller: SyncController!

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            defaults = UserDefaults(suiteName: name)!
            newController()
        }
        func newController() {
            controller = SyncController(sidebar: sidebar, directory: directory, defaults: defaults, notifications: center,
                check: { [unowned self] in
                    checks += 1
                    if let answer { return await answer() }
                    return .available(database)
                }, factory: FakeSyncEngine.factory { [unowned self] engine in engines.append(engine); onCreate?(engine) },
                now: { [unowned self] in clock })
        }
        var file: URL { directory.appendingPathComponent(SyncMirror.fileName) }
        var copy: SyncMirror { SyncMirror.read(from: file, database: database) }
        var space: Space { sidebar.sidebarSyncState.spaces[0] }

        func clean() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        func startAndSend() async throws -> FakeSyncEngine {
            await controller.setEnabled(true)
            let engine = try #require(engines.last)
            try await engine.sendChanges()
            return engine
        }
        /// Waits for the send that the controller starts once a hold ends.
        func waitForBatches(_ count: Int, of engine: FakeSyncEngine) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while engine.batches.count < count && ContinuousClock.now < deadline { await Task.yield() }
        }
        func setAppearance(_ value: String) {
            defaults.set(value, forKey: "ARCHAppearance")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        func setting(_ text: String, at time: Double) -> CKRecord {
            SyncCloudKitRecords.ckRecord(from: SyncRecord(recordType: .setting, recordName: "ARCHAppearance", fields: ["value": .text(text)],
                                                         modifiedAt: Date(timeIntervalSinceReferenceDate: time)))
        }
    }

    @Test func launchAndActivationReadNoAccountUntilTheUserRequestsSync() async throws {
        let f = Fixture()
        defer { f.clean() }
        var running: [Bool] = []
        f.controller.onRunningChange = { running.append($0) }
        await f.controller.refreshIfRequested()
        await f.controller.refreshIfRequested()
        #expect(f.checks == 0 && f.engines.isEmpty && running.isEmpty && !f.controller.hasCheckedAvailability)
        #expect(f.sidebar.onSidebarSyncSave == nil)
        await f.controller.setEnabled(true)
        #expect(f.checks == 1 && f.engines.count == 1 && running == [true] && f.sidebar.onSidebarSyncSave != nil)
        await f.controller.refreshIfRequested()
        #expect(f.checks == 2 && running == [true])
        await f.controller.setEnabled(false)
        #expect(running == [true, false] && f.sidebar.onSidebarSyncSave == nil)
        f.newController()
        await f.controller.refreshIfRequested()
        #expect(f.checks == 2 && f.engines.count == 1)
    }

    @Test func firstSyncJoinsPersonalAndAppliesSettingsOnlyAfterFetch() async throws {
        let f = Fixture()
        defer { f.clean() }
        await f.controller.refresh()
        #expect(!f.controller.isEnabled && f.engines.isEmpty && f.checks == 1)
        let local = f.space
        let remote = Space(name: "Personal")
        let remoteState = SidebarSyncState(personas: [Persona(id: Persona.defaultID, name: "Remote")], spaces: [remote],
                                           folders: [], favorites: [], pinnedTabs: [])
        let remoteRows = try SidebarRecords.records(from: remoteState, foundAt: f.clock).map { SyncCloudKitRecords.ckRecord(from: $0) }
        f.setAppearance("light")
        f.onCreate = {
            $0.fetchScript = [.fetchedChanges(.init(records: remoteRows + [f.setting("dark", at: 90)]))]
        }
        await f.controller.setEnabled(true)
        let engine = try #require(f.engines.first)
        #expect(f.controller.canSendRecords && engine.pendingChanges.isEmpty)
        #expect(f.sidebar.firstReplacements.first?.spaces == [local.id: remote.id])
        #expect(f.space.id == remote.id && f.sidebar.saved?.personas.first?.name == "Remote")
        #expect(f.defaults.string(forKey: "ARCHAppearance") == "dark" && f.copy.records.count == 3)
        #expect(!engine.pendingChanges.contains(.saveZone))
        await f.controller.setEnabled(false)
        #expect(engine.isStopped && !f.controller.canSendRecords)
    }

    @Test func holdsEveryPageAndTokenUntilSessionWriteSucceedsAndReplaysTheSavedSession() async throws {
        let f = Fixture()
        defer { f.clean() }
        let local = f.space
        let fresh = Space(name: "Personal")
        let remote = SidebarSyncState(personas: f.sidebar.sidebarSyncState.personas, spaces: [fresh], folders: [], favorites: [], pinnedTabs: [])
        let rows = try SidebarRecords.records(from: remote, foundAt: f.clock).map { SyncCloudKitRecords.ckRecord(from: $0) }
        f.onCreate = {
            $0.fetchScript = [.fetchedChanges(.init(records: rows))]
            $0.fetchFailure = .networkUnavailable
        }
        await f.controller.setEnabled(true)
        let engine = try #require(f.engines.first)
        #expect(!f.controller.canSendRecords && f.space.id == local.id && !FileManager.default.fileExists(atPath: f.file.path))
        f.sidebar.renameSpace("Personal")
        try f.sidebar.saveNow().get()
        try await engine.sendChanges()
        #expect(engine.pendingChanges.isEmpty && engine.batches.isEmpty)
        f.sidebar.failSave = true
        await f.controller.refresh()
        #expect(!f.controller.canSendRecords && f.space.id == fresh.id && f.sidebar.saved?.spaces.first?.id == local.id)
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        f.sidebar.failSave = false
        f.sidebar.beforeSave = { #expect(!FileManager.default.fileExists(atPath: f.file.path)) }
        await f.controller.refresh()
        #expect(f.controller.canSendRecords && f.sidebar.saved?.spaces.first?.id == fresh.id && f.copy.records.count == 2)
        f.sidebar.beforeSave = nil
        let token = try #require(f.copy.engineState)
        f.onCreate = nil
        f.newController()
        await f.controller.refresh()
        #expect(f.engines.last?.startedFrom == token && f.sidebar.saved?.spaces.first?.id == fresh.id)
        #expect(f.engines.last?.pendingChanges.isEmpty == true)
    }

    /// A record this build cannot apply, such as a space with a newer build's tint, waits on the server with the tab in it: the rest of the fetch applies, and a later save neither deletes nor overwrites them. A later launch that can apply them, as a newer build can, shows them instead of deleting them.
    @Test func aRecordThisBuildCannotApplyWaitsWhileTheRestSyncs() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let lab = UUID().uuidString, labTab = UUID().uuidString, work = UUID().uuidString
        func row(_ type: SyncRecordType, _ name: String, _ fields: [String: SyncValue]) -> CKRecord {
            SyncCloudKitRecords.ckRecord(from: SyncRecord(recordType: type, recordName: name, fields: fields, modifiedAt: f.clock))
        }
        func space(_ name: String, tint: String) -> CKRecord {
            row(.space, name, ["persona": .reference("default"), "name": .text("Room"), "symbol": .text("star"), "tint": .text(tint), "order": .number(5)])
        }
        engine.fetchScript = [.fetchedChanges(.init(records: [space(work, tint: "green"), space(lab, tint: "ultraviolet"),
            row(.tab, labTab, ["persona": .reference("default"), "space": .reference(lab), "engine": .text("webKit"), "order": .number(1)])]))]
        await f.controller.refresh()
        #expect(f.controller.lastError == nil && f.controller.lastSync != nil)
        #expect(f.sidebar.sidebarSyncState.spaces.map(\.id.uuidString).contains(work))
        #expect(!f.sidebar.sidebarSyncState.spaces.map(\.id.uuidString).contains(lab) && f.sidebar.sidebarSyncState.pinnedTabs.isEmpty)
        #expect(f.copy.records[lab] != nil && f.copy.records[labTab] != nil)
        f.sidebar.renameSpace("Edited")
        try f.sidebar.saveNow().get()
        #expect(engine.pendingChanges == [.saveRecord(f.space.id.uuidString)])
        #expect(f.copy.unapplied == [lab, labTab])
        // A launch of a build that reads the tint, as this file then holds it.
        try await engine.sendChanges()
        var file = f.copy
        file.records[lab] = space(lab, tint: "green")
        try file.write(to: f.file, database: f.database)
        f.newController()
        await f.controller.refresh()
        let later = try #require(f.engines.last)
        #expect(f.sidebar.sidebarSyncState.spaces.map(\.id.uuidString).contains(lab))
        #expect(f.sidebar.sidebarSyncState.pinnedTabs.map(\.id.uuidString) == [labTab])
        #expect(!later.pendingChanges.contains(.deleteRecord(lab)) && !later.pendingChanges.contains(.deleteRecord(labTab)))
        #expect(f.copy.unapplied.isEmpty)
    }

    @Test func settingsAndSidebarPreserveTheirOwnQueueAndNeverUploadAnUnsavedSidebarEdit() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        #expect(engine.sentZoneChanges == [.saveZone] && engine.pendingChanges.isEmpty && engine.batches.count == 1)
        let id = f.space.id.uuidString
        f.sidebar.renameSpace("Edited")
        try f.sidebar.saveNow().get()
        let pending = try #require(f.copy.pendingSaves.first { $0.recordName == id })
        f.setAppearance("dark")
        #expect(Set(engine.pendingChanges) == [.saveRecord(id), .saveRecord("ARCHAppearance")])
        #expect(f.copy.pendingSaves.first { $0.recordName == id } == pending)
        f.sidebar.renameSpace("Unsaved")
        f.sidebar.failSave = true
        #expect(throws: (any Error).self) { try f.sidebar.saveNow().get() }
        try await engine.sendChanges()
        #expect(engine.pendingChanges.isEmpty && f.copy.pendingSaves.isEmpty)
        let sent = try #require(f.copy.records[id].flatMap(SyncCloudKitRecords.syncRecord(from:)))
        #expect(sent[.name] == .text("Edited"))
        try await engine.sendChanges()
        #expect(engine.batches.count == 2)
    }

    @Test func settingsMergeUsesPendingAndHeldEditsAndNeverEchoesRefusedOrForeignRecords() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.setAppearance("system")
        let engine = try await f.startAndSend()
        f.setAppearance("dark")
        engine.deliver([.fetchStarted, .fetchedChanges(.init(records: [f.setting("light", at: 80)])), .fetchEnded(failure: nil)])
        #expect(f.defaults.string(forKey: "ARCHAppearance") == "dark" && engine.pendingChanges == [.saveRecord("ARCHAppearance")])
        engine.deliver([.fetchStarted, .fetchedChanges(.init(records: [f.setting("newer-build", at: 200)])), .fetchEnded(failure: nil)])
        #expect(f.defaults.string(forKey: "ARCHAppearance") == "dark" && engine.pendingChanges.isEmpty)
        #expect(f.copy.records["ARCHAppearance"]?.encryptedValues["value"] as? String == "newer-build")
        f.clock = Date(timeIntervalSinceReferenceDate: 300)
        engine.deliver([.fetchStarted, .fetchedChanges(.init(records: [f.setting("dark", at: 250)]))])
        f.setAppearance("system")
        #expect(!f.controller.canSendRecords && engine.pendingChanges.isEmpty)
        engine.deliver([.fetchEnded(failure: nil)])
        #expect(f.defaults.string(forKey: "ARCHAppearance") == "system" && engine.pendingChanges == [.saveRecord("ARCHAppearance")])
        engine.deliver([.fetchStarted, .fetchedChanges(.init(records: [f.setting("light", at: 350)])), .fetchEnded(failure: nil)])
        #expect(f.defaults.string(forKey: "ARCHAppearance") == "light" && engine.pendingChanges.isEmpty)
        let zone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        let id = CKRecord.ID(recordName: "ARCHAppearance", zoneID: zone)
        let foreign = CKRecord(recordType: "Setting", recordID: id)
        foreign.encryptedValues["value"] = "dark"
        engine.deliver([.fetchStarted, .fetchedChanges(.init(records: [foreign], deletions: [.init(recordID: id, recordType: "Setting")])),
                        .zoneDeleted(zone, .purged), .fetchEnded(failure: nil)])
        #expect(f.controller.isEnabled && f.defaults.string(forKey: "ARCHAppearance") == "light" && engine.pendingChanges.isEmpty)
    }

    @Test func relaunchedControllerRestoresPendingPayloadAndMovesAsideAnotherDatabasesFile() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let id = f.space.id.uuidString
        f.sidebar.renameSpace("Offline")
        try f.sidebar.saveNow().get()
        engine.deliver([.stateUpdate(engine.stateSerialization)])
        let previous = f.copy
        f.newController()
        await f.controller.refresh()
        let resumed = try #require(f.engines.last)
        #expect(resumed.startedFrom == previous.engineState && previous.pendingSaves.map(\.recordName) == [id])
        await f.waitForBatches(1, of: resumed)
        #expect(resumed.batches.first?.records.first?.encryptedValues["name"] as? String == "Offline")
        #expect(f.copy.pendingSaves.isEmpty && resumed.batches.count == 1 && resumed.pendingChanges.isEmpty)
        let other = SyncDatabase(containerIdentifier: "different", environment: "Production")
        try f.copy.write(to: f.file, database: other)
        f.newController()
        await f.controller.refresh()
        #expect(f.engines.last?.startedFrom == nil && f.engines.last?.pendingChanges.contains(.saveZone) == true)
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("sync.other-database.json").path))
    }
    @Test func heldSidebarSavesPublishOnlyAfterACompletedFetch() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        engine.deliver([.fetchStarted])
        f.sidebar.renameSpace("Written during fetch")
        try f.sidebar.saveNow().get()
        try await engine.sendChanges()
        #expect(!f.controller.canSendRecords && engine.pendingChanges.isEmpty)
        engine.deliver([.fetchEnded(failure: nil)])
        #expect(engine.pendingChanges == [.saveRecord(f.space.id.uuidString)])
        // The engine asked for this batch while the fetch held it and asks for none again, so the controller sends it.
        await f.waitForBatches(2, of: engine)
        #expect(f.copy.records[f.space.id.uuidString]?.encryptedValues["name"] as? String == "Written during fetch")
        #expect(engine.batches.count == 2 && engine.pendingChanges.isEmpty)
    }

    @Test func aRefusedSaveMergesAgainstItsBaseAndResendsOnlyTheSurvivingFields() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let id = f.space.id.uuidString
        var remote = try #require(f.copy.records[id].flatMap(SyncCloudKitRecords.syncRecord(from:)))
        f.clock = Date(timeIntervalSinceReferenceDate: 200)
        f.sidebar.renameSpace("Local title")
        try f.sidebar.saveNow().get()
        remote[.symbol] = .text("book")
        remote.fieldModifiedAt["symbol"] = Date(timeIntervalSinceReferenceDate: 250)
        remote.modifiedAt = Date(timeIntervalSinceReferenceDate: 250)
        let conflict = SyncCloudKitRecords.ckRecord(from: remote)
        conflict["futureField"] = "kept" as NSString
        engine.saveFailures[id] = .serverRecordChanged(conflict)
        try await engine.sendChanges()
        #expect(engine.batches.count == 3 && engine.pendingChanges.isEmpty)
        let resent = try #require(engine.batches.last?.records.first)
        #expect(resent["futureField"] as? String == "kept")
        #expect(f.space.name == "Local title" && f.space.symbol == "book")
        #expect(f.copy.pendingSaves.isEmpty && f.copy.records[id]?.encryptedValues["name"] as? String == "Local title")
        f.sidebar.renameSpace("No quota")
        try f.sidebar.saveNow().get()
        engine.saveFailures[id] = .other(.quotaExceeded)
        try await engine.sendChanges()
        #expect(engine.batches.count == 4 && engine.pendingChanges.isEmpty && f.controller.lastError != nil)
        #expect(f.copy.pendingSaves.count == 1)
        await f.controller.refresh()
        await f.waitForBatches(5, of: engine)
        #expect(engine.batches.count == 5 && engine.pendingChanges.isEmpty && f.copy.pendingSaves.isEmpty)
    }

    @Test(arguments: [false, true]) func unknownItemWaitsForFetchBeforeDeletingOrResending(tombstone: Bool) async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let id = f.space.id.uuidString
        f.sidebar.renameSpace("Local edit")
        try f.sidebar.saveNow().get()
        let withOldTag = try #require(f.copy.records[id]?.copy() as? CKRecord)
        withOldTag["priorZoneField"] = "previous zone"
        engine.deliver([.fetchedChanges(.init(records: [withOldTag])), .fetchEnded(failure: nil)])
        if tombstone {
            engine.fetchScript = [.fetchedChanges(.init(deletions: [.init(recordID: SyncCloudKitRecords.recordID(named: id), recordType: "Space")]))]
        }
        engine.saveFailures[id] = .unknownItem
        try await engine.sendChanges()
        let deadline = ContinuousClock.now + .seconds(5)
        while (!f.controller.canSendRecords || engine.fetchCount < 2) && ContinuousClock.now < deadline { await Task.yield() }
        #expect(f.controller.canSendRecords && f.copy.records[id] == nil)
        if tombstone {
            #expect(f.space.id.uuidString != id && !engine.pendingChanges.contains(.saveRecord(id)))
        } else {
            #expect(f.space.id.uuidString == id && f.space.name == "Local edit")
            #expect(engine.pendingChanges == [.saveRecord(id)] && f.controller.record(toSave: id)?["priorZoneField"] == nil)
        }
        try await engine.sendChanges()
        #expect(engine.pendingChanges.isEmpty)
    }

    @Test func missingZoneCreatesOnlyAnEmptyZoneAndAFormerZoneCannotUploadAgain() async throws {
        let f = Fixture()
        defer { f.clean() }
        await f.controller.setEnabled(true)
        let engine = try #require(f.engines.first)
        let id = f.space.id.uuidString
        engine.saveFailures[id] = .zoneNotFound
        try await engine.sendChanges()
        #expect(f.controller.isEnabled && engine.pendingChanges.contains(.saveZone))
        #expect(engine.batches.count == 1 && f.copy.records.isEmpty)
        try await engine.sendChanges()
        #expect(f.copy.records.count == 2)
        f.sidebar.renameSpace("Keep this Mac")
        try f.sidebar.saveNow().get()
        engine.saveFailures[id] = .zoneNotFound
        try await engine.sendChanges()
        let deadline = ContinuousClock.now + .seconds(5)
        while f.controller.isEnabled && ContinuousClock.now < deadline { await Task.yield() }
        #expect(!f.controller.isEnabled && f.space.name == "Keep this Mac")
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        #expect(!engine.pendingChanges.contains(.saveZone))
    }

    @Test func resetRebuildsWithoutOldZoneFieldsAndSignOutIgnoresLateEvents() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let id = f.space.id.uuidString
        let old = try #require(f.copy.records[id]?.copy() as? CKRecord)
        old["oldZoneField"] = "old"
        engine.deliver([.fetchedChanges(.init(records: [old])), .fetchEnded(failure: nil)])
        f.sidebar.renameSpace("Keep")
        try f.sidebar.saveNow().get()
        engine.deliver([.fetchStarted, .zoneDeleted(SyncCloudKitRecords.zoneID, .encryptedDataReset), .fetchEnded(failure: nil)])
        #expect(f.controller.isEnabled && f.space.name == "Keep" && f.copy.records.isEmpty)
        #expect(Set(engine.pendingChanges) == [.saveZone, .saveRecord("default"), .saveRecord(id)])
        #expect(f.controller.record(toSave: id)?["oldZoneField"] == nil)
        engine.deliver([.accountChange(.switchAccounts), .stateUpdate(Data([0])), .fetchedChanges(.init(records: [old])), .fetchEnded(failure: nil)])
        #expect(!f.controller.isEnabled && f.space.name == "Keep" && !FileManager.default.fileExists(atPath: f.file.path))
        await f.controller.setEnabled(true)
        #expect(f.engines.count == 2 && f.engines.last?.startedFrom == nil)
        engine.deliver([.zoneDeleted(SyncCloudKitRecords.zoneID, .deleted), .stateUpdate(Data([99]))])
        #expect(f.controller.isEnabled && f.copy.engineState != Data([99]))
    }

    @Test func aFetchedSettingDeletionKeepsTheLocalValueAndADeletedSidebarItemStaysDeleted() async throws {
        let f = Fixture()
        defer { f.clean() }
        let favorite = Favorite(url: URL(string: "about:blank#favorite")!, title: "Saved", personaID: Persona.defaultID)
        let original = f.sidebar.sidebarSyncState
        f.sidebar.sidebarSyncState = .init(personas: original.personas, spaces: original.spaces, folders: [], favorites: [favorite], pinnedTabs: [])
        f.setAppearance("dark")
        let engine = try await f.startAndSend()
        let id = favorite.id.uuidString
        let old = try #require(f.copy.records[id]?.copy() as? CKRecord)
        old.encryptedValues["title"] = "Remote edit"
        f.sidebar.sidebarSyncState = original
        try f.sidebar.saveNow().get()
        engine.deliver([.fetchStarted, .fetchedChanges(.init(records: [old], deletions: [
            .init(recordID: SyncCloudKitRecords.recordID(named: "ARCHAppearance"), recordType: "Setting")
        ])), .fetchEnded(failure: nil)])
        #expect(f.defaults.string(forKey: "ARCHAppearance") == "dark")
        #expect(f.sidebar.sidebarSyncState.favorites.isEmpty && engine.pendingChanges.contains(.deleteRecord(id)))
    }

    @Test(arguments: [SyncAccountChange.signOut, .switchAccounts]) func accountLossKeepsTheSidebarAndPersistsTheExplanation(change: SyncAccountChange) async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let local = f.sidebar.sidebarSyncState
        f.answer = { .unavailable(.noAccount) }
        engine.deliver([.accountChange(change)])
        await f.controller.refresh()
        #expect(f.controller.availability == .unavailable(.noAccount))
        #expect(f.controller.offReason == .accountChanged)
        #expect(!f.controller.isEnabled && f.sidebar.sidebarSyncState == local && !FileManager.default.fileExists(atPath: f.file.path))
        f.newController()
        f.answer = { .available(f.database) }
        await f.controller.refresh()
        #expect(f.controller.offReason == .accountChanged && f.controller.availability == .available(f.database))
        await f.controller.setEnabled(true)
        #expect(f.controller.offReason == nil && f.engines.last?.startedFrom == nil)
    }

    @Test func accountStatusCanReportSignOutBeforeTheEngineEvent() async throws {
        let f = Fixture()
        defer { f.clean() }
        _ = try await f.startAndSend()
        let local = f.sidebar.sidebarSyncState
        f.answer = { .unavailable(.noAccount) }
        await f.controller.refresh()
        #expect(!f.controller.isEnabled && f.controller.offReason == .accountChanged)
        #expect(!FileManager.default.fileExists(atPath: f.file.path) && f.sidebar.sidebarSyncState == local)
        f.answer = { .available(f.database) }
        await f.controller.refresh()
        #expect(f.engines.count == 1 && f.controller.offReason == .accountChanged && f.controller.availability == .available(f.database))
    }

    /// An opt-in on a Mac without an iCloud account has nothing to invalidate, so it waits for an account as for the other reasons rather than turning off as after an account change.
    @Test func anOptInWithoutAnAccountWaitsForOne() async throws {
        let f = Fixture()
        defer { f.clean() }
        let container = NSObject()
        f.controller.observeAccountChanges(of: container)
        f.answer = { .unavailable(.noAccount) }
        await f.controller.setEnabled(true)
        #expect(f.controller.isEnabled && f.controller.offReason == nil && f.engines.isEmpty)
        f.answer = { .available(f.database) }
        f.center.post(name: .CKAccountChanged, object: container)
        let deadline = ContinuousClock.now + .seconds(5)
        while f.engines.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
        #expect(f.engines.count == 1 && f.engines.first?.startedFrom == nil)
    }

    /// A quit while Delete iCloud Data waits leaves the data in iCloud and `sync.json` from before the request, so the next launch syncs and says to delete again.
    @Test func aQuitBeforeTheDeletionReachesTheServerAsksToDeleteAgain() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        engine.zoneFailure = .networkUnavailable
        await f.controller.deleteCloudData()
        #expect(f.controller.isDeletingCloudData && engine.pendingChanges.contains(.deleteZone))
        f.newController()
        await f.controller.refresh()
        let relaunched = try #require(f.engines.last)
        #expect(f.controller.isEnabled && !f.controller.isDeletingCloudData && !relaunched.pendingChanges.contains(.deleteZone))
        #expect(f.controller.lastError == "Arch quit before it deleted its iCloud data. Delete it again to remove it.")
        f.newController()
        await f.controller.refresh()
        #expect(f.controller.lastError == nil)
    }

    @Test(arguments: [SyncZoneDeletionReason.deleted, .purged]) func aDeletedZoneKeepsLocalDataAndExplainsItsReset(reason: SyncZoneDeletionReason) async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let local = f.sidebar.sidebarSyncState
        engine.deliver([.zoneDeleted(SyncCloudKitRecords.zoneID, reason)])
        #expect(!f.controller.isEnabled && f.controller.offReason == .zoneDeleted && f.sidebar.sidebarSyncState == local)
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        f.newController()
        await f.controller.refresh()
        #expect(f.controller.offReason == .zoneDeleted && f.controller.availability == .available(f.database) && f.engines.count == 1)
    }

    @Test func togglingOffPreservesTheFileAndEditsMadeWhileOffUploadOnResume() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        let state = try Data(contentsOf: f.file)
        let token = f.copy.engineState
        let id = f.space.id.uuidString
        await f.controller.setEnabled(false)
        #expect(engine.isStopped && f.controller.offReason == nil)
        f.sidebar.renameSpace("Edited while off")
        try f.sidebar.saveNow().get()
        f.setAppearance("dark")
        #expect(try Data(contentsOf: f.file) == state)
        await f.controller.setEnabled(true)
        let resumed = try #require(f.engines.last)
        await f.waitForBatches(1, of: resumed)
        #expect(resumed.startedFrom == token && Set(resumed.batches.flatMap(\.records).map(\.recordID.recordName)) == [id, "ARCHAppearance"])
        let n = resumed.fetchCount
        resumed.deliver([.accountChange(.signIn)])
        let deadline = ContinuousClock.now + .seconds(3)
        while resumed.fetchCount == n && ContinuousClock.now < deadline { await Task.yield() }
        #expect(resumed.fetchCount == n + 1 && f.engines.count == 2 && resumed.pendingChanges.isEmpty)
    }

    @Test func confirmedDeletionSendsOnlyTheZoneAndTurnsOffOnceTheServerAccepts() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        f.sidebar.renameSpace("Keep my tabs")
        try f.sidebar.saveNow().get()
        let before = engine.batches.count
        engine.zoneFailure = .networkUnavailable
        await f.controller.deleteCloudData()
        #expect(f.controller.isEnabled && f.controller.isDeletingCloudData)
        #expect(engine.pendingChanges.contains(.deleteZone) && FileManager.default.fileExists(atPath: f.file.path))
        #expect(engine.batches.count == before)
        await f.controller.refresh()
        #expect(engine.sentZoneChanges.last == .deleteZone && engine.batches.count == before)
        #expect(!f.controller.isEnabled && !f.controller.isDeletingCloudData && f.space.name == "Keep my tabs")
        #expect(f.controller.offReason == .zoneDeleted && !FileManager.default.fileExists(atPath: f.file.path))
    }

    @Test func permanentDeletionRefusalResumesSyncAndAllowsAnExplicitRetry() async throws {
        let f = Fixture()
        defer { f.clean() }
        let engine = try await f.startAndSend()
        f.sidebar.renameSpace("Local")
        try f.sidebar.saveNow().get()
        let token = f.copy.engineState
        engine.zoneFailure = .permissionFailure
        await f.controller.deleteCloudData()
        #expect(f.controller.isEnabled && !f.controller.isDeletingCloudData && f.controller.lastError != nil)
        // A new engine starts from the file kept from before the deletion, so it fetches again what the deletion's wait dropped.
        let resumed = try #require(f.engines.last)
        #expect(f.engines.count == 2 && engine.isStopped && resumed.startedFrom == token)
        #expect(!resumed.pendingChanges.contains(.deleteZone) && FileManager.default.fileExists(atPath: f.file.path))
        await f.waitForBatches(1, of: resumed)
        #expect(resumed.batches.first?.records.map(\.recordID.recordName) == [f.space.id.uuidString])
        resumed.zoneFailure = .zoneNotFound
        await f.controller.deleteCloudData()
        #expect(!f.controller.isEnabled && f.controller.offReason == .zoneDeleted && f.space.name == "Local")
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
    }

    @Test func anAccountNotificationRechecksWhileOffAndALateResultCannotRestartAnotherEngine() async throws {
        let f = Fixture()
        defer { f.clean() }
        let container = NSObject()
        f.controller.observeAccountChanges(of: container)
        f.answer = { .unavailable(.noAccount) }
        await f.controller.refresh()
        #expect(f.controller.availability == .unavailable(.noAccount))
        f.answer = { .available(f.database) }
        f.center.post(name: .CKAccountChanged, object: container)
        let deadline = ContinuousClock.now + .seconds(5)
        while f.checks < 2 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(f.controller.availability == .available(f.database) && f.engines.isEmpty)
        var delayed: CheckedContinuation<SyncAvailability.Status, Never>?
        f.answer = { await withCheckedContinuation { delayed = $0 } }
        let slow = Task { @MainActor in await f.controller.setEnabled(true) }
        while delayed == nil { await Task.yield() }
        f.answer = { .unavailable(.restricted) }
        await f.controller.refresh()
        delayed?.resume(returning: .available(f.database))
        await slow.value
        #expect(f.controller.availability == .unavailable(.restricted) && f.engines.isEmpty)
        f.answer = { .available(f.database) }
        f.center.post(name: .CKAccountChanged, object: container)
        let restarted = ContinuousClock.now + .seconds(5)
        while !f.controller.canSendRecords && ContinuousClock.now < restarted { await Task.yield() }
        #expect(f.engines.count == 1 && f.controller.canSendRecords)
    }
}
