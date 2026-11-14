// The file `sync.json`, beside `session.json` in the app's Application Support folder (`docs/sync.md`, Mapping the session store to records and Offline behavior). It keeps what sync needs between launches; `session.json` holds no sync fields. Sync writes it at every state update of the sync engine, and deleting it makes the next sync a first sync.
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

    public init(engineState: Data? = nil, records: [String: CKRecord] = [:], pendingSaves: [SyncRecord] = []) {
        self.engineState = engineState
        self.records = records
        self.pendingSaves = pendingSaves
    }

    /// Whether nothing is kept, as before the first sync.
    public var isEmpty: Bool {
        engineState == nil && records.isEmpty && pendingSaves.isEmpty
    }

    /// Reads the file at `url`. A missing file reads as empty, and so does one that does not decode, one from a newer format, or one whose records do not unarchive, since a partial mirror would disagree with the engine's change token.
    public static func read(from url: URL) -> SyncMirror {
        guard let data = try? Data(contentsOf: url), let file = try? decoder().decode(File.self, from: data), file.version == File.currentVersion,
              // An array of records unarchives only with the array class among the allowed classes; `unarchivedArrayOfObjects(ofClass:)` refuses the dictionaries inside a record.
              let records = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, CKRecord.self], from: file.records)) as? [CKRecord],
              let pendingSaves = try? file.pendingSaves.map({ try $0.record() }) else { return SyncMirror() }
        return SyncMirror(
            engineState: file.engineState,
            records: Dictionary(records.map { ($0.recordID.recordName, $0) }) { first, _ in first },
            pendingSaves: pendingSaves
        )
    }

    /// Writes the file at `url` atomically, so a crash leaves the previous file, and creates its folder when it is missing.
    public func write(to url: URL) throws {
        let sortedRecords = records.keys.sorted().compactMap { records[$0] }
        let file = File(
            version: File.currentVersion,
            engineState: engineState,
            records: try NSKeyedArchiver.archivedData(withRootObject: sortedRecords as NSArray, requiringSecureCoding: true),
            pendingSaves: pendingSaves.map(File.PendingSave.init)
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

    /// The file's format. Dates are seconds since 2001-01-01, and data is Base64 text.
    private struct File: Codable {
        static let currentVersion = 1

        var version: Int
        var engineState: Data?
        /// The mirror's records, sorted by record name, in one archive made with secure coding.
        var records: Data
        var pendingSaves: [PendingSave]

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
