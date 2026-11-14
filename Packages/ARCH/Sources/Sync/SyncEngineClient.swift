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

/// What the engine reports, in the order it happens.
public enum SyncEvent: Equatable, Sendable {
    /// The engine's state changed, such as its change token or its pending changes. `sync.json` keeps the serialization (`SyncMirror.engineState`) for the engine's next start on the same database.
    case stateUpdate(Data)
    case accountChange(SyncAccountChange)
    /// One page of a fetch.
    case fetchedChanges(SyncFetchedChanges)
    /// A fetch found this zone deleted. It can be another zone than `ArchSync1`, which the controller ignores.
    case zoneDeleted(CKRecordZone.ID, SyncZoneDeletionReason)
    /// A fetch ended, after every page it brought. A child whose parent has not arrived waits until then (`docs/sync.md`, Mapping the session store to records ▸ Incoming changes).
    case fetchEnded
    /// One batch was sent.
    case sentChanges(SyncSentChanges)
}

/// What the engine asks of the controller. The engine holds its delegate weakly.
@MainActor
public protocol SyncEngineDelegate: AnyObject {
    /// Handles one event. The engine reports its next event and builds its next batch only after this returns, so the changes applied and the comparisons run here come before the next send. To fetch or send in response, start a task: the engine waits for the handling to end before it fetches or sends again.
    func handle(_ event: SyncEvent)

    /// The record to send for the pending save of `recordName`, built on the mirror's copy, or on the server's record of a refused save, with the pending save's fields (`SyncCloudKitRecords.ckRecord(from:base:)`). Nil when nothing is left to save, and the engine then drops the pending save.
    func record(toSave recordName: String) -> CKRecord?
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

    /// Sends the pending changes now and returns once the send's events have been handled.
    func sendChanges() async throws

    /// Cancels the engine's operations. It reports no event after this, and fetches and sends nothing, so turning sync off or an account change that ends sync stops the engine before dropping it.
    func stop() async
}

/// Creates and starts an engine on `database`, a database that `SyncAvailability` found available, since `CKContainer` raises an exception for a container the app is not entitled to. `stateSerialization` is the engine state that `sync.json` kept for the same database (`SyncMirror.read(from:database:)`), never another container's or environment's, or nil for a first sync.
public typealias SyncEngineFactory = @MainActor (_ database: SyncDatabase, _ stateSerialization: Data?, _ delegate: any SyncEngineDelegate) -> any SyncEngineClient
