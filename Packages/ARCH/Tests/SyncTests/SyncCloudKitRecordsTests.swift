// Sync's records as CloudKit records in the zone `ArchSync1` and back (docs/sync.md, Record types). The test process has no iCloud entitlements, and it creates `CKRecord` values and their encrypted values without reaching CloudKit's servers.
import CloudKit
import Foundation
import Testing
@testable import Sync

@Suite struct SyncCloudKitRecordsTests {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static let referenceFields: Set<SyncField> = [.persona, .space, .folder, .parent]

    /// A record of `type` with a value in every field this build knows, each field edited at its own time, a fractional one included, and the time of a field the record has lost.
    private func fullRecord(_ type: SyncRecordType) -> SyncRecord {
        var fields: [String: SyncValue] = [:]
        var times: [String: Date] = [:]
        for (index, field) in type.fields.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            fields[field.rawValue] = switch field {
            case _ where Self.referenceFields.contains(field): .reference("\(field.rawValue)-1")
            case .order: .number(2.5)
            default: .text("\(field.rawValue) of \(type.rawValue)")
            }
            times[field.rawValue] = date(100 + Double(index) + 0.123456789)
        }
        times["removedField"] = date(50)
        return SyncRecord(recordType: type, recordName: "\(type.rawValue)-record", fields: fields, fieldModifiedAt: times, modifiedAt: date(200.987654321))
    }

    /// The keys whose values are plain, not encrypted. `allKeys()` lists the encrypted keys too, and a plain read of one returns nil.
    private func plainKeys(of record: CKRecord) -> Set<String> {
        Set(record.allKeys().filter { record[$0] != nil })
    }

    @Test func roundTripsEachRecordTypeWithItsFieldEditTimes() throws {
        for type in SyncRecordType.allCases {
            let record = fullRecord(type)
            let ckRecord = SyncCloudKitRecords.ckRecord(from: record)
            #expect(ckRecord.recordType == type.rawValue)
            #expect(ckRecord.recordID.recordName == record.recordName)
            #expect(ckRecord.recordID.zoneID.zoneName == "ArchSync1")
            #expect(ckRecord.recordID.zoneID.ownerName == CKCurrentUserDefaultName)
            let back = try #require(SyncCloudKitRecords.syncRecord(from: ckRecord))
            #expect(back == record, "\(type)")
        }
    }

    @Test func keepsEveryEncryptedFieldOutOfTheRecordsPlainKeys() throws {
        for type in SyncRecordType.allCases {
            let ckRecord = SyncCloudKitRecords.ckRecord(from: fullRecord(type))
            let references = type.fields.intersection(Self.referenceFields).map(\.rawValue)
            var plain = Set(references).union(["modifiedAt", "schemaVersion"])
            if type.fields.contains(.order) { plain.insert("order") }
            let encrypted = Set(type.fields.map(\.rawValue)).subtracting(plain).union(["fieldModifiedAt"])
            #expect(plainKeys(of: ckRecord) == plain, "\(type)")
            #expect(Set(ckRecord.encryptedValues.allKeys()) == encrypted, "\(type)")
            for key in encrypted {
                #expect(ckRecord[key] == nil, "\(type).\(key)")
            }
            for key in references {
                let reference = try #require(ckRecord[key] as? CKRecord.Reference)
                #expect(reference.action == .none)
                #expect(reference.recordID.zoneID == SyncCloudKitRecords.zoneID)
                #expect(reference.recordID.recordName == "\(key)-1")
            }
        }
        // A setting's value, such as the appearance, is encrypted like a name.
        let setting = SyncCloudKitRecords.ckRecord(from: SyncRecord(recordType: .setting, recordName: "ARCHAppearance", fields: ["value": .text("dark")], modifiedAt: date(1)))
        #expect(plainKeys(of: setting) == ["modifiedAt", "schemaVersion"])
        #expect(setting.encryptedValues["value"] as? String == "dark")
    }

    @Test func outgoingRecordKeepsFieldsThisBuildDoesNotKnow() throws {
        // The mirror's copy, written by a newer build: an encrypted text field and a plain date field that this build does not know, with their edit times.
        let mirrorRecord = SyncRecord(
            recordType: .folder, recordName: "folder-1",
            fields: ["persona": .reference("default"), "space": .reference("space-1"), "parent": .reference("folder-0"), "name": .text("News"), "order": .number(1)],
            fieldModifiedAt: ["name": date(10), "futureField": date(11), "reviewedAt": date(12)],
            modifiedAt: date(12), schemaVersion: 2
        )
        let mirror = SyncCloudKitRecords.ckRecord(from: mirrorRecord)
        mirror.encryptedValues["futureField"] = "https://feeds.example/rss"
        mirror["reviewedAt"] = date(12)

        // The mirror's copy reads with the text field; the date field has no `SyncValue`.
        let read = try #require(SyncCloudKitRecords.syncRecord(from: mirror))
        #expect(read.fields["futureField"] == .text("https://feeds.example/rss"))
        #expect(read.fields["reviewedAt"] == nil)
        #expect(read.schemaVersion == 2)

        // This Mac renames the folder and moves it to the top of its space's pinned list.
        var save = read
        save[.name] = .text("Reading")
        save[.parent] = nil
        save.fields["futureField"] = .text("changed here, which this build cannot do")
        save.fieldModifiedAt = ["name": date(30), "parent": date(30), "space": date(30), "order": date(30)]
        save.modifiedAt = date(30)
        let outgoing = SyncCloudKitRecords.ckRecord(from: save, base: mirror)

        #expect(outgoing !== mirror)
        #expect(outgoing.recordID == mirror.recordID)
        #expect(outgoing.encryptedValues["futureField"] as? String == "https://feeds.example/rss")
        #expect(outgoing["reviewedAt"] as? Date == date(12))
        #expect(outgoing.encryptedValues["name"] as? String == "Reading")
        #expect(outgoing["parent"] == nil)
        let sent = try #require(SyncCloudKitRecords.syncRecord(from: outgoing))
        #expect(sent.fieldModifiedAt == ["name": date(30), "parent": date(30), "space": date(30), "order": date(30), "futureField": date(11), "reviewedAt": date(12)])
        #expect(sent.modifiedAt == date(30))

        // The mirror's copy is left as it was.
        #expect(mirror.encryptedValues["name"] as? String == "News")
        #expect((mirror["parent"] as? CKRecord.Reference)?.recordID.recordName == "folder-0")
    }

    @Test func movesAFieldBetweenPlainAndEncryptedValuesWithoutAnException() throws {
        // CloudKit raises an exception for a write to one store while the other holds the key, so the conversion clears the old place first.
        let base = CKRecord(recordType: "Space", recordID: SyncCloudKitRecords.recordID(named: "space-1"))
        base["name"] = "Plain name"
        base.encryptedValues["order"] = "1"
        let record = SyncRecord(recordType: .space, recordName: "space-1", fields: ["name": .text("Work"), "order": .number(1)], modifiedAt: date(1))
        let outgoing = SyncCloudKitRecords.ckRecord(from: record, base: base)
        #expect(plainKeys(of: outgoing) == ["order", "modifiedAt", "schemaVersion"])
        #expect(outgoing.encryptedValues["name"] as? String == "Work")
        #expect(SyncCloudKitRecords.syncRecord(from: outgoing)?.fields == record.fields)
    }

    @Test func tellsRecordsOfTheZoneFromThoseOfOtherZones() {
        #expect(SyncCloudKitRecords.isInZone(SyncCloudKitRecords.recordID(named: "space-1")))
        #expect(SyncCloudKitRecords.isInZone(SyncCloudKitRecords.ckRecord(from: fullRecord(.space)).recordID))
        // A later build's zone, the default zone, and a zone of the same name with another owner.
        #expect(!SyncCloudKitRecords.isInZone(CKRecord.ID(recordName: "space-1", zoneID: CKRecordZone.ID(zoneName: "ArchSync2", ownerName: CKCurrentUserDefaultName))))
        #expect(!SyncCloudKitRecords.isInZone(CKRecord.ID(recordName: "space-1")))
        #expect(!SyncCloudKitRecords.isInZone(CKRecord.ID(recordName: "space-1", zoneID: CKRecordZone.ID(zoneName: "ArchSync1", ownerName: "_another-owner"))))
    }

    @Test func readsNoRecordOfATypeThisBuildDoesNotKnow() {
        let theme = CKRecord(recordType: "Theme", recordID: SyncCloudKitRecords.recordID(named: "theme-1"))
        theme.encryptedValues["name"] = "Dusk"
        #expect(SyncCloudKitRecords.syncRecord(from: theme) == nil)
    }

    @Test func readsARecordWithoutMetadataAsVersionOneWithoutEditTimes() throws {
        let bare = CKRecord(recordType: "Persona", recordID: SyncCloudKitRecords.recordID(named: "default"))
        bare.encryptedValues["name"] = "Personal"
        bare.encryptedValues["fieldModifiedAt"] = "not JSON"
        let record = try #require(SyncCloudKitRecords.syncRecord(from: bare))
        #expect(record.fields == ["name": .text("Personal")])
        #expect(record.fieldModifiedAt.isEmpty)
        #expect(record.modifiedAt == .distantPast)
        #expect(record.schemaVersion == 1)
    }
}
