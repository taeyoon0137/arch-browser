// The comparison of the records built from this Mac's state with the mirror's (`docs/sync.md`, Mapping the session store to records ▸ Outgoing changes). Sync runs it after each session save and settings change and after each change to the mirror, but only once the session has applied every change the mirror holds. Its result replaces the pending changes of the records in its scope, so a record that changes again before it is sent stays one pending change.
import Foundation

/// Every change this Mac still has to send.
public struct SyncChanges: Hashable, Sendable {
    /// The records to save, one for each record name, in the order of the local records. Each has its order key, each field's edit time, `modifiedAt`, and the mirror copy's fields that this build does not know, with their edit times.
    public var saves: [SyncRecord]
    /// The record names to delete, sorted: the mirror's records in the comparison's scope that the local state no longer has.
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
    /// A field with the mirror's value keeps the mirror's edit time. Any other field keeps the time from `pending` while its value stays the one found there and that time is later than the mirror's time for the field, even when other fields of the record change, and otherwise takes `now`. A pending time no later than the mirror's predates the mirror's value, so the value found again counts as a new edit. Edits made while sync was off take the time of the first comparison after it turns on again. A record whose known fields all equal the mirror's needs no save.
    /// - Parameters:
    ///   - local: The records built from this Mac's state, in sidebar order, without order keys or edit times. The order of each sibling list (`SyncOrderKeys.SiblingList`) in this array is the order to keep. Fields this build does not know for a record's type are ignored. When a record name appears twice, the first record counts.
    ///   - scope: Which mirror records `local` lists in full. A mirror record in scope that `local` lacks is deleted, and one out of scope is left alone. The sidebar's comparison takes the sidebar's record types; the settings' takes the `Setting` records of the keys this build lists, without those whose mirror value it cannot apply (`docs/sync.md`, Settings list). The two therefore compare apart, and a newer build's settings survive.
    ///   - mirror: The last known server records. Every change they hold must already be applied to the state that `local` comes from, or the comparison would delete or undo it.
    ///   - pending: Every save not sent yet, from either comparison.
    ///   - now: When this comparison runs.
    public static func changes(local: [SyncRecord], scope: (SyncRecord) -> Bool, mirror: [SyncRecord], pending: [SyncRecord], foundAt now: Date) -> SyncChanges {
        let mirrorByName = Dictionary(mirror.map { ($0.recordName, $0) }) { first, _ in first }
        let pendingByName = Dictionary(pending.map { ($0.recordName, $0) }) { first, _ in first }
        var localNames = Set<String>()
        let records = local.filter { localNames.insert($0.recordName).inserted }
        let ordered = withOrderKeys(records, mirror: mirrorByName, pending: pendingByName)
        let saves = ordered.compactMap { record in
            save(for: record, mirror: mirrorByName[record.recordName], pending: pendingByName[record.recordName], foundAt: now)
        }
        let deletions = Set(mirror.filter { scope($0) && !localNames.contains($0.recordName) }.map(\.recordName))
        return SyncChanges(saves: saves, deletions: deletions.sorted())
    }

    /// Sets each record's order key from its place in its sibling list (`SyncOrderKeys.keys(for:existing:pending:)`). The keys of mirror copies in the same list come first, so a move writes only the moved records, and a pending save's key in the same list holds where it still fits between them.
    private static func withOrderKeys(_ records: [SyncRecord], mirror: [String: SyncRecord], pending: [String: SyncRecord]) -> [SyncRecord] {
        var lists: [SyncOrderKeys.SiblingList: [Int]] = [:]
        for (index, record) in records.enumerated() {
            if let list = SyncOrderKeys.SiblingList(of: record) { lists[list, default: []].append(index) }
        }
        var result = records
        for (list, indices) in lists {
            let names = indices.map { records[$0].recordName }
            let keys = SyncOrderKeys.keys(for: names, existing: orderKeys(of: names, in: list, copies: mirror), pending: orderKeys(of: names, in: list, copies: pending))
            for (index, key) in zip(indices, keys) {
                result[index][.order] = .number(key)
            }
        }
        return result
    }

    /// The order keys of the copies among `copies` that sort in `list`, by record name.
    private static func orderKeys(of names: [String], in list: SyncOrderKeys.SiblingList, copies: [String: SyncRecord]) -> [String: Double] {
        var keys: [String: Double] = [:]
        for name in names {
            if let copy = copies[name], SyncOrderKeys.SiblingList(of: copy) == list { keys[name] = SyncOrderKeys.key(of: copy) }
        }
        return keys
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
                // A pending time counts only for an edit later than the mirror's, since a fetch can replace the field and the value can come back later.
                let mirrorTime = mirror.map { $0.fieldModifiedAt[field] ?? $0.modifiedAt }
                var time = now
                if let pending, pending.fields[field] == value, let pendingTime = pending.fieldModifiedAt[field], mirrorTime.map({ pendingTime > $0 }) ?? true {
                    time = pendingTime
                }
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
