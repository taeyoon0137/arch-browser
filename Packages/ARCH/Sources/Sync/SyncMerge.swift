// The per-field merge of this Mac's version of a record with the server's (`docs/sync.md`, Conflicts; sync decision 3). Sync uses it for a save that the server refuses because another Mac saved the record first, and for each fetched record that this Mac also changed.
import Foundation

/// Merges two versions of one record, using the mirror's copy, the last server record this Mac knew, as their common base.
public enum SyncMerge {
    public struct Result: Hashable, Sendable {
        /// The merged record, with the server's record type and record name. When `needsSend` is false, this is the server's record unchanged.
        public var record: SyncRecord
        /// Whether the merged record differs from the server's, so that this Mac must send it.
        public var needsSend: Bool
    }

    /// Merges `local` and `server` field by field against `base`:
    /// - A field changed on one side takes that side's value. A field that side removed stays removed.
    /// - A field changed on both sides to different values takes the value of the side with the later `modifiedAt`, or the server's on a tie. Both sides changing it to the same value is no conflict.
    /// - Without a base, both sides count as changed, as for a `Setting` that two Macs first write, and a field that only one side has survives.
    /// - A field that this build does not know for the record type (`SyncRecordType.fields`) counts as unchanged on this Mac, which cannot edit it, so it keeps the server's value.
    ///
    /// A merged record that must be sent takes the later `modifiedAt` of the two, so that other Macs compare their edits with its latest one, and the higher `schemaVersion`, since it can hold fields of the newer format.
    public static func merge(local: SyncRecord, server: SyncRecord, base: SyncRecord?) -> Result {
        assert(local.recordName == server.recordName && local.recordType == server.recordType, "SyncMerge merges two versions of one record")
        let knownFields = server.recordType.fields
        var fieldNames = Set(local.fields.keys).union(server.fields.keys)
        if let base { fieldNames.formUnion(base.fields.keys) }

        var merged: [String: SyncValue] = [:]
        for fieldName in fieldNames {
            let isKnown = SyncField(rawValue: fieldName).map(knownFields.contains) ?? false
            let localValue = local.fields[fieldName]
            let serverValue = server.fields[fieldName]
            let localChanged: Bool
            let serverChanged: Bool
            if let base {
                let baseValue = base.fields[fieldName]
                localChanged = isKnown && localValue != baseValue
                serverChanged = serverValue != baseValue
            } else {
                // Nothing tells which side set the field, so each side that has a value counts as changed, and a side without one yields to the other. This Mac's value of a field it does not know yields to the server's.
                localChanged = localValue != nil && (isKnown || serverValue == nil)
                serverChanged = serverValue != nil
            }
            if localChanged && serverChanged && localValue != serverValue {
                merged[fieldName] = local.modifiedAt > server.modifiedAt ? localValue : serverValue
            } else {
                merged[fieldName] = localChanged ? localValue : serverValue
            }
        }

        guard merged != server.fields else { return Result(record: server, needsSend: false) }
        let record = SyncRecord(
            recordType: server.recordType,
            recordName: server.recordName,
            fields: merged,
            modifiedAt: max(local.modifiedAt, server.modifiedAt),
            schemaVersion: max(local.schemaVersion, server.schemaVersion)
        )
        return Result(record: record, needsSend: true)
    }
}
