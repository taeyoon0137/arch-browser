// The sync engine as the controller uses it (`docs/sync.md`, Conflicts and Offline behavior): pending changes by record name, fetches and sends, and Arch's own events. `CloudKitSyncEngine` implements it with `CKSyncEngine`. `SyncTests` use `FakeSyncEngine`, which keeps pending changes in memory and replays scripted events, so no test reaches CloudKit's servers.
import CloudKit
import Foundation

/// A change for the engine to send: the save or deletion of a record of the zone `ArchSync1`, by record name, or the save or deletion of the zone itself.
public enum SyncPendingChange: Hashable, Sendable {
    /// Saves the record. The engine asks its delegate for the record when it builds a batch (`SyncEngineDelegate.record(toSave:)`).
    case saveRecord(String)
    case deleteRecord(String)
    /// Creates the zone, as after `zoneNotFound` with an empty mirror or after an encrypted data reset (`docs/sync.md`, Offline behavior, and Accounts and removed data).
    case saveZone
    /// Deletes the zone and every record in it, as Delete iCloud Data does.
    case deleteZone
}

/// How the iCloud account changed (`docs/sync.md`, Accounts and removed data).
public enum SyncAccountChange: Hashable, Sendable {
    /// An account signed in. Whether the engine reports this when it starts without a state serialization is Not verified 5.
    case signIn
    case signOut
    /// Another account replaced the one the engine used.
    case switchAccounts
}

/// Why a fetch found a zone deleted (`docs/sync.md`, Accounts and removed data).
public enum SyncZoneDeletionReason: Hashable, Sendable {
    /// Another Mac deleted it, as Delete iCloud Data does.
    case deleted
    /// The user removed Arch's data in the system's iCloud settings.
    case purged
    /// The user reset the end-to-end encryption keys, so the encrypted fields are gone.
    case encryptedDataReset
}

/// One page of a fetch. A fetch can report several pages, and a child can come in a later page than its parent.
public struct SyncFetchedChanges: Equatable, Sendable {
    /// One record that the server deleted.
    public struct Deletion: Hashable, Sendable {
        public var recordID: CKRecord.ID
        /// The record's type as CloudKit names it, which can be a type this build does not know.
        public var recordType: String

        public init(recordID: CKRecord.ID, recordType: String) {
            self.recordID = recordID
            self.recordType = recordType
        }
    }

    /// The records as the server holds them, each whole with its system fields. Each keeps its zone, since the controller drops records of other zones (`SyncCloudKitRecords.isInZone(_:)`).
    public var records: [CKRecord]
    public var deletions: [Deletion]

    public init(records: [CKRecord] = [], deletions: [Deletion] = []) {
        self.records = records
        self.deletions = deletions
    }
}

/// Why the server refused a save. The engine reports only the reasons it does not retry itself.
public enum SyncSaveFailure: Equatable, Sendable {
    /// Another Mac saved the record first. The server's record comes with it, to merge against the mirror's copy and send again with its change tag (`docs/sync.md`, Conflicts).
    case serverRecordChanged(CKRecord)
    /// No record has the change tag of the record sent: another Mac deleted it, or the zone was created again after the mirror's copy was fetched.
    case unknownItem
    case zoneNotFound
    /// Any other refusal, such as a full iCloud storage (`quotaExceeded`), or a `serverRecordChanged` that came without the server's record.
    case other(CKError.Code)
}

/// A save that the server refused, by record name.
public struct SyncFailedSave: Equatable, Sendable {
    public var recordName: String
    public var failure: SyncSaveFailure

    public init(recordName: String, failure: SyncSaveFailure) {
        self.recordName = recordName
        self.failure = failure
    }
}

/// One batch that the engine sent. The engine sends only records of the zone `ArchSync1`, so every record named here is one of them.
public struct SyncSentChanges: Equatable, Sendable {
    /// The records the server saved, each with the system fields that hold its new change tag.
    public var savedRecords: [CKRecord]
    public var deletedRecordNames: [String]
    /// The saves the server refused for a reason the engine does not retry.
    public var failedSaves: [SyncFailedSave]

    public init(savedRecords: [CKRecord] = [], deletedRecordNames: [String] = [], failedSaves: [SyncFailedSave] = []) {
        self.savedRecords = savedRecords
        self.deletedRecordNames = deletedRecordNames
        self.failedSaves = failedSaves
    }
}

/// The zone's save or deletion that one send sent (`SyncPendingChange.saveZone` and `.deleteZone`). The engine sends only the zone `ArchSync1`. A zone change that failed for a reason the engine retries stays pending and is not reported, as a record's is not.
public struct SyncSentZoneChanges: Equatable, Sendable {
    /// Whether the server saved the zone.
    public var savedZone: Bool
    /// Whether the server deleted the zone and every record in it, as Delete iCloud Data asks.
    public var deletedZone: Bool
    /// CloudKit's code for a save of the zone that the server refused for a reason the engine does not retry, such as a full iCloud storage (`quotaExceeded`). The engine drops the save, so no later send creates the zone unless the controller adds it again.
    public var failedSave: CKError.Code?
    /// CloudKit's code for a deletion of the zone that the server refused for a reason the engine does not retry. The engine drops the deletion, and the zone stays.
    public var failedDelete: CKError.Code?

