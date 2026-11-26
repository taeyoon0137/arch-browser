// Repairs the complete, field-merged sidebar graph once a fetch has finished successfully.
import ARCHEngine
import Browsing
import CryptoKit
import Foundation

/// Merges fetched sidebar records and repairs their graph before applying them locally.
public enum IncomingSidebarRecords {
    /// The sidebar to apply, local deletions, records to repair, and records to delete remotely.
    public struct Plan {
        public let sidebar: SidebarSyncState
        public let deletions: SidebarSyncDeletions
        public let repairs: [SyncRecord]
        public let recordsToDelete: [String]
    }

    /// A malformed record or identity found while rebuilding the sidebar graph.
    public enum InvalidGraph: Error {
        case malformedRecord(String)
        case inconsistentIdentity(String)
    }

    /// Merges a completed fetch against base records from the mirror. Absent fetched records
    /// carry no implication of deletion. An explicit tombstone takes precedence over a local save.
    /// A tab without an engine takes `defaultEngine`. A record name that one input lists twice
    /// counts once, as its first copy.
    public static func plan(local: [SyncRecord], fetched: [SyncRecord], mirror: [SyncRecord],
                            deleted: [String: SyncRecordType], foundAt: Date, defaultEngine: EngineKind) throws -> Plan {
        func byName(_ records: [SyncRecord]) -> [String: SyncRecord] {
            Dictionary(records.filter { $0.recordType.isSidebar }.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var combined = byName(local)
        let bases = byName(mirror)
        let fetchedByName = byName(fetched)
        let held = heldRecords(server: Array(bases.merging(fetchedByName) { _, fetched in fetched }.values), local: local, deleted: deleted)
        var sends: [String: SyncRecord] = [:]
        for (name, server) in fetchedByName where held[name] == nil {
            if let localRecord = combined[name] {
                let base = bases[name].flatMap { $0.recordType == server.recordType ? SyncMerge.Base.mirror($0) : nil } ?? .firstWrite
                let merge = SyncMerge.merge(local: localRecord, server: server, base: base)
                combined[name] = merge.record
                if merge.needsSend { sends[name] = merge.record }
            } else { combined[name] = server }
        }
        let plan = try plan(records: Array(combined.values), deleted: deleted, foundAt: foundAt, defaultEngine: defaultEngine, held: held)
        for name in deleted.keys { sends[name] = nil }
        for name in plan.recordsToDelete { sends[name] = nil }
        for row in plan.repairs { sends[row.recordName] = row }
        return Plan(sidebar: plan.sidebar, deletions: plan.deletions,
                    repairs: sends.values.sorted { $0.recordName < $1.recordName }, recordsToDelete: plan.recordsToDelete)
    }

    /// Inputs contain all sidebar records after field merging, including unsent local records. An
    /// explicit deletion always wins. Settings use SyncedSettings independently of this graph.
    /// A tab without an engine takes `defaultEngine`. A record name listed twice counts once, as its first copy.
    public static func plan(records: [SyncRecord], deleted: [String: SyncRecordType], foundAt: Date, defaultEngine: EngineKind) throws -> Plan {
        try plan(records: records, deleted: deleted, foundAt: foundAt, defaultEngine: defaultEngine, held: heldRecords(server: records, local: [], deleted: deleted))
    }

    /// The sidebar records that this build leaves alone, by name: a server record whose name or a field it needs this build cannot read, such as a tint or engine of a newer build, or a space's home address that is not http or https; a server record that would move `local`'s row of the same name to another Persona or type; a server Persona whose Personal space name (`personalSpaceID(for:)`) another record holds that is not one of its spaces; and every record under one of them, since the repairs would otherwise move it. The plans skip them, and the comparisons neither save nor delete them, so sync goes on without them and keeps what another build wrote.
    public static func heldOut(server: [SyncRecord], local: [SyncRecord], deleted: [String: SyncRecordType] = [:]) -> Set<String> {
        Set(heldRecords(server: server, local: local, deleted: deleted).keys)
    }

    /// Holds out unsupported or moved records and their descendants from the repair plan.
    private static func heldRecords(server: [SyncRecord], local: [SyncRecord], deleted: [String: SyncRecordType] = [:]) -> [String: SyncRecord] {
        let localByName = Dictionary(local.map { ($0.recordName, $0) }) { first, _ in first }
        var held: [String: SyncRecord] = [:]
        for item in server where item.recordType.isSidebar {
            let moved = localByName[item.recordName].map { $0.recordType != item.recordType || (item.recordType != .siteRule && $0[.persona] != item[.persona]) } ?? false
            if moved || !canApply(item) { held[item.recordName] = item }
        }
        // A Persona left without spaces gets a Personal space of a fixed name (`personalSpaceID(for:)`). Another record of that name, which no build writes, would fail every fetch's plan, so the Persona waits instead.
        let byName = Dictionary((server + local).map { ($0.recordName, $0) }) { first, _ in first }
        for item in server where item.recordType == .persona && held[item.recordName] == nil {
            guard let name = try? personalSpaceID(for: item).uuidString, let other = byName[name] else { continue }
            if other.recordType != .space || other[.persona] != .reference(item.recordName) { held[item.recordName] = item }
        }
        // A new rule waits for its destination records. A known local destination or an
        // explicit deletion distinguishes a deleted space, whose rule retains its reference.
        for item in server where item.recordType == .siteRule && held[item.recordName] == nil {
            guard case .reference(let persona) = item[.persona], case .reference(let space) = item[.space] else { continue }
            let known = localByName[item.recordName]
            let sameDestination = known?[.persona] == item[.persona] && known?[.space] == item[.space]
            if deleted[persona] == .persona { continue }
            let hasPersona = byName[persona]?.recordType == .persona
            let destination = byName[space]
            let hasSpace = destination?.recordType == .space && destination?[.persona] == item[.persona]
            if !hasPersona || (!hasSpace && !sameDestination && deleted[space] != .space) {
                held[item.recordName] = item
            } else if destination != nil && !hasSpace {
                held[item.recordName] = item
            }
        }
        var grew = !held.isEmpty
        while grew {
            grew = false
            for item in server + local where item.recordType.isSidebar && held[item.recordName] == nil {
                let parents = [SyncField.persona, .space, .parent, .folder].compactMap { field -> String? in
                    if case .reference(let name) = item[field] { name } else { nil }
                }
                if parents.contains(where: { held[$0] != nil }) {
                    held[item.recordName] = item
                    grew = true
                }
            }
        }
        return held
    }

    /// Whether `sidebar(personas:spaces:folders:all:defaultEngine:)` can turn the record into a sidebar item once the repairs have given it a space and parent.
    private static func canApply(_ item: SyncRecord) -> Bool {
        func text(_ field: SyncField) -> String? {
            if case .text(let text) = item[field] { text } else { nil }
        }
        func address(_ field: SyncField) -> URL? {
            text(field).flatMap { URL(string: $0, encodingInvalidCharacters: false) }.flatMap { $0.scheme == nil ? nil : $0 }
        }
        guard (try? identifier(item.recordName, type: item.recordType)) != nil else { return false }
        if item.recordType != .persona {
            guard case .reference(let owner) = item[.persona], (try? identifier(owner, type: .persona)) != nil else { return false }
        }
        switch item.recordType {
        case .persona:
            return text(.name) != nil
        case .space:
            guard text(.name) != nil, text(.symbol) != nil, text(.tint).flatMap(SpaceTint.init(rawValue:)) != nil else { return false }
            // A home page set here comes only from an http or https page.
            return item[.homeURL] == nil || address(.homeURL).flatMap { $0.scheme?.lowercased() }.map { $0 == "http" || $0 == "https" } == true
        case .folder:
            // An older build's live folder, whose `live` field this build does not read, applies as an ordinary folder, and a folder without `tint` has no color (`docs/sync.md`, Schema versions).
            return text(.name) != nil && (item[.tint] == nil || text(.tint).flatMap(SpaceTint.init(rawValue:)) != nil)
        case .favorite:
            return address(.url) != nil && text(.title) != nil
        case .tab:
            guard item[.engine] == nil || text(.engine).flatMap(EngineKind.init(rawValue:)) != nil else { return false }
            guard item[.url] == nil || (address(.url) != nil && text(.title) != nil) else { return false }
            return item[.customTitle] == nil || text(.customTitle) != nil
        case .siteRule:
            guard let host = text(.host), let prefix = text(.pathPrefix),
                  let site = try? SiteRuleSite(host: host, pathPrefix: prefix), site.host == host, site.pathPrefix == prefix,
                  text(.window).flatMap(SiteRule.Window.init(rawValue:)) != nil,
                  case .reference(let space) = item[.space], (try? identifier(space, type: .space)) != nil else { return false }
            return true
        case .setting, .remoteTabs:
            return true
        }
    }

    /// Repairs missing spaces, invalid parent links, cycles, and excessive folder depth, then builds the sidebar and tombstones.
    private static func plan(records: [SyncRecord], deleted: [String: SyncRecordType], foundAt: Date, defaultEngine: EngineKind, held: [String: SyncRecord]) throws -> Plan {
        var all: [String: SyncRecord] = [:]
        var removed = deleted.filter { $0.value.isSidebar }
        // The fixed default profile owns the platform's default storage and cannot be removed.
        removed.removeValue(forKey: "default")
        // A name listed twice counts by its first copy.
        var listed = Set<String>()
        for item in records where item.recordType.isSidebar && held[item.recordName] == nil && listed.insert(item.recordName).inserted {
            if let removal = removed[item.recordName] {
                if removal == item.recordType { continue }
                // A deletion of another type names some other record; it removes nothing here.
                removed.removeValue(forKey: item.recordName)
            }
            all[item.recordName] = item
        }
        let original = all
        let personas = SyncOrderKeys.sorted(all.values.filter { $0.recordType == .persona })
        let owners = Set(personas.map(\.recordName))
        for item in original.values where item.recordType != .persona {
            let owner = try reference(item, .persona)
            if !owners.contains(owner) {
                removed[item.recordName] = item.recordType
                all.removeValue(forKey: item.recordName)
            }
        }
        var spaces = Dictionary(grouping: SyncOrderKeys.sorted(all.values.filter { $0.recordType == .space }), by: { $0[.persona] })
        // A Persona whose spaces are held out still has them on the server.
        let heldSpaceOwners = Set(held.values.filter { $0.recordType == .space }.map { $0[.persona] })
        for persona in personas where spaces[.reference(persona.recordName)] == nil && !heldSpaceOwners.contains(.reference(persona.recordName)) {
            let name = try personalSpaceID(for: persona).uuidString
            guard all[name] == nil else { throw InvalidGraph.inconsistentIdentity(name) }
            // The same deterministic repair can be deleted remotely while its Persona survives.
            // Recreate it only if the Persona still has no other space.
            removed.removeValue(forKey: name)
            let item = SyncRecord(recordType: .space, recordName: name, fields: [
                "persona": .reference(persona.recordName), "name": .text(localized("Personal")), "order": .number(1),
                "symbol": .text("circle.fill"), "tint": .text("blue")], modifiedAt: foundAt)
            all[name] = item
            spaces[.reference(persona.recordName)] = [item]
        }

        for var item in all.values where item.recordType == .folder || item.recordType == .tab {
            let owner = item[.persona]
            let space = item[.space].flatMap { value -> SyncRecord? in
                guard case .reference(let id) = value else { return nil }
                return all[id]
            }
            if space?.recordType != .space || space?[.persona] != owner {
                guard let first = spaces[owner]?.first else {
                    // Its Persona's only spaces are held out, so it waits with them.
                    all.removeValue(forKey: item.recordName)
                    continue
                }
                item[.space] = .reference(first.recordName)
            }
            let key: SyncField = item.recordType == .folder ? .parent : .folder
            if let parent = item[key] {
                let folder: SyncRecord? = if case .reference(let id) = parent { all[id] } else { nil }
                if folder?.recordType != .folder || folder?[.persona] != owner { item[key] = nil }
            }
            all[item.recordName] = item
        }
        let folders = all.values.filter { $0.recordType == .folder }.map(\.recordName).sorted()
        // A folder has one parent. A walk either hits a resolved chain, a root, or a cycle.
        var finished = Set<String>()
        for id in folders where !finished.contains(id) {
            var path: [String] = []
            var positions: [String: Int] = [:]
            var current: String? = id
            while let name = current, !finished.contains(name) {
                if let pos = positions[name] {
                    if let first = path[pos...].min() { all[first]?[.parent] = nil }
                    break
                }
                positions[name] = path.count
                path.append(name)
                if case .reference(let parent) = all[name]?[.parent] { current = parent } else { current = nil }
            }
            finished.formUnion(path)
        }
        let sortedFolders = SyncOrderKeys.sorted(folders.compactMap { all[$0] })
        let children = Dictionary(grouping: sortedFolders, by: { $0[.parent] })
        var orderedFolders: [SyncRecord] = []
        // Keep the third-level ancestor for flattening everything below level four.
        var queue = (children[nil] ?? []).map { (item: $0, depth: 1, third: Optional<String>.none) }
        var index = 0
        while index < queue.count {
            let (item, depth, ancestor) = queue[index]
            index += 1
            var row = item
            if case .reference(let parent) = row[.parent] { row[.space] = all[parent]?[.space] }
            if depth > 4 { row[.parent] = ancestor.map(SyncValue.reference) }
            all[row.recordName] = row
            orderedFolders.append(row)
            let third = depth == 3 ? row.recordName : ancestor
            for child in children[.reference(row.recordName)] ?? [] { queue.append((child, depth + 1, third)) }
        }
        // Flattened siblings must be sorted together by their original keys.
        let repairedChildren = Dictionary(grouping: SyncOrderKeys.sorted(orderedFolders), by: { $0[.parent] })
        var parentFirst: [SyncRecord] = []
        func appendFolders(of parent: SyncValue?) {
            for folder in repairedChildren[parent] ?? [] {
                parentFirst.append(folder)
                appendFolders(of: .reference(folder.recordName))
            }
        }
        appendFolders(of: nil)
        for var tab in all.values where tab.recordType == .tab {
            if case .reference(let parent) = tab[.folder] { tab[.space] = all[parent]?[.space] }
            all[tab.recordName] = tab
        }

        var repairs: [SyncRecord] = []
        for var row in all.values.sorted(by: { $0.recordName < $1.recordName }) where original[row.recordName]?.fields != row.fields {
            let old = original[row.recordName]?.fields ?? [:]
            for field in Set(old.keys).union(row.fields.keys) where old[field] != row.fields[field] { row.fieldModifiedAt[field] = foundAt }
            row.modifiedAt = max(foundAt, row.modifiedAt)
            repairs.append(row)
        }
        let state = try sidebar(personas: personas, spaces: spaces, folders: parentFirst, all: all, defaultEngine: defaultEngine)
        var tombstones = SidebarSyncDeletions()
        for (name, type) in removed {
            guard let id = try? identifier(name, type: type) else { continue }
            switch type {
            case .persona: tombstones.personas.insert(id)
            case .space: tombstones.spaces.insert(id)
            case .folder: tombstones.folders.insert(id)
            case .favorite: tombstones.favorites.insert(id)
            case .tab: tombstones.tabs.insert(id)
            case .siteRule: tombstones.siteRules.insert(id)
            case .setting, .remoteTabs: break
            }
        }
        let repairDeletions = removed.keys.filter { deleted[$0] == nil }.sorted()
        return Plan(sidebar: state, deletions: tombstones, repairs: repairs, recordsToDelete: repairDeletions)
    }

    /// RFC 9562 UUIDv5 using the Persona UUID as the namespace and an invariant UTF-8 name.
    private static func personalSpaceID(for persona: SyncRecord) throws -> UUID {
        var namespace = try identifier(persona.recordName, type: .persona).uuid
        var bytes = withUnsafeBytes(of: &namespace) { Data($0) }
        bytes.append(contentsOf: "Arch Personal space".utf8)
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x50
        hash[8] = (hash[8] & 0x3f) | 0x80
        return hash.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    /// Validates a record name as a UUID, with the fixed default Persona as an exception.
    private static func identifier(_ raw: String, type: SyncRecordType) throws -> UUID {
        if type == .persona, raw == "default" { return Persona.defaultID }
        guard let id = UUID(uuidString: raw), raw == id.uuidString, type != .persona || id != Persona.defaultID else {
            throw InvalidGraph.malformedRecord(raw)
        }
        return id
    }

    private static func reference(_ item: SyncRecord, _ field: SyncField) throws -> String {
        guard case .reference(let name) = item[field] else { throw InvalidGraph.malformedRecord(item.recordName) }
        return name
    }

    /// Converts repaired records into the sidebar's Personas, spaces, folders, favorites, and pinned tabs.
    private static func sidebar(personas: [SyncRecord], spaces: [SyncValue?: [SyncRecord]], folders: [SyncRecord],
                                all: [String: SyncRecord], defaultEngine: EngineKind) throws -> SidebarSyncState {
        func text(_ item: SyncRecord, _ field: SyncField) throws -> String {
            guard case .text(let text) = item[field] else { throw InvalidGraph.malformedRecord(item.recordName) }
            return text
        }
        func url(_ item: SyncRecord, _ field: SyncField) throws -> URL {
            guard let url = URL(string: try text(item, field), encodingInvalidCharacters: false), url.scheme != nil else {
                throw InvalidGraph.malformedRecord(item.recordName)
            }
            return url
        }
        func owner(_ item: SyncRecord) throws -> UUID { try identifier(reference(item, .persona), type: .persona) }
        func optionalParent(_ item: SyncRecord, _ field: SyncField) throws -> UUID? {
            try item[field].map { _ in try identifier(reference(item, field), type: .folder) }
        }
        let people = try personas.map { try Persona(id: identifier($0.recordName, type: .persona), name: text($0, .name)) }
        let spaceRows = try personas.flatMap { persona in
            try (spaces[.reference(persona.recordName)] ?? []).map { item in
                guard let tint = try SpaceTint(rawValue: text(item, .tint)) else { throw InvalidGraph.malformedRecord(item.recordName) }
                var space = try Space(id: identifier(item.recordName, type: .space), name: text(item, .name),
                                      symbol: text(item, .symbol), tint: tint, personaID: owner(item))
                if item[.homeURL] != nil { space.homeURL = try url(item, .homeURL) }
                return space
            }
        }
        let folderRows = try folders.map { item in
            let tint = try item[.tint].map { _ in
                guard let tint = try SpaceTint(rawValue: text(item, .tint)) else { throw InvalidGraph.malformedRecord(item.recordName) }
                return tint
            }
            return try SidebarSyncState.Folder(id: identifier(item.recordName, type: .folder), personaID: owner(item),
                spaceID: identifier(reference(item, .space), type: .space), parentID: optionalParent(item, .parent),
                name: text(item, .name), tint: tint)
        }
        let favorites = try SyncOrderKeys.sorted(all.values.filter { $0.recordType == .favorite }).map { item in
            try Favorite(id: identifier(item.recordName, type: .favorite), url: url(item, .url), title: text(item, .title), personaID: owner(item))
        }
        let tabs = try SyncOrderKeys.sorted(all.values.filter { $0.recordType == .tab }).map { item in
            var engine = defaultEngine
            if item[.engine] != nil {
                guard let kind = try EngineKind(rawValue: text(item, .engine)) else { throw InvalidGraph.malformedRecord(item.recordName) }
                engine = kind
            }
            let saved = try item[.url].map { _ in try SavedPage(url: url(item, .url), title: text(item, .title)) }
            let custom = try item[.customTitle].map { _ in try text(item, .customTitle) }
            return try SidebarSyncState.PinnedTab(id: identifier(item.recordName, type: .tab), personaID: owner(item),
                spaceID: identifier(reference(item, .space), type: .space), folderID: optionalParent(item, .folder),
                savedPage: saved, customTitle: custom, engine: engine)
        }
        let siteRules = try all.values.filter { $0.recordType == .siteRule }.sorted { $0.recordName < $1.recordName }.map { item in
            guard let window = try SiteRule.Window(rawValue: text(item, .window)) else { throw InvalidGraph.malformedRecord(item.recordName) }
            return try SiteRule(id: identifier(item.recordName, type: .siteRule), host: text(item, .host), pathPrefix: text(item, .pathPrefix),
                spaceID: identifier(reference(item, .space), type: .space), personaID: owner(item), window: window, modifiedAt: item.modifiedAt)
        }
        return SidebarSyncState(personas: people, spaces: spaceRows, folders: folderRows, favorites: favorites, pinnedTabs: tabs, siteRules: siteRules)
    }
}
