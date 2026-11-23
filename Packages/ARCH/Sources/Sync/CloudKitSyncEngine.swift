// The sync engine on CloudKit (`docs/sync.md`, Container, database, and zone, Conflicts, and Offline behavior): one `CKSyncEngine` on the private database of the container that the app's entitlements name, which fetches only the zone `ArchSync1` and sends each batch atomically. It turns the engine's events and CloudKit's errors into Arch's own (`SyncEvent`), so the controller and its tests use no `CKSyncEngine` type.
import CloudKit
import Foundation

/// Implements `SyncEngineClient` with `CKSyncEngine`.
@MainActor
public final class CloudKitSyncEngine: SyncEngineClient {
    private let engine: CKSyncEngine
    /// The engine's delegate. The engine holds it weakly, so this keeps it.
    private let relay: Relay

    /// Creates and starts the engine on the private database of `database`'s container. `database` must come from `SyncAvailability.Status.available`: `CKContainer` raises an exception for a container the app is not entitled to. A state serialization that does not decode counts as none, so the engine fetches the zone from its start and the controller merges every record with its mirror copy.
    public init(database: SyncDatabase, stateSerialization: Data?, delegate: any SyncEngineDelegate) {
        relay = Relay(delegate: delegate)
        let state = stateSerialization.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let privateDatabase = CKContainer(identifier: database.containerIdentifier).privateCloudDatabase
        engine = CKSyncEngine(CKSyncEngine.Configuration(database: privateDatabase, stateSerialization: state, delegate: relay))
    }

    public var pendingChanges: [SyncPendingChange] {
        engine.state.pendingDatabaseChanges.compactMap(Self.change(from:)) + engine.state.pendingRecordZoneChanges.compactMap(Self.change(from:))
    }

    public func add(_ changes: [SyncPendingChange]) {
        guard !relay.isStopped else { return }
        let databaseChanges = changes.compactMap(Self.databaseChange(for:))
        let recordChanges = changes.compactMap(Self.recordZoneChange(for:))
        if !databaseChanges.isEmpty { engine.state.add(pendingDatabaseChanges: databaseChanges) }
        if !recordChanges.isEmpty { engine.state.add(pendingRecordZoneChanges: recordChanges) }
    }

    public func remove(_ changes: [SyncPendingChange]) {
        guard !relay.isStopped else { return }
        let removed = Set(changes)
        // Removes the engine's own values, so they match whatever way the engine compares its changes.
        let databaseChanges = engine.state.pendingDatabaseChanges.filter { Self.change(from: $0).map(removed.contains) ?? false }
        let recordChanges = engine.state.pendingRecordZoneChanges.filter { Self.change(from: $0).map(removed.contains) ?? false }
        if !databaseChanges.isEmpty { engine.state.remove(pendingDatabaseChanges: databaseChanges) }
        if !recordChanges.isEmpty { engine.state.remove(pendingRecordZoneChanges: recordChanges) }
    }

    public func fetchChanges() async throws {
        guard !relay.isStopped else { return }
        try await engine.fetchChanges(Self.fetchOptions())
    }

    public func sendChanges() async throws {
        guard !relay.isStopped else { return }
        try await engine.sendChanges()
    }

    public func stop() async {
        relay.isStopped = true
        // The engine sends the zone's changes without asking the delegate, so only an empty list keeps it from sending them. Its state update is not delivered, so `sync.json` keeps the changes.
        let state = engine.state
        let databaseChanges = state.pendingDatabaseChanges
        let recordChanges = state.pendingRecordZoneChanges
        if !databaseChanges.isEmpty { state.remove(pendingDatabaseChanges: databaseChanges) }
        if !recordChanges.isEmpty { state.remove(pendingRecordZoneChanges: recordChanges) }
        await engine.cancelOperations()
    }

    // MARK: - Mapping

    /// The options of every fetch, the engine's own and those of `fetchChanges()`: only the zone `ArchSync1`. The default scope, `.all`, would also fetch a later build's zone, such as `ArchSync2`, whose records mean something else under the same names (`docs/sync.md`, Container, database, and zone).
    nonisolated static func fetchOptions(from options: CKSyncEngine.FetchChangesOptions = .init()) -> CKSyncEngine.FetchChangesOptions {
        var options = options
        options.scope = .zoneIDs([SyncCloudKitRecords.zoneID])
        options.prioritizedZoneIDs = options.prioritizedZoneIDs.filter { $0 == SyncCloudKitRecords.zoneID }
        return options
    }