    public init(savedZone: Bool = false, deletedZone: Bool = false, failedSave: CKError.Code? = nil, failedDelete: CKError.Code? = nil) {
        self.savedZone = savedZone
        self.deletedZone = deletedZone
        self.failedSave = failedSave
        self.failedDelete = failedDelete
    }
}

/// What the engine reports, in the order it happens.
public enum SyncEvent: Equatable, Sendable {
    /// The engine's state changed, such as its change token or its pending changes. `sync.json` keeps the serialization (`SyncMirror.engineState`) for the engine's next start on the same database.
    case stateUpdate(Data)
    case accountChange(SyncAccountChange)
    /// A fetch began, including one CloudKit scheduled automatically.
    case fetchStarted
    /// One page of a fetch.
    case fetchedChanges(SyncFetchedChanges)
    /// A fetch found this zone deleted. It can be another zone than `ArchSync1`, which the controller ignores.
    case zoneDeleted(CKRecordZone.ID, SyncZoneDeletionReason)
    /// A fetch ended, after every page it brought, the engine's own fetches included. `failure` is nil when the fetch of the zone completed or the fetch did not need one. Otherwise it is CloudKit's code for the zone fetch's failure, such as a network that dropped between pages: the pages that came hold only part of the zone's changes, and a later fetch brings the rest. A child whose parent has not arrived waits until a fetch ends without a failure (`docs/sync.md`, Mapping the session store to records ▸ Incoming changes, and Sync engine).
    case fetchEnded(failure: CKError.Code?)
    /// One batch of record changes was sent.
    case sentChanges(SyncSentChanges)
    /// The zone's save or deletion was sent, and the server took it or refused it for a reason the engine does not retry.
    case sentZoneChanges(SyncSentZoneChanges)
}

/// What the engine asks of the controller. The engine holds its delegate weakly.
@MainActor
public protocol SyncEngineDelegate: AnyObject {
    /// Handles one event. The engine reports its next event and builds its next batch only after this returns, so the changes applied and the comparisons run here come before the next send. To fetch or send in response, start a task: the engine waits for the handling to end before it fetches or sends again.
    func handle(_ event: SyncEvent)

    /// The record to send for the pending save of `recordName`, built on the mirror's copy, or on the server's record of a refused save, with the pending save's fields (`SyncCloudKitRecords.ckRecord(from:base:)`). Nil when nothing is left to save, and the engine then drops the pending save.
    func record(toSave recordName: String) -> CKRecord?
    /// A controller holds record batches until a fetch has been applied and its session saved.
    var canSendRecords: Bool { get }
}

extension SyncEngineDelegate {
    public var canSendRecords: Bool { true }
}

/// The sync engine on one database (`SyncDatabase`) and the zone `ArchSync1`. It starts when it is created (`SyncEngineFactory`) and then syncs on its own: it fetches at its start and when CloudKit reports changes, and it sends pending changes in batches, each saved atomically, retrying network failures, rate limits, and unavailable service itself.
@MainActor
public protocol SyncEngineClient: AnyObject {
    /// The changes not sent yet: the zone's changes, then the records' changes, each in the order they were added. A send removes each change it sends, except those that fail for a reason the engine retries.
    var pendingChanges: [SyncPendingChange] { get }

    /// Adds changes to send. A change already pending is not added again. A record's save replaces its pending deletion and a deletion its pending save, and the same holds for the zone's.
    func add(_ changes: [SyncPendingChange])

    /// Removes pending changes, such as the saves that a comparison no longer returns.
    func remove(_ changes: [SyncPendingChange])

    /// Fetches the zone's changes now and returns once the fetch's events have been handled.
    func fetchChanges() async throws

    /// Sends the pending changes now and returns once the send's events have been handled. One send asks for batches until no pending record change is left, so a change added while the delegate handles one of its batches, such as a merged save, goes in the same send.
    func sendChanges() async throws

    /// Stops the engine before the controller drops it, as when sync turns off or an account change ends it. The engine then reports no event, ignores `add(_:)`, `remove(_:)`, `fetchChanges()`, and `sendChanges()`, drops its pending changes, the zone's included, so it has nothing left to send, and cancels its operations. The last state update that `sync.json` kept still holds the pending changes. An operation already under way can still finish, since CloudKit cancels operations asynchronously, and the engine can still fetch on its own until it is freed, but nothing of either reaches the delegate or `sync.json`.
    func stop() async
}

/// Creates and starts an engine on `database`, a database that `SyncAvailability` found available, since `CKContainer` raises an exception for a container the app is not entitled to. `stateSerialization` is the engine state that `sync.json` kept for the same database (`SyncMirror.read(from:database:)`), never another container's or environment's, or nil for a first sync.
public typealias SyncEngineFactory = @MainActor (_ database: SyncDatabase, _ stateSerialization: Data?, _ delegate: any SyncEngineDelegate) -> any SyncEngineClient
