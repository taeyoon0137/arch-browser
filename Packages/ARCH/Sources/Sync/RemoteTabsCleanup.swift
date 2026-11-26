// After sync stops, this Mac retries deletion without uploading or applying sidebar data.
import CloudKit
import Foundation

@MainActor final class RemoteTabsCleanup: SyncEngineDelegate {
    private let deviceID: String
    private let finished: () -> Void
    private var engine: (any SyncEngineClient)?
    private var names = Set<String>()
    private var fetched = false
    private var completed = false
    var canSendRecords: Bool { fetched && !completed }

    init(database: SyncDatabase, deviceID: String, factory: SyncEngineFactory, finished: @escaping () -> Void) {
        self.deviceID = deviceID
        self.finished = finished
        engine = factory(database, nil, self)
    }

    func run() async {
        guard let engine, !completed else { return }
        do {
            try await engine.fetchChanges()
            if canSendRecords { try await engine.sendChanges() }
            if completed { await engine.stop() }
        } catch { return }
    }

    func stop() async { await engine?.stop(); engine = nil }
    func record(toSave recordName: String) -> CKRecord? { nil }

    func handle(_ event: SyncEvent) {
        guard !completed else { return }
        switch event {
        case .fetchStarted: fetched = false
        case .fetchedChanges(let changes):
            for row in changes.records where SyncCloudKitRecords.isInZone(row.recordID) {
                if let record = SyncCloudKitRecords.syncRecord(from: row), RemoteTabsRecords.owns(record, deviceID: deviceID) {
                    names.insert(record.recordName)
                }
            }
            for deletion in changes.deletions where SyncCloudKitRecords.isInZone(deletion.recordID) {
                names.remove(deletion.recordID.recordName)
            }
        case .fetchEnded(let error):
            if error == .zoneNotFound { complete(); return }
            guard error == nil else { return }
            fetched = true
            if names.isEmpty { complete() }
            else { engine?.add(names.sorted().map(SyncPendingChange.deleteRecord)) }
        case .sentChanges(let changes):
            names.subtract(changes.deletedRecordNames)
            if fetched && names.isEmpty { complete() }
        case .zoneDeleted(let zone, _):
            if zone == SyncCloudKitRecords.zoneID { complete() }
        case .accountChange(let change):
            if change != .signIn { complete() }
        default: break
        }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        finished()
        let previous = engine
        engine = nil
        Task { await previous?.stop() }
    }
}
