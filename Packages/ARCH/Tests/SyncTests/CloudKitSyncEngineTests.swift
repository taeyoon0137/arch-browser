// The CloudKit sync engine's mapping (docs/sync.md, Container, database, and zone, Conflicts, and Offline behavior): the fetch options that name only `ArchSync1`, CloudKit's save errors as Arch's failures, the changes an atomic batch sends again, and pending changes, account changes, and zone deletion reasons. The test process has no iCloud entitlements, so it creates no `CKSyncEngine`; it builds `CKError` values and records without reaching CloudKit's servers.
import CloudKit
import Foundation
import Testing
@testable import Sync

@Suite struct CloudKitSyncEngineTests {
    private let laterZone = CKRecordZone.ID(zoneName: "ArchSync2", ownerName: CKCurrentUserDefaultName)

    private func record(_ name: String, in zoneID: CKRecordZone.ID = SyncCloudKitRecords.zoneID) -> CKRecord {
        CKRecord(recordType: SyncRecordType.space.rawValue, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }

    @Test func fetchesOnlyTheZoneArchSync1() {
        let options = CloudKitSyncEngine.fetchOptions()
        #expect(options.scope == .zoneIDs([SyncCloudKitRecords.zoneID]))
        #expect(options.scope.contains(SyncCloudKitRecords.zoneID))
        #expect(!options.scope.contains(laterZone))
        #expect(!options.scope.contains(CKRecordZone.ID.default))
    }

    @Test func narrowsTheEnginesOwnFetchOptionsToTheZone() {
        let group = CKOperationGroup()
        var engineOptions = CKSyncEngine.FetchChangesOptions(scope: .all, operationGroup: group)
        engineOptions.prioritizedZoneIDs = [laterZone, SyncCloudKitRecords.zoneID]
        let options = CloudKitSyncEngine.fetchOptions(from: engineOptions)
        #expect(options.scope == .zoneIDs([SyncCloudKitRecords.zoneID]))
        #expect(options.prioritizedZoneIDs == [SyncCloudKitRecords.zoneID])
        // The options hold a copy of the group.
        #expect(options.operationGroup.operationGroupID == group.operationGroupID)

        var excluding = CKSyncEngine.FetchChangesOptions(scope: .allExcluding([SyncCloudKitRecords.zoneID]))
        excluding.prioritizedZoneIDs = [laterZone]
        #expect(CloudKitSyncEngine.fetchOptions(from: excluding).scope == .zoneIDs([SyncCloudKitRecords.zoneID]))
        #expect(CloudKitSyncEngine.fetchOptions(from: excluding).prioritizedZoneIDs.isEmpty)
    }

    @Test func mapsEachSaveErrorToItsFailure() throws {
        let serverRecord = record("space-1")
        let changed = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])
        let failure = try #require(CloudKitSyncEngine.failure(for: changed))
        guard case .serverRecordChanged(let record) = failure else {
            Issue.record("Expected the server's record, got \(failure)")
            return
        }
        #expect(record === serverRecord)
        #expect(CloudKitSyncEngine.failure(for: CKError(.unknownItem)) == .unknownItem)
        #expect(CloudKitSyncEngine.failure(for: CKError(.zoneNotFound)) == .zoneNotFound)
        // The engine retries a missing network itself and keeps the change pending.
        #expect(CloudKitSyncEngine.failure(for: CKError(.networkUnavailable)) == nil)
    }

    @Test func reportsNoFailureForTheErrorsTheEngineRetriesOrTheBatchSendsAgain() {
        let codes: [CKError.Code] = [.networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable, .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled, .batchRequestFailed]
        for code in codes {
            #expect(CloudKitSyncEngine.failure(for: CKError(code)) == nil, "\(code)")
        }
    }

    @Test func reportsAnyOtherErrorWithItsCode() {
        #expect(CloudKitSyncEngine.failure(for: CKError(.quotaExceeded)) == .other(.quotaExceeded))
        #expect(CloudKitSyncEngine.failure(for: CKError(.invalidArguments)) == .other(.invalidArguments))
        // A conflict without the server's record cannot be merged.
        #expect(CloudKitSyncEngine.failure(for: CKError(.serverRecordChanged)) == .other(.serverRecordChanged))
    }

    @Test func aSentBatchReportsItsSavesAndDeletionsAndOnlyTheFailuresTheEngineDoesNotRetry() {
        let saved = record("saved")
        let conflicting = record("conflicting")
        let serverRecord = record("conflicting")
        let sent = CloudKitSyncEngine.sentChanges(
            savedRecords: [saved],
            deletedRecordIDs: [SyncCloudKitRecords.recordID(named: "deleted")],
            failedSaves: [
                (conflicting, CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])),
                (record("offline"), CKError(.networkUnavailable)),
                (record("refusedWithTheBatch"), CKError(.batchRequestFailed)),
                (record("gone"), CKError(.unknownItem)),
            ]
        )
        #expect(sent.savedRecords == [saved])
        #expect(sent.deletedRecordNames == ["deleted"])
        #expect(sent.failedSaves == [
            SyncFailedSave(recordName: "conflicting", failure: .serverRecordChanged(serverRecord)),
            SyncFailedSave(recordName: "gone", failure: .unknownItem),
        ])
    }

    @Test func sendsAgainOnlyTheChangesThatAnotherRecordsFailureRefused() {
        let id = SyncCloudKitRecords.recordID(named:)
        let resend = CloudKitSyncEngine.changesToResend(
            failedSaves: [
                (id("b"), CKError(.batchRequestFailed)),
                (id("conflicting"), CKError(.serverRecordChanged)),
                (id("a"), CKError(.batchRequestFailed)),
                (id("offline"), CKError(.networkFailure)),
            ],
            failedDeletes: [id("deleted-2"): CKError(.batchRequestFailed), id("deleted-1"): CKError(.batchRequestFailed), id("busy"): CKError(.zoneBusy)]
        )
        #expect(resend == [.saveRecord(id("b")), .saveRecord(id("a")), .deleteRecord(id("deleted-1")), .deleteRecord(id("deleted-2"))])
    }

    @Test func mapsEachPendingChangeToTheEnginesAndBack() throws {
        for change in [SyncPendingChange.saveRecord("tab-1"), .deleteRecord("tab-2")] {
            let engineChange = try #require(CloudKitSyncEngine.recordZoneChange(for: change))
            #expect(CloudKitSyncEngine.databaseChange(for: change) == nil)
            #expect(CloudKitSyncEngine.change(from: engineChange) == change)
        }
        #expect(CloudKitSyncEngine.recordZoneChange(for: .saveRecord("tab-1")) == .saveRecord(SyncCloudKitRecords.recordID(named: "tab-1")))
        #expect(CloudKitSyncEngine.recordZoneChange(for: .deleteRecord("tab-2")) == .deleteRecord(SyncCloudKitRecords.recordID(named: "tab-2")))

        for change in [SyncPendingChange.saveZone, .deleteZone] {
            let engineChange = try #require(CloudKitSyncEngine.databaseChange(for: change))
            #expect(CloudKitSyncEngine.recordZoneChange(for: change) == nil)
            #expect(CloudKitSyncEngine.change(from: engineChange) == change)
        }
        guard case .saveZone(let zone)? = CloudKitSyncEngine.databaseChange(for: .saveZone) else {
            Issue.record("Expected the zone's save")
            return
        }
        #expect(zone.zoneID == SyncCloudKitRecords.zoneID)
        #expect(CloudKitSyncEngine.databaseChange(for: .deleteZone) == .deleteZone(SyncCloudKitRecords.zoneID))
    }

    @Test func ignoresPendingChangesOfAnotherZone() {
        let otherRecord = CKRecord.ID(recordName: "tab-1", zoneID: laterZone)
        #expect(CloudKitSyncEngine.change(from: CKSyncEngine.PendingRecordZoneChange.saveRecord(otherRecord)) == nil)
        #expect(CloudKitSyncEngine.change(from: CKSyncEngine.PendingRecordZoneChange.deleteRecord(otherRecord)) == nil)
        #expect(CloudKitSyncEngine.change(from: CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: laterZone))) == nil)
        #expect(CloudKitSyncEngine.change(from: CKSyncEngine.PendingDatabaseChange.deleteZone(.default)) == nil)
    }

    @Test func mapsAccountChangesAndZoneDeletionReasons() {
        let first = CKRecord.ID(recordName: "first-user")
        let second = CKRecord.ID(recordName: "second-user")
        #expect(SyncAccountChange(.signIn(currentUser: first)) == .signIn)
        #expect(SyncAccountChange(.signOut(previousUser: first)) == .signOut)
        #expect(SyncAccountChange(.switchAccounts(previousUser: first, currentUser: second)) == .switchAccounts)
        #expect(SyncZoneDeletionReason(.deleted) == .deleted)
        #expect(SyncZoneDeletionReason(.purged) == .purged)
        #expect(SyncZoneDeletionReason(.encryptedDataReset) == .encryptedDataReset)
    }
}
