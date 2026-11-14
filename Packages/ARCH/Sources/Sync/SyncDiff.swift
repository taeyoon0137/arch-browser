// The comparison of the records built from this Mac's state with the mirror's (`docs/sync.md`, Mapping the session store to records ▸ Outgoing changes). Sync runs it after each session save and settings change; its result replaces the pending changes, so a record that changes again before it is sent stays one pending change.
import Foundation

/// Every change this Mac still has to send.
public struct SyncChanges: Hashable, Sendable {
    /// The records to save, one for each record name, in the order of the local records. Each has its order key, each field's edit time, `modifiedAt`, and the mirror copy's fields that this build does not know, with their edit times.
    public var saves: [SyncRecord]
    /// The record names to delete, sorted: the mirror's records of the compared types that the local state no longer has.
    public var deletions: [String]

    public init(saves: [SyncRecord] = [], deletions: [String] = []) {
        self.saves = saves
        self.deletions = deletions
    }
}

/// Finds the records that differ from the mirror's copies and gives each changed field the time sync found its value.
public enum SyncDiff {
    /// Compares `local` with `mirror` and returns every change still to send.
    ///
    /// A field with the mirror's value keeps the mirror's edit time. Any other field keeps the time from `pending` while its value stays the one found there, even when other fields of the record change, and otherwise takes `now`. Edits made while sync was off therefore take the time of the first comparison after it turns on again. A record whose known fields all equal the mirror's needs no save.
    /// - Parameters:
    ///   - local: The records built from this Mac's state, in sidebar order, without order keys or edit times. The order of each sibling list (`SyncOrderKeys.SiblingList`) in this array is the order to keep. Fields this build does not know for a record's type are ignored. When a record name appears twice, the first record counts.
    ///   - types: The record types that `local` lists in full. A mirror record of one of these types that `local` lacks is deleted. Mirror records of other types are left alone, so the sidebar and the settings can be compared apart.
    ///   - mirror: The last known server records.
    ///   - pending: The saves the last comparison returned that are not sent yet.
    ///   - now: When this comparison runs.
    public static func changes(local: [SyncRecord], types: Set<SyncRecordType>, mirror: [SyncRecord], pending: [SyncRecord], foundAt now: Date) -> SyncChanges {
        let mirrorByName = Dictionary(mirror.map { ($0.recordName, $0) }) { first, _ in first }
        let pendingByName = Dictionary(pending.map { ($0.recordName, $0) }) { first, _ in first }
        var localNames = Set<String>()
        let records = local.filter { localNames.insert($0.recordName).inserted }
        let ordered = withOrderKeys(records) { [pendingByName[$0], mirrorByName[$0]].compactMap { $0 } }
        let saves = ordered.compactMap { record in
            save(for: record, mirror: mirrorByName[record.recordName], pending: pendingByName[record.recordName], foundAt: now)
        }
        let deletions = Set(mirror.filter { types.contains($0.recordType) && !localNames.contains($0.recordName) }.map(\.recordName))
        return SyncChanges(saves: saves, deletions: deletions.sorted())
    }

    /// Sets each record's order key from its place in its sibling list. A sibling keeps the key of its pending save, else of its mirror copy, when that copy is in the same list and the key is still in order (`SyncOrderKeys.keys(for:existing:)`).
    private static func withOrderKeys(_ records: [SyncRecord], earlierCopies: (String) -> [SyncRecord]) -> [SyncRecord] {
        var lists: [SyncOrderKeys.SiblingList: [Int]] = [:]
        for (index, record) in records.enumerated() {
            if let list = SyncOrderKeys.SiblingList(of: record) { lists[list, default: []].append(index) }
        }
        var result = records
        for (list, indices) in lists {
            let names = indices.map { records[$0].recordName }
            var existing: [String: Double] = [:]
            for name in names {
                let copy = earlierCopies(name).first { SyncOrderKeys.SiblingList(of: $0) == list }
                existing[name] = copy.flatMap(SyncOrderKeys.key(of:))
            }
            for (index, key) in zip(indices, SyncOrderKeys.keys(for: names, existing: existing)) {
                result[index][.order] = .number(key)
            }
        }
        return result
    }

    /// The record to save for `record`, or nil when its known fields equal the mirror's.
    private static func save(for record: SyncRecord, mirror: SyncRecord?, pending: SyncRecord?, foundAt now: Date) -> SyncRecord? {
        let knownFields = Set(record.recordType.fields.map(\.rawValue))
        // Fields this build does not know keep the mirror's values and times (`docs/sync.md`, Schema versions).
        var fields = mirror?.fields.filter { !knownFields.contains($0.key) } ?? [:]
        var times = mirror?.fieldModifiedAt.filter { !knownFields.contains($0.key) } ?? [:]
        var changeTimes: [Date] = []
        for field in knownFields {
            let value = record.fields[field]
            fields[field] = value
            if value == mirror?.fields[field] {
                times[field] = mirror?.fieldModifiedAt[field]
            } else {
                let time = pending.flatMap { $0.fields[field] == value ? $0.fieldModifiedAt[field] : nil } ?? now
                times[field] = time
                changeTimes.append(time)
            }
        }
        guard mirror == nil || !changeTimes.isEmpty else { return nil }
        return SyncRecord(
            recordType: record.recordType,
            recordName: record.recordName,
            fields: fields,
            fieldModifiedAt: times,
            modifiedAt: max(changeTimes.max() ?? now, mirror?.modifiedAt ?? .distantPast),
            schemaVersion: max(mirror?.schemaVersion ?? SyncRecord.currentSchemaVersion, SyncRecord.currentSchemaVersion)
        )
    }
}