    /// Whether the engine keeps a change that failed with `code` pending and sends it again, so nothing reports it: a network failure, a rate limit, an unavailable service or account, a busy zone, and a missing authentication. A cancelled operation comes only from `stop()`, after which nothing is reported.
    nonisolated static func isRetried(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable, .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled: true
        default: false
        }
    }

    /// The failure to report for a save that the server refused with `error`, or nil for none: one the engine retries (`isRetried(_:)`), or one that failed only because another record of its atomic batch failed (`batchRequestFailed`), which is sent again (`changesToResend(failedSaves:failedDeletes:)`).
    nonisolated static func failure(for error: CKError) -> SyncSaveFailure? {
        guard !isRetried(error.code) else { return nil }
        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord else { return .other(error.code) }
            return .serverRecordChanged(serverRecord)
        case .unknownItem:
            return .unknownItem
        case .zoneNotFound:
            return .zoneNotFound
        case .batchRequestFailed:
            return nil
        default:
            return .other(error.code)
        }
    }

    /// The zone's sent changes as Arch reports them, or nil when nothing is left to report: the zone `ArchSync1` saved or deleted, and the save or deletion that the server refused for a reason the engine does not retry. Other zones, which this engine never adds, are left out.
    nonisolated static func sentZoneChanges(savedZoneIDs: [CKRecordZone.ID], deletedZoneIDs: [CKRecordZone.ID], failedSaves: [(zoneID: CKRecordZone.ID, error: CKError)], failedDeletes: [CKRecordZone.ID: CKError]) -> SyncSentZoneChanges? {
        let zoneID = SyncCloudKitRecords.zoneID
        let refused = { (error: CKError?) in error.map(\.code).flatMap { isRetried($0) ? nil : $0 } }
        let sent = SyncSentZoneChanges(
            savedZone: savedZoneIDs.contains(zoneID),
            deletedZone: deletedZoneIDs.contains(zoneID),
            failedSave: refused(failedSaves.first { $0.zoneID == zoneID }?.error),
            failedDelete: refused(failedDeletes[zoneID])
        )
        return sent == SyncSentZoneChanges() ? nil : sent
    }

    /// The failure that a fetch's end reports, `current` until now, once the engine's fetch of `zoneID` ended with `error`: CloudKit's code when the fetch of `ArchSync1` failed, and nil when it completed, as when the engine fetched it again within the same fetch. Another zone, which this engine never fetches, leaves `current`.
    nonisolated static func fetchFailure(_ current: CKError.Code?, afterFetchOf zoneID: CKRecordZone.ID, error: CKError?) -> CKError.Code? {
        zoneID == SyncCloudKitRecords.zoneID ? error?.code : current
    }

    /// The changes to add again after a batch: the saves and deletions that the server refused only because another record of the same atomic batch failed (`batchRequestFailed`). The engine keeps only the changes that fail for a reason it retries, so it would drop these. Saves keep their order in the batch, and deletions follow, sorted by record name.
    nonisolated static func changesToResend(failedSaves: [(recordID: CKRecord.ID, error: CKError)], failedDeletes: [CKRecord.ID: CKError]) -> [CKSyncEngine.PendingRecordZoneChange] {
        let saves = failedSaves.filter { $0.error.code == .batchRequestFailed }.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.recordID) }
        let deletions = failedDeletes.filter { $0.value.code == .batchRequestFailed }.keys.sorted { $0.recordName < $1.recordName }.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord($0) }
        return saves + deletions
    }

    /// The sent batch as Arch reports it: the records saved, the names of the records deleted, and the refused saves that the engine does not retry.
    nonisolated static func sentChanges(savedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], failedSaves: [(record: CKRecord, error: CKError)]) -> SyncSentChanges {
        SyncSentChanges(
            savedRecords: savedRecords,
            deletedRecordNames: deletedRecordIDs.map(\.recordName),
            failedSaves: failedSaves.compactMap { failed in
                failure(for: failed.error).map { SyncFailedSave(recordName: failed.record.recordID.recordName, failure: $0) }
            }
        )
    }

    /// Arch's events for one of the engine's events. A fetch's end carries `fetchFailure`, the failure of the zone's fetch within that fetch (`fetchFailure(_:afterFetchOf:error:)`). The engine's events that Sync does not use, such as the start of a send, give none, and so does the end of a zone's fetch, which only `fetchFailure` reports.
    nonisolated static func events(from event: CKSyncEngine.Event, fetchFailure: CKError.Code?) -> [SyncEvent] {
        switch event {
        case .stateUpdate(let update):
            // A serialization that does not encode leaves `sync.json` with the previous state; the next update writes it.
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else { return [] }
            return [.stateUpdate(data)]
        case .accountChange(let change):
            return [.accountChange(SyncAccountChange(change.changeType))]
        case .fetchedDatabaseChanges(let changes):
            return changes.deletions.map { .zoneDeleted($0.zoneID, SyncZoneDeletionReason($0.reason)) }
        case .fetchedRecordZoneChanges(let changes):
            let deletions = changes.deletions.map { SyncFetchedChanges.Deletion(recordID: $0.recordID, recordType: $0.recordType) }
            return [.fetchedChanges(SyncFetchedChanges(records: changes.modifications.map(\.record), deletions: deletions))]
        case .didFetchChanges:
            return [.fetchEnded(failure: fetchFailure)]
        case .sentRecordZoneChanges(let sent):
            return [.sentChanges(sentChanges(savedRecords: sent.savedRecords, deletedRecordIDs: sent.deletedRecordIDs, failedSaves: sent.failedRecordSaves.map { ($0.record, $0.error) }))]
        case .sentDatabaseChanges(let sent):
            let zoneChanges = sentZoneChanges(savedZoneIDs: sent.savedZones.map(\.zoneID), deletedZoneIDs: sent.deletedZoneIDs, failedSaves: sent.failedZoneSaves.map { ($0.zone.zoneID, $0.error) }, failedDeletes: sent.failedZoneDeletes)
            return zoneChanges.map { [.sentZoneChanges($0)] } ?? []
        case .willFetchChanges: return [.fetchStarted]
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
            return []
        @unknown default:
            return []
        }
    }

    /// The engine's change for a record's save or deletion in the zone, or nil for the zone's own changes.
    nonisolated static func recordZoneChange(for change: SyncPendingChange) -> CKSyncEngine.PendingRecordZoneChange? {
        switch change {
        case .saveRecord(let name): .saveRecord(SyncCloudKitRecords.recordID(named: name))
        case .deleteRecord(let name): .deleteRecord(SyncCloudKitRecords.recordID(named: name))
        case .saveZone, .deleteZone: nil
        }
    }

    /// The engine's change for the zone's save or deletion, or nil for a record's.
    nonisolated static func databaseChange(for change: SyncPendingChange) -> CKSyncEngine.PendingDatabaseChange? {
        switch change {
        case .saveZone: .saveZone(CKRecordZone(zoneID: SyncCloudKitRecords.zoneID))
        case .deleteZone: .deleteZone(SyncCloudKitRecords.zoneID)
        case .saveRecord, .deleteRecord: nil
        }
    }

    /// The pending change for the engine's record change, or nil for a record of another zone, which this engine never adds.
    nonisolated static func change(from change: CKSyncEngine.PendingRecordZoneChange) -> SyncPendingChange? {
        switch change {
        case .saveRecord(let recordID): SyncCloudKitRecords.isInZone(recordID) ? .saveRecord(recordID.recordName) : nil
        case .deleteRecord(let recordID): SyncCloudKitRecords.isInZone(recordID) ? .deleteRecord(recordID.recordName) : nil
        @unknown default: nil
        }
    }

    /// The pending change for the engine's database change, or nil for another zone, which this engine never adds.
    nonisolated static func change(from change: CKSyncEngine.PendingDatabaseChange) -> SyncPendingChange? {
        switch change {
        case .saveZone(let zone): zone.zoneID == SyncCloudKitRecords.zoneID ? .saveZone : nil
        case .deleteZone(let zoneID): zoneID == SyncCloudKitRecords.zoneID ? .deleteZone : nil
        @unknown default: nil
        }
    }
}

