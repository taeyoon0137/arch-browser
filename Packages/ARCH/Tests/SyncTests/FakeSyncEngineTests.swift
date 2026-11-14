// The fake sync engine that the controller's tests use (docs/sync.md, Module layout) keeps to what `CKSyncEngine` documents and `CloudKitSyncEngine` adds: pending changes without duplicates, where a save replaces a deletion and the other way around, the zone's changes sent before the records, a zone change that stays pending after a failure the engine retries and is dropped and reported after any other, records built through the delegate, a send that builds batches of at most the limit until no change is left, the changes its handling adds included, an atomic batch whose other changes go again when one save fails, a fetch that reports its pages before its end, and its zone fetch's failure at its end, pending changes restored from a state update whose bytes do not change between encodings, and no events or changes once stopped.
import CloudKit
import Foundation
import Testing
@testable import Sync

@MainActor
@Suite struct FakeSyncEngineTests {
    /// A placeholder; no real container identifier appears in the repository.
    private let database = SyncDatabase(containerIdentifier: "iCloud.example.sync", environment: "Production")

    /// Records each event, builds the records it has for the engine's saves, and runs `onEvent` after each event.
    @MainActor
    private final class Delegate: SyncEngineDelegate {
        var events: [SyncEvent] = []
        var records: [String: CKRecord] = [:]
        var onEvent: ((SyncEvent) -> Void)?

