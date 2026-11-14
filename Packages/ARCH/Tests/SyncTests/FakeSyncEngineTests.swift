// The fake sync engine that the controller's tests use (docs/sync.md, Module layout) keeps to what `CKSyncEngine` documents and `CloudKitSyncEngine` adds: pending changes without duplicates, where a save replaces a deletion and the other way around, records built through the delegate, an atomic batch whose other changes stay pending when one save fails, a fetch that reports its pages before its end, pending changes restored from a state update, and no events once stopped.
import CloudKit
import Foundation
import Testing
@testable import Sync

@MainActor
@Suite struct FakeSyncEngineTests {
    /// A placeholder; no real container identifier appears in the repository.
    private let database = SyncDatabase(containerIdentifier: "iCloud.example.sync", environment: "Production")

    /// Records each event and builds the records it has for the engine's saves.
    @MainActor
    private final class Delegate: SyncEngineDelegate {
        var events: [SyncEvent] = []
        var records: [String: CKRecord] = [:]

        func handle(_ event: SyncEvent) {
            events.append(event)
        }

        func record(toSave recordName: String) -> CKRecord? {
            records[recordName]
        }
    }

    private func record(_ name: String) -> CKRecord {
        CKRecord(recordType: SyncRecordType.tab.rawValue, recordID: SyncCloudKitRecords.recordID(named: name))
    }

    @Test func keepsOneChangeForEachRecordAndTheZoneWithTheLaterOfASaveAndADeletion() {
        let delegate = Delegate()
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.add([.saveRecord("a"), .saveRecord("b"), .saveRecord("a")])
        #expect(engine.pendingChanges == [.saveRecord("a"), .saveRecord("b")])
        engine.add([.deleteRecord("a"), .saveZone, .deleteZone])
        #expect(engine.pendingChanges == [.deleteZone, .saveRecord("b"), .deleteRecord("a")])
        engine.remove([.saveRecord("b"), .deleteZone])
        #expect(engine.pendingChanges == [.deleteRecord("a")])
    }

    @Test func sendsTheZoneFirstAndBuildsEachSaveThroughTheDelegate() async throws {
        let delegate = Delegate()
        let saved = record("saved")
        delegate.records["saved"] = saved
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.add([.saveRecord("saved"), .saveRecord("withoutRecord"), .deleteRecord("deleted"), .saveZone])
        try await engine.sendChanges()

        #expect(engine.sentZoneChanges == [.saveZone])
        #expect(engine.batches == [FakeSyncEngine.Batch(records: [saved], deletedRecordNames: ["deleted"])])
        #expect(engine.pendingChanges.isEmpty)
        #expect(delegate.events == [.sentChanges(SyncSentChanges(savedRecords: [saved], deletedRecordNames: ["deleted"])), .stateUpdate(engine.stateSerialization)])
    }

    @Test func aRefusedSaveSavesNothingOfItsBatchAndKeepsTheOtherChangesPending() async throws {
        let delegate = Delegate()
        let conflicting = record("conflicting")
        let other = record("other")
        let serverRecord = record("conflicting")
        delegate.records = ["conflicting": conflicting, "other": other]
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.saveFailures["conflicting"] = .serverRecordChanged(serverRecord)
        engine.add([.saveRecord("conflicting"), .saveRecord("other"), .deleteRecord("deleted")])
        try await engine.sendChanges()

        #expect(delegate.events.first == .sentChanges(SyncSentChanges(failedSaves: [SyncFailedSave(recordName: "conflicting", failure: .serverRecordChanged(serverRecord))])))
        #expect(engine.pendingChanges == [.saveRecord("other"), .deleteRecord("deleted")])

        // The merged save goes again with the others, and the failure came only once.
        engine.add([.saveRecord("conflicting")])
        delegate.events = []
        try await engine.sendChanges()
        #expect(delegate.events.first == .sentChanges(SyncSentChanges(savedRecords: [other, conflicting], deletedRecordNames: ["deleted"])))
        #expect(engine.pendingChanges.isEmpty)
    }

    @Test func aFetchReportsItsScriptThenTheStateAndItsEnd() async throws {
        let delegate = Delegate()
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        let fetched = SyncFetchedChanges(records: [record("tab-1")], deletions: [SyncFetchedChanges.Deletion(recordID: SyncCloudKitRecords.recordID(named: "tab-2"), recordType: "Tab")])
        engine.fetchScript = [.fetchedChanges(fetched), .zoneDeleted(SyncCloudKitRecords.zoneID, .purged)]
        try await engine.fetchChanges()
        #expect(delegate.events == [.fetchedChanges(fetched), .zoneDeleted(SyncCloudKitRecords.zoneID, .purged), .stateUpdate(engine.stateSerialization), .fetchEnded])

        delegate.events = []
        try await engine.fetchChanges()
        #expect(delegate.events == [.stateUpdate(engine.stateSerialization), .fetchEnded])
        #expect(engine.fetchCount == 2)
    }

    @Test func anEngineStartedFromAStateUpdateHasItsPendingChanges() {
        let delegate = Delegate()
        let first = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        first.add([.saveZone, .saveRecord("a"), .deleteRecord("b")])
        let next = FakeSyncEngine(database: database, stateSerialization: first.stateSerialization, delegate: delegate)
        #expect(next.startedFrom == first.stateSerialization)
        #expect(next.pendingChanges == [.saveZone, .saveRecord("a"), .deleteRecord("b")])
    }

    @Test func aFactoryHandsOverEachEngineItCreates() {
        let delegate = Delegate()
        var created: [FakeSyncEngine] = []
        let factory = FakeSyncEngine.factory { created.append($0) }
        let engine = factory(database, nil, delegate)
        #expect(created.count == 1)
        #expect(created.first === engine as? FakeSyncEngine)
        #expect(created.first?.database == database)
    }

    @Test func aStoppedEngineReportsNothingAndSendsNothing() async throws {
        let delegate = Delegate()
        delegate.records["a"] = record("a")
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.add([.saveRecord("a")])
        engine.fetchScript = [.accountChange(.signOut)]
        await engine.stop()
        engine.deliver([.accountChange(.switchAccounts)])
        try await engine.fetchChanges()
        try await engine.sendChanges()
        #expect(delegate.events.isEmpty)
        #expect(engine.fetchCount == 0)
        #expect(engine.batches.isEmpty)
        #expect(engine.pendingChanges == [.saveRecord("a")])
    }
}