extension SyncAccountChange {
    /// The change for the engine's account change. One this build does not know counts as a switch, which turns sync off and keeps the local sidebar.
    init(_ changeType: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch changeType {
        case .signIn: self = .signIn
        case .signOut: self = .signOut
        case .switchAccounts: self = .switchAccounts
        @unknown default: self = .switchAccounts
        }
    }
}

extension SyncZoneDeletionReason {
    /// The reason for CloudKit's. One this build does not know counts as `deleted`, which turns sync off and keeps local data, as a missing zone without a reported deletion does (`docs/sync.md`, Offline behavior).
    init(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) {
        switch reason {
        case .deleted: self = .deleted
        case .purged: self = .purged
        case .encryptedDataReset: self = .encryptedDataReset
        @unknown default: self = .deleted
        }
    }
}

/// The `CKSyncEngine` delegate. It hands events and record requests to the controller's delegate, which it holds weakly so that the controller owning the engine is freed with it, and it hands over nothing once the engine stops.
@MainActor
private final class Relay: CKSyncEngineDelegate {
    weak var delegate: (any SyncEngineDelegate)?
    var isStopped = false
    /// The failure of the zone's fetch within the fetch under way, which its end reports.
    private var fetchFailure: CKError.Code?

    init(delegate: any SyncEngineDelegate) {
        self.delegate = delegate
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await report(event, syncEngine: syncEngine)
    }