        func handle(_ event: SyncEvent) {
            events.append(event)
            onEvent?(event)
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
        #expect(delegate.events == [
            .sentZoneChanges(SyncSentZoneChanges(savedZone: true)),
            .stateUpdate(FakeSyncEngine.stateSerialization(of: [.saveRecord("saved"), .saveRecord("withoutRecord"), .deleteRecord("deleted")])),
            .sentChanges(SyncSentChanges(savedRecords: [saved], deletedRecordNames: ["deleted"])),
            .stateUpdate(engine.stateSerialization),
        ])
    }

    @Test func aZoneChangeThatFailsForAReasonTheEngineRetriesStaysPendingAndIsNotReported() async throws {
        let delegate = Delegate()
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.add([.deleteZone])
        engine.zoneFailure = .networkUnavailable
        try await engine.sendChanges()
        #expect(engine.pendingChanges == [.deleteZone])
        #expect(engine.sentZoneChanges.isEmpty)
        #expect(delegate.events.isEmpty)

        // Online again, the deletion goes and its report says so.
        try await engine.sendChanges()
        #expect(engine.pendingChanges.isEmpty)
        #expect(engine.sentZoneChanges == [.deleteZone])
        #expect(delegate.events == [.sentZoneChanges(SyncSentZoneChanges(deletedZone: true)), .stateUpdate(engine.stateSerialization)])
    }

    @Test func aZoneChangeRefusedForAnotherReasonIsDroppedAndReported() async throws {
        let delegate = Delegate()
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.add([.saveZone])
        engine.zoneFailure = .quotaExceeded
        try await engine.sendChanges()
        #expect(engine.pendingChanges.isEmpty)
        #expect(engine.sentZoneChanges.isEmpty)
        #expect(delegate.events == [.sentZoneChanges(SyncSentZoneChanges(failedSave: .quotaExceeded)), .stateUpdate(engine.stateSerialization)])
    }

    @Test func aRefusedSaveSavesNothingOfItsBatchAndTheSendsNextBatchTakesTheOtherChanges() async throws {
        let delegate = Delegate()
        let conflicting = record("conflicting")
        let other = record("other")
        let serverRecord = record("conflicting")
        delegate.records = ["conflicting": conflicting, "other": other]
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.saveFailures["conflicting"] = .serverRecordChanged(serverRecord)
        engine.add([.saveRecord("conflicting"), .saveRecord("other"), .deleteRecord("deleted")])
        try await engine.sendChanges()

        #expect(engine.batches == [
            FakeSyncEngine.Batch(records: [conflicting, other], deletedRecordNames: ["deleted"]),
            FakeSyncEngine.Batch(records: [other], deletedRecordNames: ["deleted"]),
        ])
        #expect(delegate.events == [
            .sentChanges(SyncSentChanges(failedSaves: [SyncFailedSave(recordName: "conflicting", failure: .serverRecordChanged(serverRecord))])),
            .stateUpdate(FakeSyncEngine.stateSerialization(of: [.saveRecord("other"), .deleteRecord("deleted")])),
            .sentChanges(SyncSentChanges(savedRecords: [other], deletedRecordNames: ["deleted"])),
            .stateUpdate(FakeSyncEngine.stateSerialization(of: [])),
        ])
        #expect(engine.pendingChanges.isEmpty)
    }

    @Test func aSaveAddedBackWhileItsRefusalIsHandledGoesInTheSameSend() async throws {
        let delegate = Delegate()
        let conflicting = record("conflicting")
        let other = record("other")
        delegate.records = ["conflicting": conflicting, "other": other]
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.saveFailures["conflicting"] = .serverRecordChanged(record("conflicting"))
        // The merged save goes again, as the controller adds it while it handles the refusal.
        delegate.onEvent = { event in
            if case .sentChanges(let sent) = event, !sent.failedSaves.isEmpty { engine.add([.saveRecord("conflicting")]) }
        }
        engine.add([.saveRecord("conflicting"), .saveRecord("other")])
        try await engine.sendChanges()

        #expect(engine.batches == [
            FakeSyncEngine.Batch(records: [conflicting, other], deletedRecordNames: []),
            FakeSyncEngine.Batch(records: [other, conflicting], deletedRecordNames: []),
        ])
        #expect(delegate.events.last == .stateUpdate(FakeSyncEngine.stateSerialization(of: [])))
        #expect(engine.pendingChanges.isEmpty)
    }

    @Test func splitsASendIntoBatchesOfAtMostTheLimitWhereASaveWithoutARecordTakesNoPlace() async throws {
        let delegate = Delegate()
        let names = ["a", "b", "c", "d", "e"]
        for name in names { delegate.records[name] = record(name) }
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.batchLimit = 2
        engine.add([.saveRecord("a"), .saveRecord("withoutRecord"), .saveRecord("b"), .saveRecord("c"), .saveRecord("d"), .saveRecord("e")])
        try await engine.sendChanges()

        #expect(engine.batches.map { $0.records.map(\.recordID.recordName) } == [["a", "b"], ["c", "d"], ["e"]])
        let sentEvents = delegate.events.filter { if case .sentChanges = $0 { true } else { false } }
        #expect(sentEvents.count == 3)
        #expect(engine.pendingChanges.isEmpty)
    }

    @Test func aSendThatNeverRunsOutOfChangesThrowsAtTheLimit() async throws {
        let delegate = Delegate()
        delegate.records["conflicting"] = record("conflicting")
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.batchesPerSendLimit = 3
        engine.saveFailures["conflicting"] = .other(.serverRecordChanged)
        // A delegate that adds the refused save back, and the server that refuses it again each time.
        delegate.onEvent = { event in
            guard case .sentChanges(let sent) = event, let failed = sent.failedSaves.first else { return }
            engine.saveFailures[failed.recordName] = failed.failure
            engine.add([.saveRecord(failed.recordName)])
        }
        engine.add([.saveRecord("conflicting")])
        await #expect(throws: FakeSyncEngine.SendError.batchLimitExceeded) {
            try await engine.sendChanges()
        }
        #expect(engine.batches.count == 3)
    }

    @Test func aFetchReportsItsScriptThenTheStateAndItsEnd() async throws {
        let delegate = Delegate()
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        let fetched = SyncFetchedChanges(records: [record("tab-1")], deletions: [SyncFetchedChanges.Deletion(recordID: SyncCloudKitRecords.recordID(named: "tab-2"), recordType: "Tab")])
        engine.fetchScript = [.fetchedChanges(fetched), .zoneDeleted(SyncCloudKitRecords.zoneID, .purged)]
        try await engine.fetchChanges()
        #expect(delegate.events == [.fetchedChanges(fetched), .zoneDeleted(SyncCloudKitRecords.zoneID, .purged), .stateUpdate(engine.stateSerialization), .fetchEnded(failure: nil)])

        delegate.events = []
        try await engine.fetchChanges()
        #expect(delegate.events == [.stateUpdate(engine.stateSerialization), .fetchEnded(failure: nil)])
        #expect(engine.fetchCount == 2)
    }

    @Test func aFetchWhoseZoneFetchFailsReportsTheFailureAtItsEndAndThrows() async throws {
        let delegate = Delegate()
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        let fetched = SyncFetchedChanges(records: [record("tab-1")])
        engine.fetchScript = [.fetchedChanges(fetched)]
        engine.fetchFailure = .networkFailure
        do {
            try await engine.fetchChanges()
            Issue.record("Expected the scripted failure")
        } catch let error as CKError {
            #expect(error.code == .networkFailure)
        }
        #expect(delegate.events == [.fetchedChanges(fetched), .stateUpdate(engine.stateSerialization), .fetchEnded(failure: .networkFailure)])

        // The failure came only once.
        delegate.events = []
        try await engine.fetchChanges()
        #expect(delegate.events == [.stateUpdate(engine.stateSerialization), .fetchEnded(failure: nil)])
    }

    @Test func anEngineStartedFromAStateUpdateHasItsPendingChanges() {
        let delegate = Delegate()
        let first = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        first.add([.saveZone, .saveRecord("a"), .deleteRecord("b")])
        let serialization = first.stateSerialization
        // Each encoding gives the same bytes, so a state update compares equal to the serialization it holds.
        for _ in 0 ..< 20 {
            #expect(first.stateSerialization == serialization)
        }
        let next = FakeSyncEngine(database: database, stateSerialization: serialization, delegate: delegate)
        #expect(next.startedFrom == serialization)
        #expect(next.pendingChanges == [.saveZone, .saveRecord("a"), .deleteRecord("b")])
        #expect(next.stateSerialization == serialization)
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

    @Test func aStoppedEngineReportsNothingTakesNoChangeAndDropsItsPendingChanges() async throws {
        let delegate = Delegate()
        delegate.records["a"] = record("a")
        let engine = FakeSyncEngine(database: database, stateSerialization: nil, delegate: delegate)
        engine.add([.saveRecord("a"), .saveZone])
        let kept = engine.stateSerialization
        engine.fetchScript = [.accountChange(.signOut)]
        await engine.stop()
        engine.add([.saveRecord("b")])
        engine.deliver([.accountChange(.switchAccounts)])
        try await engine.fetchChanges()
        try await engine.sendChanges()
        #expect(delegate.events.isEmpty)
        #expect(engine.fetchCount == 0)
        #expect(engine.batches.isEmpty)
        #expect(engine.sentZoneChanges.isEmpty)
        #expect(engine.pendingChanges.isEmpty)

        // The state update kept before the stop still holds the pending changes for the next engine.
        let next = FakeSyncEngine(database: database, stateSerialization: kept, delegate: delegate)
        #expect(next.pendingChanges == [.saveZone, .saveRecord("a")])
    }
}
