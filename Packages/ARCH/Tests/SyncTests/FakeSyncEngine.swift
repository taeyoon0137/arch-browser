// A sync engine for tests (docs/sync.md, Module layout). It keeps pending changes in memory as `CKSyncEngine` keeps them, builds each send's records through its delegate, saves a batch atomically, and reports the events a test scripts, so no test reaches CloudKit's servers.
import CloudKit
import Foundation
@testable import Sync

@MainActor
final class FakeSyncEngine: SyncEngineClient {
    /// What one send sent.
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
    /// The failure for the next save of each record name. A batch with a failure saves nothing, as an atomic batch does, and its other changes stay pending, as `CloudKitSyncEngine` adds them again.
    var saveFailures: [String: SyncSaveFailure] = [:]
    private(set) var fetchCount = 0
    private(set) var batches: [Batch] = []
    /// The zone's changes that sends have sent, in order.
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

    /// The state serialization, which holds the pending changes.
    var stateSerialization: Data {
        (try? JSONEncoder().encode(pendingChanges.map(StoredChange.init))) ?? Data()
    }

    var pendingChanges: [SyncPendingChange] {
        zoneChanges + recordChanges
    }

    func add(_ changes: [SyncPendingChange]) {
        for change in changes {
            let isZoneChange = change == .saveZone || change == .deleteZone
            var list = isZoneChange ? zoneChanges : recordChanges
            list.removeAll { $0 == Self.opposite(of: change) }
            if !list.contains(change) { list.append(change) }
            if isZoneChange { zoneChanges = list } else { recordChanges = list }
        }
    }

    func remove(_ changes: [SyncPendingChange]) {
        zoneChanges.removeAll(where: changes.contains)
        recordChanges.removeAll(where: changes.contains)
    }

    /// Reports the fetch script, then the state and the fetch's end.
    func fetchChanges() async throws {
        guard !isStopped else { return }
        fetchCount += 1
        let script = fetchScript
        fetchScript = []
        deliver(script)
        deliver([.stateUpdate(stateSerialization)])
        deliver([.fetchEnded])
    }

    /// Sends the zone's changes, then every pending record change in one batch, and reports the batch and the state.
    func sendChanges() async throws {
        guard !isStopped else { return }
        sentZoneChanges += zoneChanges
        zoneChanges = []
        let changes = recordChanges
        recordChanges = []
        var records: [CKRecord] = []
        var deletions: [String] = []
        var failures: [SyncFailedSave] = []
        var sent: [SyncPendingChange] = []
        for change in changes {
            switch change {
            case .saveRecord(let name):
                // A save without a record leaves the pending changes, as `CloudKitSyncEngine` drops it.
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
            deliver([.stateUpdate(stateSerialization)])
            return
        }
        batches.append(Batch(records: records, deletedRecordNames: deletions))
        guard failures.isEmpty else {
            let refused = Set(failures.map { SyncPendingChange.saveRecord($0.recordName) })
            add(sent.filter { !refused.contains($0) })
            deliver([.sentChanges(SyncSentChanges(failedSaves: failures)), .stateUpdate(stateSerialization)])
            return
        }
        deliver([.sentChanges(SyncSentChanges(savedRecords: records, deletedRecordNames: deletions)), .stateUpdate(stateSerialization)])
    }

    func stop() async {
        isStopped = true
    }

    /// Reports events as the engine does, one after another, until it stops.
    func deliver(_ events: [SyncEvent]) {
        for event in events {
            guard !isStopped, let delegate else { return }
            delegate.handle(event)
        }
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
