// The records that sync keeps in the user's iCloud zone, as plain values without CloudKit types (`docs/sync.md`, Record types). The CloudKit conversion turns them into `CKRecord` values and back; the merge, the comparison with the mirror, and the session mapping work on these values alone.
import Foundation

/// The kind of a record, named as its CloudKit record type.
public enum SyncRecordType: String, CaseIterable, Hashable, Sendable {
    case persona = "Persona"
    case space = "Space"
    case folder = "Folder"
    case favorite = "Favorite"
    case tab = "Tab"
    case setting = "Setting"

    /// The fields this build reads and writes for the type. Any other field in a record came from a newer build, and this build keeps it unchanged (`docs/sync.md`, Schema versions).
    public var fields: Set<SyncField> {
        switch self {
        case .persona: [.name, .order]
        case .space: [.persona, .name, .symbol, .tint, .homeURL, .order]
        case .folder: [.persona, .space, .parent, .name, .live, .order]
        case .favorite: [.persona, .url, .title, .order]
        case .tab: [.persona, .space, .folder, .url, .title, .customTitle, .engine, .order]
        case .setting: [.value]
        }
    }

    /// Fields that only make sense together, so the merge treats each group as one unit (`docs/sync.md`, Conflicts; sync decision 3): a pinned tab's or folder's place, and a saved page. Every other field is a unit of its own.
    public var fieldGroups: [Set<SyncField>] {
        switch self {
        case .folder: [[.space, .parent, .order]]
        case .favorite: [[.url, .title]]
        case .tab: [[.space, .folder, .order], [.url, .title]]
        case .persona, .space, .setting: []
        }
    }
}

/// A field name that this build uses. Records key their fields by the raw name, so a field from a newer build, which has no case here, stays in `SyncRecord.fields` too.
public enum SyncField: String, CaseIterable, Hashable, Sendable {
    case persona
    case space
    case folder
    case parent
    case name
    case symbol
    case tint
    case homeURL
    case url
    case title
    case customTitle
    case engine
    case order
    case value
    case live
}

/// A field's value.
public enum SyncValue: Hashable, Sendable {
    /// A name, title, address, raw value, or setting value.
    case text(String)
    /// An `order` sort key.
    case number(Double)
    /// Another record of the zone, by its record name, such as a tab's space.
    case reference(String)
}

/// One record of the zone. Its record name is unique within the zone whatever its type. A field that the record lacks has no value, such as `folder` on a tab outside folders.
public struct SyncRecord: Hashable, Sendable {
    /// The record format that this build writes (`docs/sync.md`, Schema versions).
    public static let currentSchemaVersion = 2

    public var recordType: SyncRecordType
    public var recordName: String
    /// Every field the record has, by raw field name, including fields this build does not know.
    public var fields: [String: SyncValue]
    /// When a Mac found each field's latest edit, by raw field name, including fields the record has lost and fields this build does not know. A field keeps its time until its value changes. Conflicts compare these times (sync decision 3).
    public var fieldModifiedAt: [String: Date]
    /// When the Mac that wrote the record found its latest edit. A merge unit whose fields have no time in `fieldModifiedAt` counts as edited then.
    public var modifiedAt: Date
    /// The record format version of the build that wrote the record.
    public var schemaVersion: Int

    public init(recordType: SyncRecordType, recordName: String, fields: [String: SyncValue] = [:], fieldModifiedAt: [String: Date] = [:], modifiedAt: Date, schemaVersion: Int = SyncRecord.currentSchemaVersion) {
        self.recordType = recordType
        self.recordName = recordName
        self.fields = fields
        self.fieldModifiedAt = fieldModifiedAt
        self.modifiedAt = modifiedAt
        self.schemaVersion = schemaVersion
    }

    /// A field this build knows. Setting nil removes the field.
    public subscript(field: SyncField) -> SyncValue? {
        get { fields[field.rawValue] }
        set { fields[field.rawValue] = newValue }
    }
}
