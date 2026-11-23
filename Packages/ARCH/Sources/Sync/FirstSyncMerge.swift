// First sync on a Mac (docs/sync.md, decision 4). The caller supplies complete, syncable records
// and the browser's saved-page comparison. Planning neither changes the sidebar nor opens a database.
import Foundation

/// Plans the first sync by matching local sidebar records with server records before applying either side.
public enum FirstSyncMerge {
    /// A local item takes the identity of an existing server item. A space or folder moves all of its
    /// contents, including local-only items. A tab or favorite transfers its selection or open tab.
    public struct Replacement: Equatable, Sendable {
        public let type: SyncRecordType
        public let localName: String
        public let serverName: String
    }

    /// The records to apply and upload, and the local identities to replace with server identities.
    public struct Plan: Equatable, Sendable {
        /// Every fetched record, including any fields a same-ID local copy filled in.
        public let recordsToApply: [String: SyncRecord]
        /// Spaces before their folders, parents before children, and tabs after folders.
        public let replacements: [Replacement]
        /// Unmatched local items and same-ID merges with new values, in local sidebar order. An unmatched item in a list the server also fills goes after the server's items.
        public let recordsToUpload: [SyncRecord]
    }

    /// A conflict between record types assigned the same name by local and server data.
    public enum InvalidRecords: Error, Equatable {
        case conflictingTypes(String)
    }

    /// A record name that either input lists twice counts once, as its first copy, so the plan never names an item twice. A name that the two inputs give to records of different types fails the plan.
    public static func plan(local: [SyncRecord], server: [SyncRecord], samePage: (URL, URL) -> Bool) throws -> Plan {
        var serverByName: [String: SyncRecord] = [:]
        let server = server.filter { record in
            guard serverByName[record.recordName] == nil else { return false }
            serverByName[record.recordName] = record
            return true
        }
        var localNames = Set<String>()
        let local = local.filter { localNames.insert($0.recordName).inserted }
        for record in local {
            if let other = serverByName[record.recordName], other.recordType != record.recordType {
                throw InvalidRecords.conflictingTypes(record.recordName)
            }
        }

        // Exact IDs, including the default Persona and settings, always have first claim.
        let available = SyncOrderKeys.sorted(server.filter { !localNames.contains($0.recordName) })
        let candidates = Dictionary(grouping: available, by: matchKey)
        var claimed = Set<String>()
        var aliases: [String: String] = [:]
        var replacements: [Replacement] = []
        func match(_ record: SyncRecord) {
            guard serverByName[record.recordName] == nil,
                  let key = matchKey(remap(record, using: aliases)), let bucket = candidates[key] else { return }
            let savedPage = address(of: record)
            guard let other = bucket.first(where: { candidate in
                guard !claimed.contains(candidate.recordName) else { return false }
                guard record.recordType == .tab else { return true }
                guard let savedPage, let remotePage = address(of: candidate) else { return false }
                return samePage(savedPage, remotePage)
            }) else { return }
            claimed.insert(other.recordName)
            aliases[record.recordName] = other.recordName
            replacements.append(Replacement(type: record.recordType, localName: record.recordName, serverName: other.recordName))
        }

        let ordered = SyncOrderKeys.sorted(local)
        for space in ordered where space.recordType == .space { match(space) }
        // Walk the local hierarchy top-down. A cycle or a missing parent cannot match by folder name.
        let folders = ordered.filter { $0.recordType == .folder }
        let children = Dictionary(grouping: folders, by: { $0[.parent] })
        var level = children[nil] ?? []
        while !level.isEmpty {
            var next: [SyncRecord] = []
            for folder in level {
                match(folder)
                next.append(contentsOf: children[.reference(folder.recordName)] ?? [])
            }
            level = next
        }
        for record in ordered where record.recordType == .favorite || record.recordType == .tab { match(record) }

        var apply = serverByName
        var upload: [SyncRecord] = []
        // Local keys number each list from 1, so a new item would sort among the server's; it takes the next keys after them instead, in local order.
        var nextKeys: [SyncOrderKeys.SiblingList: Double] = [:]
        for record in server {
            guard let list = SyncOrderKeys.SiblingList(of: record), let key = SyncOrderKeys.key(of: record) else { continue }
            nextKeys[list] = max(nextKeys[list] ?? key, key)
        }
        for original in local where aliases[original.recordName] == nil {
            var record = remap(original, using: aliases)
            if let existing = serverByName[record.recordName] {
                let merge = SyncMerge.merge(local: record, server: existing, base: .firstSync)
                apply[record.recordName] = merge.record
                if merge.needsSend { upload.append(merge.record) }
            } else {
                if let list = SyncOrderKeys.SiblingList(of: record), let last = nextKeys[list] {
                    nextKeys[list] = last + 1
                    record[.order] = .number(last + 1)
                }
                upload.append(record)
            }
        }
        return Plan(recordsToApply: apply, replacements: replacements, recordsToUpload: upload)
    }

    /// The hierarchy and values used to match an unshared local record to a server record.
    private enum MatchKey: Hashable {
        case space(persona: String, name: String)
        case folder(persona: String, space: String, parent: SyncValue?, name: String)
        case favorite(persona: String, address: String)
        case tab(persona: String, space: String, folder: SyncValue?)
    }

    /// Builds a matching key for a space, folder, favorite, or tab with valid parent fields.
    private static func matchKey(_ record: SyncRecord) -> MatchKey? {
        guard case .reference(let persona) = record[.persona] else { return nil }
        switch record.recordType {
        case .space:
            guard case .text(let name) = record[.name] else { return nil }
            return .space(persona: persona, name: name)
        case .folder:
            guard case .reference(let space) = record[.space], case .text(let name) = record[.name],
                  isOptionalReference(record[.parent]) else { return nil }
            return .folder(persona: persona, space: space, parent: record[.parent], name: name)
        case .favorite:
            guard case .text(let url) = record[.url], address(of: record) != nil else { return nil }
            return .favorite(persona: persona, address: url)
        case .tab:
            guard case .reference(let space) = record[.space], isOptionalReference(record[.folder]) else { return nil }
            return .tab(persona: persona, space: space, folder: record[.folder])
        case .persona, .setting:
            return nil
        }
    }

    private static func isOptionalReference(_ value: SyncValue?) -> Bool {
        switch value {
        case nil, .reference: true
        default: false
        }
    }

    private static func address(of record: SyncRecord) -> URL? {
        guard case .text(let text) = record[.url], let url = URL(string: text, encodingInvalidCharacters: false),
              url.scheme != nil else { return nil }
        return url
    }

    /// Replaces local space, parent, and folder references with claimed server identities.
    private static func remap(_ original: SyncRecord, using aliases: [String: String]) -> SyncRecord {
        var record = original
        for field: SyncField in [.space, .parent, .folder] {
            if case .reference(let local) = record[field], let server = aliases[local] { record[field] = .reference(server) }
        }
        return record
    }
}
