// The per-field merge of this Mac's version of a record with the server's (`docs/sync.md`, Conflicts and First sync on a Mac; sync decisions 3 and 4). Sync uses it for a save that the server refuses because another Mac saved the record first, for each fetched record that this Mac also changed, and at a first sync for each local record with the record name of a server record.
import Foundation

/// Merges two versions of one record, one unit of fields at a time.
public enum SyncMerge {
    /// What the merge knows of the two versions' common past.
    public enum Base: Hashable, Sendable {
        /// The mirror's copy: the last server record this Mac knew.
        case mirror(SyncRecord)
        /// No mirror copy while sync runs: both Macs wrote the record first, as two Macs that first write a `Setting`, whose record name is fixed.
        case firstWrite
        /// No mirror copy at this Mac's first sync. This Mac's edit times are when sync found its values, not when the user made them, so they cannot outweigh the server's (sync decision 4).
        case firstSync
    }

    public struct Result: Hashable, Sendable {
        /// The merged record, with the server's record type and record name. When `needsSend` is false, this is the server's record unchanged.
        public var record: SyncRecord
        /// Whether the merged record differs from the server's, so that this Mac must send it.
        public var needsSend: Bool
    }

    /// Merges `local` and `server` one unit at a time. A unit is a group of fields that only make sense together (`SyncRecordType.fieldGroups`), such as a pinned tab's place or a saved page, or else one field.
    /// - With `.mirror`, a unit changed on one side takes that side's values. A field that side removed stays removed. A unit changed on both sides to different values takes the values of the side that edited it later, or the server's on a tie. Both sides changing it to the same values is no conflict.
    /// - With `.firstWrite`, each side that has a value in a unit counts as changed, so the later edit wins, and a unit that only one side has survives.
    /// - With `.firstSync`, the server's values win every unit in which it has a value, and this Mac's values fill only the units the server lacks.
    /// - A field that this build does not know for the record type (`SyncRecordType.fields`) counts as unchanged on this Mac, which cannot edit it, so it keeps the server's value.
    ///
    /// A unit's edit time is the latest of its fields' times in `SyncRecord.fieldModifiedAt`, or the record's `modifiedAt` when none has one. Each unit keeps the edit times of the side whose values it takes. A merged record that must be sent takes the later `modifiedAt` of the two and the higher `schemaVersion`, since it can hold fields of the newer format.
    ///
    /// Two records that are not versions of one record, by name and type, do not merge: the result is the server's record, with nothing to send.
    public static func merge(local: SyncRecord, server: SyncRecord, base: Base) -> Result {
        guard local.recordName == server.recordName, local.recordType == server.recordType else { return Result(record: server, needsSend: false) }
        let recordType = server.recordType
        let knownFields = recordType.fields
        var fieldNames = Set(local.fields.keys).union(server.fields.keys).union(local.fieldModifiedAt.keys).union(server.fieldModifiedAt.keys)
        if case .mirror(let baseRecord) = base { fieldNames.formUnion(baseRecord.fields.keys) }
        let groups = recordType.fieldGroups.map { Set($0.map(\.rawValue)) }
        let groupedNames = groups.reduce(into: Set<String>()) { $0.formUnion($1) }
        let units = groups + fieldNames.subtracting(groupedNames).map { Set([$0]) }

        var fields: [String: SyncValue] = [:]
        var times: [String: Date] = [:]
        for unit in units {
            let isKnown = unit.allSatisfy { SyncField(rawValue: $0).map(knownFields.contains) ?? false }
            let localValues = local.fields.filter { unit.contains($0.key) }
            let serverValues = server.fields.filter { unit.contains($0.key) }
            let localChanged: Bool
            let serverChanged: Bool
            switch base {
            case .mirror(let baseRecord):
                let baseValues = baseRecord.fields.filter { unit.contains($0.key) }
                localChanged = isKnown && localValues != baseValues
                serverChanged = serverValues != baseValues
            case .firstWrite:
                // Nothing tells which side set the unit, so each side that has a value counts as changed, and a side without one yields to the other. This Mac's value of a field it does not know yields to the server's.
                localChanged = !localValues.isEmpty && (isKnown || serverValues.isEmpty)
                serverChanged = !serverValues.isEmpty
            case .firstSync:
                localChanged = !localValues.isEmpty && serverValues.isEmpty
                serverChanged = !serverValues.isEmpty
            }
            let takesLocal = if localChanged && serverChanged {
                localValues != serverValues && editTime(of: unit, in: local) > editTime(of: unit, in: server)
            } else {
                localChanged
            }
            let side = takesLocal ? local : server
            fields.merge(side.fields.filter { unit.contains($0.key) }) { $1 }
            times.merge(side.fieldModifiedAt.filter { unit.contains($0.key) }) { $1 }
        }

        guard fields != server.fields || times != server.fieldModifiedAt else { return Result(record: server, needsSend: false) }
        let record = SyncRecord(
            recordType: recordType,
            recordName: server.recordName,
            fields: fields,
            fieldModifiedAt: times,
            modifiedAt: max(local.modifiedAt, server.modifiedAt),
            schemaVersion: max(local.schemaVersion, server.schemaVersion)
        )
        return Result(record: record, needsSend: true)
    }

    /// The latest edit time among the unit's fields in `record`, or the record's `modifiedAt` when none of them has a time.
    private static func editTime(of unit: Set<String>, in record: SyncRecord) -> Date {
        unit.compactMap { record.fieldModifiedAt[$0] }.max() ?? record.modifiedAt
    }
}
