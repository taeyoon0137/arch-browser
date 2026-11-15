// The file `sync.json`, beside `session.json` in the app's Application Support folder (`docs/sync.md`, Mapping the session store to records and Offline behavior). It keeps what sync needs between launches, for one CloudKit database (`SyncDatabase`); `session.json` holds the local sidebar and its recovery marker. Sync writes it at every state update of the sync engine, once `session.json` holds every change applied from the mirror it writes, and deleting it makes the next sync a first sync.
import CloudKit
import Foundation

/// What sync keeps between launches: the sync engine's state, the mirror of the server's records, and the pending saves. An empty value, which a missing or unreadable file reads as, makes the next sync a first sync.
public struct SyncMirror: Sendable {
    /// The file's name in the app's Application Support folder.
    public static let fileName = "sync.json"

    /// The sync engine's state serialization, as the engine encoded it. It holds the zone's change token and the record names of the pending changes. Nil before the first sync.
    public var engineState: Data?
    /// The mirror: each synced item's last known server record, by record name. Each keeps its system fields, which hold its change tag, and every field, including records of types and fields of types that this build does not know (`docs/sync.md`, Schema versions).
    public var records: [String: CKRecord]
    /// Every save not sent yet, as the last comparison of its scope returned it (`SyncDiff`), with its field values and edit times. The engine's state keeps only the record names, and the next comparison needs the values to tell whether a field still holds the value it found.
    public var pendingSaves: [SyncRecord]
    /// The mirror's records that the session does not hold because this build could not apply them: those it held out (`IncomingSidebarRecords.heldOut(server:local:)`) and those of types it does not know. The next launch applies them as if fetched, so a later build that can shows them rather than taking them for items deleted here.
    public var unapplied: Set<String>

    public init(engineState: Data? = nil, records: [String: CKRecord] = [:], pendingSaves: [SyncRecord] = [], unapplied: Set<String> = []) {
        self.engineState = engineState
        self.records = records
        self.pendingSaves = pendingSaves
        self.unapplied = unapplied
    }

    /// Whether nothing is kept, as before the first sync.
    public var isEmpty: Bool {
        engineState == nil && records.isEmpty && pendingSaves.isEmpty
    }

