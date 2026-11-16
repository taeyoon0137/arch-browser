// The conversion between sync's records and CloudKit records in the zone `ArchSync1` (`docs/sync.md`, Container, database, and zone, and Record types). Names, addresses, titles, and every other text value go in `encryptedValues`, which CloudKit encrypts end to end; references, order keys, `modifiedAt`, and `schemaVersion` stay plain because CloudKit cannot encrypt references and the rest names nothing.
import CloudKit
import Foundation

/// Turns a `SyncRecord` into the `CKRecord` to send and a fetched or mirrored `CKRecord` back into a `SyncRecord`.
public enum SyncCloudKitRecords {
    /// The custom zone in the private database that holds every record. Its number is the major schema version (`docs/sync.md`, Schema versions).
    public static let zoneID = CKRecordZone.ID(zoneName: "ArchSync1", ownerName: CKCurrentUserDefaultName)

    /// The keys of a record's metadata, which no `SyncField` uses.
    enum MetadataKey {
        /// Plain: when the Mac that wrote the record found its latest edit, as a date.
        static let modifiedAt = "modifiedAt"
        /// Plain: the record format version, as an integer.
        static let schemaVersion = "schemaVersion"
        /// Encrypted: each field's edit time, as JSON text of an object from raw field name to seconds since 2001-01-01.
        static let fieldModifiedAt = "fieldModifiedAt"

        static let all: Set<String> = [modifiedAt, schemaVersion, fieldModifiedAt]
    }