    /// The next batch: the pending record changes within the send's scope, as many as fit in one request, saved atomically (`docs/sync.md`, Conflicts). A change outside the scope would fail the send. A save the delegate has no record for leaves the pending changes, so the engine does not ask for it again.
    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard await canBuildBatch else { return nil }
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        await beginBatch()
        var batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            if let record = await self.record(toSave: recordID.recordName) { return record }
            guard await self.canBuildBatch else { return nil }
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        await endBatch()
        // The provider can suspend while stop() clears the queue.
        guard await canBuildBatch else { return nil }
        batch?.atomicByZone = true
        return batch
    }

    nonisolated func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        CloudKitSyncEngine.fetchOptions(from: context.options)
    }

    private var canBuildBatch: Bool { !isStopped && delegate?.canSendRecords == true }

    /// The delegates told that a batch build began, kept until it ends, so each `willBuildBatch()` gets its `didBuildBatch()` even after a stop or a weak delegate's release.
    private var buildingFor: [(any SyncEngineDelegate)?] = []

    private func beginBatch() {
        buildingFor.append(delegate)
        delegate?.willBuildBatch()
    }

    private func endBatch() {
        guard !buildingFor.isEmpty else { return }
        buildingFor.removeLast()?.didBuildBatch()
    }

    private var isRunning: Bool {
        !isStopped && delegate != nil
    }

    /// Hands over Arch's events for the engine's event, keeping the zone fetch's failure from a fetch's start to its end.
    private func report(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        // Check and requeue on the same actor as stop(), so a late event cannot refill the cleared queue.
        guard isRunning else { return }
        switch event {
        case .sentRecordZoneChanges(let sent):
            let resend = CloudKitSyncEngine.changesToResend(failedSaves: sent.failedRecordSaves.map { ($0.record.recordID, $0.error) }, failedDeletes: sent.failedRecordDeletes)
            if !resend.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: resend) }
        case .willFetchChanges:
            fetchFailure = nil
        case .didFetchRecordZoneChanges(let fetched):
            fetchFailure = CloudKitSyncEngine.fetchFailure(fetchFailure, afterFetchOf: fetched.zoneID, error: fetched.error)
        default:
            break
        }
        let events = CloudKitSyncEngine.events(from: event, fetchFailure: fetchFailure)
        if case .didFetchChanges = event { fetchFailure = nil }
        deliver(events)
    }

    private func deliver(_ events: [SyncEvent]) {
        for event in events {
            guard !isStopped, let delegate else { return }
            delegate.handle(event)
        }
    }

    private func record(toSave recordName: String) -> CKRecord? {
        guard !isStopped else { return nil }
        return delegate?.record(toSave: recordName)
    }
}
