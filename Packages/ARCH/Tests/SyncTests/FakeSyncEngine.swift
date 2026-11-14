// A sync engine for tests (docs/sync.md, Module layout). It keeps pending changes in memory as `CKSyncEngine` keeps them, sends the zone's changes and then batches of record changes until none is left, builds each batch's records through its delegate, saves a batch atomically, and reports the events and failures a test scripts, so no test reaches CloudKit's servers.
import CloudKit
import Foundation
@testable import Sync

@MainActor
final class FakeSyncEngine: SyncEngineClient {
    enum SendError: Error {
        case batchLimitExceeded
    }

    /// What one batch sent.
    struct Batch: Equatable {
        /// The records the delegate built for the batch's saves, saved or refused.
        var records: [CKRecord]
        var deletedRecordNames: [String]
    }

    let database: SyncDatabase
    /// The state serialization the engine started from.
    let startedFrom: Data?
    private weak var delegate: (any SyncEngineDelegate)?
    private var zoneChanges: [SyncPendingChange] = []
    private var recordChanges: [SyncPendingChange] = []

    /// The events the next fetch reports before its state update and its end, such as fetched changes and zone deletions.
    var fetchScript: [SyncEvent] = []
    /// The failure of the next fetch's zone fetch, which its end reports and its call throws, as after a network that dropped between pages.
    var fetchFailure: CKError.Code?
    /// The failure for the next save of each record name. A batch with a failure saves nothing, as an atomic batch does, and its other changes stay pending, as `CloudKitSyncEngine` adds them back, so the send's next batch takes them.
    var saveFailures: [String: SyncSaveFailure] = [:]
    /// The failure for the next send of the zone's change. A code the engine retries (`CloudKitSyncEngine.isRetried(_:)`) keeps the change pending and reports nothing, as when offline. Any other drops the change and reports it.
    var zoneFailure: CKError.Code?
    /// The most changes one batch holds, as one request holds at most 250 records.
    var batchLimit = 250
    /// The most batches one send builds before it throws, since a delegate that adds a change back after each refusal would keep the engine sending without end.
    var batchesPerSendLimit = 100
    private(set) var fetchCount = 0
    private(set) var batches: [Batch] = []
    /// The zone's changes that the server took, in order.
    private(set) var sentZoneChanges: [SyncPendingChange] = []
    private(set) var isStopped = false

    /// Starts with the pending changes of `stateSerialization`, one that an engine of this kind reported.
    init(database: SyncDatabase, stateSerialization: Data?, delegate: any SyncEngineDelegate) {
        self.database = database
        startedFrom = stateSerialization
        self.delegate = delegate
        add(stateSerialization.flatMap { try? JSONDecoder().decode([StoredChange].self, from: $0) }?.compactMap(\.change) ?? [])
    }

    /// A factory that hands each engine it creates to `created`, so a test can script it.
    static func factory(_ created: @escaping @MainActor (FakeSyncEngine) -> Void) -> SyncEngineFactory {
        { database, stateSerialization, delegate in
            let engine = FakeSyncEngine(database: database, stateSerialization: stateSerialization, delegate: delegate)
            created(engine)
            return engine
        }
    }

