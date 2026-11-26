// Converts the browser's syncable sidebar into records for the first sync and outgoing comparisons.
import Browsing
import Foundation

/// Projects a saved sidebar into ordered sync records for first sync and outgoing comparisons.
public enum SidebarRecords {
    /// Records stay in sidebar order within each sibling list. SyncDiff assigns the sparse keys
    /// against the mirror on later comparisons. No browser data outside this projection is read.
    public static func records(from state: SidebarSyncState, foundAt: Date) throws -> [SyncRecord] {
        var records: [SyncRecord] = []
        var orders: [SyncOrderKeys.SiblingList: Int] = [:]
        func append(_ type: SyncRecordType, _ name: String, _ fields: [String: SyncValue]) {
            var record = SyncRecord(recordType: type, recordName: name, fields: fields, modifiedAt: foundAt)
            if let list = SyncOrderKeys.SiblingList(of: record) {
                orders[list, default: 0] += 1
                record[.order] = .number(Double(orders[list, default: 0]))
            }
            for key in record.fields.keys { record.fieldModifiedAt[key] = foundAt }
            records.append(record)
        }

        for persona in state.personas { append(.persona, personaName(persona.id), ["name": .text(persona.name)]) }
        for space in state.spaces {
            var fields: [String: SyncValue] = ["persona": .reference(personaName(space.resolvedPersonaID)), "name": .text(space.name),
                                               "symbol": .text(space.symbol), "tint": .text(space.tint.rawValue)]
            fields["homeURL"] = space.homeURL.map { .text($0.absoluteString) }
            append(.space, space.id.uuidString, fields)
        }
        for folder in state.folders {
            var fields: [String: SyncValue] = ["persona": .reference(personaName(folder.personaID)),
                                               "space": .reference(folder.spaceID.uuidString), "name": .text(folder.name)]
            fields["parent"] = folder.parentID.map { .reference($0.uuidString) }
            fields["tint"] = folder.tint.map { .text($0.rawValue) }
            append(.folder, folder.id.uuidString, fields)
        }
        for favorite in state.favorites {
            append(.favorite, favorite.id.uuidString, ["persona": .reference(personaName(favorite.resolvedPersonaID)),
                                                      "url": .text(favorite.url.absoluteString), "title": .text(favorite.title)])
        }
        for tab in state.pinnedTabs {
            var fields: [String: SyncValue] = ["persona": .reference(personaName(tab.personaID)), "space": .reference(tab.spaceID.uuidString),
                                               "engine": .text(tab.engine.rawValue)]
            fields["folder"] = tab.folderID.map { .reference($0.uuidString) }
            fields["url"] = tab.savedPage.map { .text($0.url.absoluteString) }
            fields["title"] = tab.savedPage.map { .text($0.title) }
            fields["customTitle"] = tab.customTitle.map(SyncValue.text)
            append(.tab, tab.id.uuidString, fields)
        }
        for rule in state.siteRules where state.canSyncSiteRules {
            append(.siteRule, rule.id.uuidString, ["host": .text(rule.host), "pathPrefix": .text(rule.pathPrefix),
                "persona": .reference(personaName(rule.personaID)), "space": .reference(rule.spaceID.uuidString),
                "window": .text(rule.window.rawValue)])
        }
        return records
    }

    private static func personaName(_ id: UUID) -> String {
        id == Persona.defaultID ? "default" : id.uuidString
    }
}
