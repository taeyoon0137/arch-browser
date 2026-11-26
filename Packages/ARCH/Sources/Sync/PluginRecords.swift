// The plugin sync allowlist excludes package bytes, local paths, plugin storage, and secrets.
// Each Persona's manager provides only its non-secret settings.
import ARCHEngine
import Browsing
import CryptoKit
import Foundation
import Plugins

/// Maps installed and pending plugins to separate records in the existing sync zone.
public enum PluginRecords {
    /// Entry IDs are unique within a Persona, including both entries of an engine pair.
    /// Pairing a package later does not rename its record or delete the installed entry.
    public static func recordName(personaID: UUID, pluginID: String) -> String {
        let digest = SHA256.hash(data: Data(pluginID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "plugin.\(personaName(personaID)).\(digest)"
    }

    public enum InvalidItem: Error { case unsupported(String) }

    public static func records(from items: [PersonaPluginSyncItem], foundAt: Date) throws -> [SyncRecord] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json<T: Encodable>(_ value: T) throws -> SyncValue {
            .text(String(decoding: try encoder.encode(value), as: UTF8.self))
        }
        var seen = Set<String>()
        return try items.compactMap { scoped in
            let item = scoped.item
            guard item.isValid else { throw InvalidItem.unsupported(item.id) }
            let name = recordName(personaID: scoped.personaID, pluginID: item.id)
            guard seen.insert(name).inserted else { return nil }
            var record = SyncRecord(recordType: .plugin, recordName: name, fields: [
                "persona": .reference(personaName(scoped.personaID)), "pluginID": .text(item.id),
                "manifestID": .text(item.manifestID), "name": .text(item.name), "kind": .text(item.kind),
                "enabled": .text(item.isEnabled ? "true" : "false"),
                "settings": try json(item.settings), "grant": try json(item.grant)
            ], modifiedAt: foundAt)
            record[.source] = try item.source.map(json)
            record[.engine] = item.engine.map(SyncValue.text)
            record[.counterpartID] = item.counterpartID.map(SyncValue.text)
            record.fieldModifiedAt = Dictionary(uniqueKeysWithValues: record.fields.keys.map { ($0, foundAt) })
            return record
        }
    }

    /// Unknown kinds and engines wait in the mirror for a build that understands them.
    /// A mismatched record name never applies to another Persona or installed entry.
    public static func item(from record: SyncRecord) -> PersonaPluginSyncItem? {
        func text(_ field: SyncField) -> String? {
            if case .text(let value) = record[field] { value } else { nil }
        }
        func decoded<T: Decodable>(_ type: T.Type, _ field: SyncField) -> T? {
            text(field).flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
        }
        guard record.recordType == .plugin, case .reference(let owner) = record[.persona],
              let persona = owner == "default" ? Persona.defaultID : UUID(uuidString: owner),
              let id = text(.pluginID), !id.isEmpty,
              record.recordName == recordName(personaID: persona, pluginID: id),
              let manifestID = text(.manifestID), !manifestID.isEmpty, let name = text(.name),
              let kind = text(.kind), PluginKind(rawValue: kind) != nil,
              let enabled = text(.enabled), enabled == "true" || enabled == "false",
              let settings = decoded([String: PluginValue].self, .settings),
              let grant = decoded(PluginGrant.self, .grant),
              record[.engine] == nil || text(.engine).flatMap(EngineKind.init(rawValue:)) != nil,
              record[.counterpartID] == nil || text(.counterpartID) != nil else { return nil }
        let source = decoded(PluginSyncSource.self, .source)
        guard record[.source] == nil || source != nil else { return nil }
        let item = PluginSyncItem(id: id, manifestID: manifestID, name: name, kind: kind,
                                  source: source, isEnabled: enabled == "true", settings: settings,
                                  grant: grant, engine: text(.engine), counterpartID: text(.counterpartID))
        guard item.isValid else { return nil }
        return PersonaPluginSyncItem(personaID: persona, item: item)
    }

    private static func personaName(_ id: UUID) -> String {
        id == Persona.defaultID ? "default" : id.uuidString
    }
}