    /// The state serialization of an engine with `changes` pending. The same changes always give the same bytes, so a test can compare serializations.
    static func stateSerialization(of changes: [SyncPendingChange]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(changes.map(StoredChange.init))) ?? Data()
    }

    /// The state serialization, which holds the pending changes.
    var stateSerialization: Data {
        Self.stateSerialization(of: pendingChanges)
    }

    var pendingChanges: [SyncPendingChange] {
        zoneChanges + recordChanges
    }

    func add(_ changes: [SyncPendingChange]) {
        guard !isStopped else { return }
        for change in changes {
            let isZoneChange = change == .saveZone || change == .deleteZone
            var list = isZoneChange ? zoneChanges : recordChanges
            list.removeAll { $0 == Self.opposite(of: change) }
            if !list.contains(change) { list.append(change) }
            if isZoneChange { zoneChanges = list } else { recordChanges = list }
        }
    }

    func remove(_ changes: [SyncPendingChange]) {
        guard !isStopped else { return }
        zoneChanges.removeAll(where: changes.contains)
        recordChanges.removeAll(where: changes.contains)
    }

    /// Reports the fetch script, then the state and the fetch's end, and throws the scripted failure.
    func fetchChanges() async throws {
        guard !isStopped else { return }
        fetchCount += 1
        let script = fetchScript
        let failure = fetchFailure
        fetchScript = []
        fetchFailure = nil
        deliver([.fetchStarted])
        deliver(script)
        deliverStateUpdate()
        deliver([.fetchEnded(failure: failure)])
        if let failure { throw CKError(failure) }
    }

    /// Sends the zone's changes, then batches of the pending record changes until none is left, the changes added while the delegate handles a batch included, and reports each with the state.
    func sendChanges() async throws {
        guard !isStopped else { return }
        sendZoneChanges()
        var count = 0
        while !isStopped, delegate?.canSendRecords == true, !recordChanges.isEmpty {
            guard count < batchesPerSendLimit else {
                throw SendError.batchLimitExceeded
            }
            count += 1
            sendBatch()
        }
    }

    /// Drops the pending changes, as `CloudKitSyncEngine` does, so a later engine starts from the state update a test kept.
    func stop() async {
        isStopped = true
        zoneChanges = []
        recordChanges = []
    }

    /// Reports events as the engine does, one after another, until it stops.
    func deliver(_ events: [SyncEvent]) {
        for event in events {
            guard !isStopped, let delegate else { return }
            delegate.handle(event)
        }
    }

    /// Sends the zone's pending changes and reports what the server did, unless the scripted failure is one the engine retries.
    private func sendZoneChanges() {
        guard !zoneChanges.isEmpty else { return }
        let changes = zoneChanges
        let failure = zoneFailure
        zoneFailure = nil
        if let failure, CloudKitSyncEngine.isRetried(failure) { return }
        zoneChanges = []
        let sent: SyncSentZoneChanges
        if let failure {
            sent = SyncSentZoneChanges(failedSave: changes.contains(.saveZone) ? failure : nil, failedDelete: changes.contains(.deleteZone) ? failure : nil)
        } else {
            sentZoneChanges += changes
            sent = SyncSentZoneChanges(savedZone: changes.contains(.saveZone), deletedZone: changes.contains(.deleteZone))
        }
        deliver([.sentZoneChanges(sent)])
        deliverStateUpdate()
    }

    /// Sends the next batch: the pending record changes in order, up to `batchLimit`. A save without a record drops its pending change, as `CloudKitSyncEngine` drops it, and takes no place in the batch.
    private func sendBatch() {
        var records: [CKRecord] = []
        var deletions: [String] = []
        var failures: [SyncFailedSave] = []
        var sent: [SyncPendingChange] = []
        while sent.count < batchLimit, !recordChanges.isEmpty {
            let change = recordChanges.removeFirst()
            switch change {
            case .saveRecord(let name):
                guard let record = delegate?.record(toSave: name) else { continue }
                records.append(record)
                sent.append(change)
                if let failure = saveFailures.removeValue(forKey: name) { failures.append(SyncFailedSave(recordName: name, failure: failure)) }
            case .deleteRecord(let name):
                deletions.append(name)
                sent.append(change)
            case .saveZone, .deleteZone:
                break
            }
        }
        guard !sent.isEmpty else {
            deliverStateUpdate()
            return
        }
        batches.append(Batch(records: records, deletedRecordNames: deletions))
        if !failures.isEmpty {
            let refused = Set(failures.map { SyncPendingChange.saveRecord($0.recordName) })
            add(sent.filter { !refused.contains($0) })
            deliver([.sentChanges(SyncSentChanges(failedSaves: failures))])
        } else {
            deliver([.sentChanges(SyncSentChanges(savedRecords: records, deletedRecordNames: deletions))])
        }
        deliverStateUpdate()
    }

    /// Reports the state as it is once the events before it have been handled, with the changes their handling added.
    private func deliverStateUpdate() {
        deliver([.stateUpdate(stateSerialization)])
    }

    private static func opposite(of change: SyncPendingChange) -> SyncPendingChange {
        switch change {
        case .saveRecord(let name): .deleteRecord(name)
        case .deleteRecord(let name): .saveRecord(name)
        case .saveZone: .deleteZone
        case .deleteZone: .saveZone
        }
    }

    /// A pending change in the state serialization.
    private struct StoredChange: Codable {
        var kind: String
        var recordName: String?

        init(_ change: SyncPendingChange) {
            switch change {
            case .saveRecord(let name): (kind, recordName) = ("saveRecord", name)
            case .deleteRecord(let name): (kind, recordName) = ("deleteRecord", name)
            case .saveZone: kind = "saveZone"
            case .deleteZone: kind = "deleteZone"
            }
        }

        var change: SyncPendingChange? {
            switch (kind, recordName) {
            case ("saveRecord", let name?): .saveRecord(name)
            case ("deleteRecord", let name?): .deleteRecord(name)
            case ("saveZone", nil): .saveZone
            case ("deleteZone", nil): .deleteZone
            default: nil
            }
        }
    }
}
