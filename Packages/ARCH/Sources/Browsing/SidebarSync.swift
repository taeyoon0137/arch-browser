// The portion of a saved session that may be shared with another Mac (docs/sync.md, Outgoing changes).
import ARCHEngine
import Foundation
import LiveFolders

public struct SidebarSyncState: Equatable {
    public struct Folder: Equatable {
        public let id: UUID
        public let personaID: UUID
        public let spaceID: UUID
        public let parentID: UUID?
        public let name: String
        public let live: LiveFolderConfiguration?
    }

    public struct PinnedTab: Equatable {
        public let id: UUID
        public let personaID: UUID
        public let spaceID: UUID
        public let folderID: UUID?
        public let savedPage: SavedPage?
        public let customTitle: String?
        public let engine: EngineKind
    }

    public let personas: [Persona]
    public let spaces: [Space]
    public let folders: [Folder]
    public let favorites: [Favorite]
    public let pinnedTabs: [PinnedTab]

    /// Uses the captured session after migration or a successful save. A folder can only enter the
    /// result through its own space and an ordinary pinned ancestor at every level.
    init(snapshot: SessionSnapshot, defaultEngine: EngineKind) {
        personas = snapshot.personas ?? []
        spaces = snapshot.spaces
        favorites = snapshot.favorites
        let owners = Dictionary(snapshot.spaces.map { ($0.id, $0.resolvedPersonaID) }, uniquingKeysWith: { first, _ in first })
        let source = snapshot.folders ?? []
        let byParent = Dictionary(grouping: source, by: \.parentID)
        var allowed = Set<UUID>()
        var ordinary = Set<UUID>()
        var pending = byParent[nil] ?? []
        while let folder = pending.popLast() {
            guard folder.isPinned, !folder.isAgentFolder, owners[folder.spaceID] != nil,
                  Self.canShare(folder.live), allowed.insert(folder.id).inserted else { continue }
            if folder.live == nil {
                ordinary.insert(folder.id)
                pending.append(contentsOf: (byParent[folder.id] ?? []).filter { $0.spaceID == folder.spaceID })
            }
        }
        folders = source.compactMap { folder in
            guard allowed.contains(folder.id), let owner = owners[folder.spaceID] else { return nil }
            return Folder(id: folder.id, personaID: owner, spaceID: folder.spaceID, parentID: folder.parentID,
                          name: folder.name, live: folder.live)
        }
        let folderSpaces = Dictionary(folders.map { ($0.id, $0.spaceID) }, uniquingKeysWith: { first, _ in first })
        pinnedTabs = snapshot.tabs.compactMap { tab in
            guard tab.isPinned, tab.liveItemID == nil, let id = tab.id, let owner = owners[tab.spaceID],
                  tab.personaID == nil || tab.personaID == owner else { return nil }
            if let folder = tab.folderID, !ordinary.contains(folder) || folderSpaces[folder] != tab.spaceID { return nil }
            return PinnedTab(id: id, personaID: owner, spaceID: tab.spaceID, folderID: tab.folderID,
                             savedPage: tab.savedPage, customTitle: tab.customTitle, engine: tab.engine ?? defaultEngine)
        }
    }

    private static func canShare(_ live: LiveFolderConfiguration?) -> Bool {
        guard case .feed(let address, let isPrivate) = live?.source else { return true }
        // Also exclude a legacy or malformed unmarked feed with credentials, a query, or a fragment.
        return !isPrivate && address.query == nil && address.fragment == nil && address.user == nil && address.password == nil
    }
}