    /// The ID of the record named `recordName` in the zone.
    public static func recordID(named recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    /// Whether `recordID` names a record of the zone. The sync engine can fetch every zone of the database, and a later build's zone, such as `ArchSync2`, holds records whose values mean something else, under the same record names (`docs/sync.md`, Container, database, and zone, and Schema versions). Sync converts, mirrors, and applies only records and deletions of this zone and drops the others. This is apart from `syncRecord(from:)`'s nil for a record type this build does not know, whose records the mirror keeps.
    public static func isInZone(_ recordID: CKRecord.ID) -> Bool {
        recordID.zoneID == zoneID
    }

    /// The record to send for `record`.
    ///
    /// With `base`, the mirror's copy of the record or the server's record of a refused save, the result starts from a copy of it, so it keeps the system fields that hold the change tag, and the fields this build does not know for the record type keep the base's values and edit times, whatever their CloudKit type (`docs/sync.md`, Schema versions). The fields this build knows, and their edit times, come from `record`; a known field that `record` lacks is removed. Without `base`, every field of `record` is written. `base` itself is left unchanged.
    ///
    /// Each value is placed by its kind: text in `encryptedValues`, and numbers and references as plain values. A reference points to a record of the zone and has no delete action, because the Mac that deletes a parent also deletes or moves its children in the same batch. A metadata key that the base holds in the other kind of values, as another writer could leave it, moves too, since CloudKit raises an exception for a write to one kind while the other holds the key.
    ///
    /// A base that is not a copy of the same record in the zone, by name and type, is not used.
    public static func ckRecord(from record: SyncRecord, base: CKRecord? = nil) -> CKRecord {
        let base = base.flatMap { isInZone($0.recordID) && $0.recordID.recordName == record.recordName && $0.recordType == record.recordType.rawValue ? $0 : nil }
        let ckRecord = (base?.copy() as? CKRecord) ?? CKRecord(recordType: record.recordType.rawValue, recordID: recordID(named: record.recordName))
        let knownFields = Set(record.recordType.fields.map(\.rawValue))
        let writtenFields = base == nil ? knownFields.union(record.fields.keys) : knownFields
        for field in writtenFields {
            remove(field, from: ckRecord)
            switch record.fields[field] {
            case .text(let text): ckRecord.encryptedValues[field] = text
            case .number(let number): ckRecord[field] = number
            case .reference(let name): ckRecord[field] = CKRecord.Reference(recordID: recordID(named: name), action: .none)
            case nil: break
            }
        }

        // Edit times follow the values: the known fields' times come from `record`, and the base's other fields keep theirs.
        var times = record.fieldModifiedAt
        if let base {
            times = fieldModifiedAt(of: base).filter { !knownFields.contains($0.key) }.merging(times.filter { knownFields.contains($0.key) }) { $1 }
        }
        for key in MetadataKey.all { remove(key, from: ckRecord) }
        ckRecord.encryptedValues[MetadataKey.fieldModifiedAt] = fieldModifiedAtText(times)
        ckRecord[MetadataKey.modifiedAt] = record.modifiedAt
        ckRecord[MetadataKey.schemaVersion] = record.schemaVersion
        return ckRecord
    }

    /// The `SyncRecord` that `ckRecord` holds, or nil for a record type this build does not know, which the mirror keeps as it came. `ckRecord` is a record of the zone; Sync drops records of other zones before this (`isInZone(_:)`).
    ///
    /// Fields come from both the plain and the encrypted values: text as `.text`, numbers as `.number`, and references as `.reference` with the referenced record's name. A field of any other CloudKit type, which only a newer build writes, is left out here; an outgoing record built on the mirror's copy keeps it (`ckRecord(from:base:)`). A record without `modifiedAt` counts as modified at the server's modification date, and one without `schemaVersion` as version 1.
    public static func syncRecord(from ckRecord: CKRecord) -> SyncRecord? {
        guard let recordType = SyncRecordType(rawValue: ckRecord.recordType) else { return nil }
        var fields: [String: SyncValue] = [:]
        let keys = Set(ckRecord.allKeys()).union(ckRecord.encryptedValues.allKeys()).subtracting(MetadataKey.all)
        for key in keys {
            // A plain read of an encrypted key returns nil, and the other way around.
            let value = ckRecord[key] ?? ckRecord.encryptedValues[key]
            if let reference = value as? CKRecord.Reference {
                fields[key] = .reference(reference.recordID.recordName)
            } else if let text = value as? String {
                fields[key] = .text(text)
            } else if let number = value as? NSNumber {
                fields[key] = .number(number.doubleValue)
            }
        }
        return SyncRecord(
            recordType: recordType,
            recordName: ckRecord.recordID.recordName,
            fields: fields,
            fieldModifiedAt: fieldModifiedAt(of: ckRecord),
            modifiedAt: (ckRecord[MetadataKey.modifiedAt] as? Date) ?? ckRecord.modificationDate ?? .distantPast,
            schemaVersion: (ckRecord[MetadataKey.schemaVersion] as? NSNumber)?.intValue ?? 1
        )
    }

    /// Removes `key` from whichever of the record's plain and encrypted values holds it. CloudKit raises an exception for any write to one of them, even of nil, while the other holds the key, so each is cleared only when it has the key.
    private static func remove(_ key: String, from record: CKRecord) {
        if record[key] != nil { record[key] = nil }
        if record.encryptedValues[key] != nil { record.encryptedValues[key] = nil }
    }

    /// The edit times in the record's `fieldModifiedAt` text, or none when it has no such text or the text does not decode.
    private static func fieldModifiedAt(of record: CKRecord) -> [String: Date] {
        guard let text = record.encryptedValues[MetadataKey.fieldModifiedAt] as? String,
              let seconds = try? JSONDecoder().decode([String: Double].self, from: Data(text.utf8)) else { return [:] }
        return seconds.mapValues(Date.init(timeIntervalSinceReferenceDate:))
    }

    /// The JSON text of `times`, with sorted keys so that the same times give the same text. JSON cannot hold an infinite time, so such a time is left out.
    private static func fieldModifiedAtText(_ times: [String: Date]) -> String {
        let seconds = times.mapValues(\.timeIntervalSinceReferenceDate).filter { $0.value.isFinite }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(seconds)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