    /// Reads the file at `url` for `database`. A missing file reads as empty. A file from a newer format reads as empty and first leaves a copy, `sync-v<version>.json`. One that does not decode or whose records do not unarchive reads as empty, since a partial mirror would disagree with the engine's change token, and moves to `sync.unreadable.json`. One written for another database, such as a build for the other CloudKit environment or another container, reads as empty and moves to `sync.other-database.json`, since its change token and change tags belong to that database and its mirror would keep this Mac's items from uploading. Each copy, like those `SessionStore` makes of `session.json`, keeps the file from the next write and replaces an older copy. A pending save this build cannot read, of a record type or with a kind of value that only a newer build writes, is skipped and the rest reads: its record keeps its mirror copy, so the next comparison that covers its type finds the change again. Records of other zones are skipped (`SyncCloudKitRecords.isInZone(_:)`).
    public static func read(from url: URL, database: SyncDatabase) -> SyncMirror {
        guard let data = try? Data(contentsOf: url) else { return SyncMirror() }
        let folder = url.deletingLastPathComponent()
        if let version = try? JSONDecoder().decode(SavedVersion.self, from: data).version, version > File.currentVersion {
            try? data.write(to: folder.appendingPathComponent("sync-v\(version).json"), options: .atomic)
            return SyncMirror()
        }
        guard let file = try? decoder().decode(File.self, from: data), file.version == File.currentVersion else {
            return moveAside(url, as: "sync.unreadable.json")
        }
        guard file.database == database.digest else { return moveAside(url, as: "sync.other-database.json") }
        // An array of records unarchives only with the array class among the allowed classes; `unarchivedArrayOfObjects(ofClass:)` refuses the dictionaries inside a record.
        guard let records = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, CKRecord.self], from: file.records)) as? [CKRecord] else {
            return moveAside(url, as: "sync.unreadable.json")
        }
        return SyncMirror(
            engineState: file.engineState,
            records: Dictionary(records.filter { SyncCloudKitRecords.isInZone($0.recordID) }.map { ($0.recordID.recordName, $0) }) { first, _ in first },
            pendingSaves: file.pendingSaves.compactMap { try? $0.record() },
            unapplied: Set(file.unapplied ?? [])
        )
    }

    /// Moves the file at `url` to `name` in its folder, replacing an older copy, and gives an empty value.
    private static func moveAside(_ url: URL, as name: String) -> SyncMirror {
        _ = try? FileManager.default.replaceItemAt(url.deletingLastPathComponent().appendingPathComponent(name), withItemAt: url)
        return SyncMirror()
    }

    /// Writes the file at `url` for `database` atomically, so a crash leaves the previous file, and creates its folder when it is missing. The file names the database only by its digest.
    public func write(to url: URL, database: SyncDatabase) throws {
        let sortedRecords = records.keys.sorted().compactMap { records[$0] }
        let file = File(
            version: File.currentVersion,
            database: database.digest,
            engineState: engineState,
            records: try NSKeyedArchiver.archivedData(withRootObject: sortedRecords as NSArray, requiringSecureCoding: true),
            pendingSaves: pendingSaves.map(File.PendingSave.init),
            unapplied: unapplied.isEmpty ? nil : unapplied.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.nonConformingFloatEncodingStrategy = Self.nonConformingFloats
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// A number that is infinite or not a number, such as an unusable order key from a fetched record (`SyncOrderKeys.key(of:)`), is written as text, since JSON has no such numbers.
    private static let nonConformingFloats = JSONEncoder.NonConformingFloatEncodingStrategy.convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// The version a file was written with, read on its own so that a newer file is copied even when the rest does not decode.
    private struct SavedVersion: Decodable {
        var version: Int?
    }

    /// The file's format. Dates are seconds since 2001-01-01, and data is Base64 text.
    private struct File: Codable {
        static let currentVersion = 1

        var version: Int
        /// The digest of the database that the engine's state and the mirror belong to (`SyncDatabase.digest`).
        var database: String
        var engineState: Data?
        /// The mirror's records, sorted by record name, in one archive made with secure coding.
        var records: Data
        /// The pending saves. Reading skips one that does not decode, such as one with a kind of value that only a newer build writes, so the rest of the file still reads.
        var pendingSaves: [PendingSave]
        /// The unapplied record names, sorted, or nil for none. Files before it have none.
        var unapplied: [String]?

        init(version: Int, database: String, engineState: Data?, records: Data, pendingSaves: [PendingSave], unapplied: [String]?) {
            self.version = version
            self.database = database
            self.engineState = engineState
            self.records = records
            self.pendingSaves = pendingSaves
            self.unapplied = unapplied
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            database = try container.decode(String.self, forKey: .database)
            engineState = try container.decodeIfPresent(Data.self, forKey: .engineState)
            records = try container.decode(Data.self, forKey: .records)
            pendingSaves = try container.decode([Readable].self, forKey: .pendingSaves).compactMap(\.save)
            unapplied = try container.decodeIfPresent([String].self, forKey: .unapplied)
        }

        private enum CodingKeys: String, CodingKey {
            case version, database, engineState, records, pendingSaves, unapplied
        }

        /// One pending save as read, or nil when it does not decode. Decoding never fails, so the list goes on to the next save.
        private struct Readable: Decodable {
            var save: PendingSave?

            init(from decoder: Decoder) throws {
                save = try? PendingSave(from: decoder)
            }
        }

        /// A pending save with every field, edit time, and version that `SyncRecord` holds.
        struct PendingSave: Codable {
            var recordType: String
            var recordName: String
            var fields: [String: Value]
            var fieldModifiedAt: [String: Date]
            var modifiedAt: Date
            var schemaVersion: Int

            init(_ record: SyncRecord) {
                recordType = record.recordType.rawValue
                recordName = record.recordName
                fields = record.fields.mapValues(Value.init)
                fieldModifiedAt = record.fieldModifiedAt
                modifiedAt = record.modifiedAt
                schemaVersion = record.schemaVersion
            }

            func record() throws -> SyncRecord {
                guard let type = SyncRecordType(rawValue: recordType) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown record type \(recordType)"))
                }
                return SyncRecord(recordType: type, recordName: recordName, fields: fields.mapValues(\.value), fieldModifiedAt: fieldModifiedAt, modifiedAt: modifiedAt, schemaVersion: schemaVersion)
            }
        }

        /// A field value as an object with one key that names its kind: `{"text": "Work"}`, `{"number": 1.5}`, or `{"reference": "default"}`.
        struct Value: Codable {
            var value: SyncValue

            private enum CodingKeys: String, CodingKey {
                case text, number, reference
            }

            init(_ value: SyncValue) {
                self.value = value
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try container.decodeIfPresent(String.self, forKey: .text) {
                    value = .text(text)
                } else if let number = try container.decodeIfPresent(Double.self, forKey: .number) {
                    value = .number(number)
                } else if let name = try container.decodeIfPresent(String.self, forKey: .reference) {
                    value = .reference(name)
                } else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A value needs text, number, or reference"))
                }
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch value {
                case .text(let text): try container.encode(text, forKey: .text)
                case .number(let number): try container.encode(number, forKey: .number)
                case .reference(let name): try container.encode(name, forKey: .reference)
                }
            }
        }
    }
}
