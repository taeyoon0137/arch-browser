// The portion of a saved session that may be shared with another Mac (docs/sync.md, Outgoing changes).
import ARCHEngine
import Foundation

/// The sidebar records eligible for sharing with another Mac.
public struct SidebarSyncState: Equatable {
    /// A shareable pinned folder with its owning Persona and space.
    public struct Folder: Equatable, Identifiable {
        public let id: UUID
        public let personaID: UUID
        public let spaceID: UUID
        public let parentID: UUID?
        public let name: String

        public init(id: UUID, personaID: UUID, spaceID: UUID, parentID: UUID?, name: String) {
            self.id = id
            self.personaID = personaID
            self.spaceID = spaceID
            self.parentID = parentID
            self.name = name
        }
    }

    /// A pinned tab's saved identity and page for sidebar synchronization.
    public struct PinnedTab: Equatable, Identifiable {
        public let id: UUID
        public let personaID: UUID
        public let spaceID: UUID
        public let folderID: UUID?
        public let savedPage: SavedPage?
        public let customTitle: String?
        public let engine: EngineKind

        public init(id: UUID, personaID: UUID, spaceID: UUID, folderID: UUID?, savedPage: SavedPage?, customTitle: String?, engine: EngineKind) {
            self.id = id
            self.personaID = personaID
            self.spaceID = spaceID
            self.folderID = folderID
            self.savedPage = savedPage
            self.customTitle = customTitle
            self.engine = engine
        }
    }

    public let personas: [Persona]
    public let spaces: [Space]
    public let folders: [Folder]
    public let favorites: [Favorite]
    public let pinnedTabs: [PinnedTab]

    public init(personas: [Persona], spaces: [Space], folders: [Folder], favorites: [Favorite], pinnedTabs: [PinnedTab]) {
        self.personas = personas
        self.spaces = spaces
        self.folders = folders
        self.favorites = favorites
        self.pinnedTabs = pinnedTabs
    }

    /// Uses the captured session after migration or a successful save. A folder can only enter the
    /// result through its own space and a pinned ancestor at every level. A loaded session
    /// holds each ID once (`SessionSnapshot.normalized()`); an item that a snapshot lists twice still
    /// enters once, as its first copy (`docs/sync.md`, Mapping the session store to records).
    init(snapshot: SessionSnapshot, defaultEngine: EngineKind) {
        personas = Self.firstCopies(snapshot.personas ?? [])
        spaces = Self.firstCopies(snapshot.spaces)
        favorites = Self.firstCopies(snapshot.favorites)
        let owners = Dictionary(spaces.map { ($0.id, $0.resolvedPersonaID) }, uniquingKeysWith: { first, _ in first })
        let source = Self.firstCopies(snapshot.folders ?? [])
        let byParent = Dictionary(grouping: source, by: \.parentID)
        var allowed = Set<UUID>()
        var pending = byParent[nil] ?? []
        while let folder = pending.popLast() {
            guard folder.isPinned, !folder.isAgentFolder, owners[folder.spaceID] != nil, allowed.insert(folder.id).inserted else { continue }
            pending.append(contentsOf: (byParent[folder.id] ?? []).filter { $0.spaceID == folder.spaceID })
        }
        folders = source.compactMap { folder in
            guard allowed.contains(folder.id), let owner = owners[folder.spaceID] else { return nil }
            return Folder(id: folder.id, personaID: owner, spaceID: folder.spaceID, parentID: folder.parentID,
                          name: folder.name)
        }
        let folderSpaces = Dictionary(folders.map { ($0.id, $0.spaceID) }, uniquingKeysWith: { first, _ in first })
        pinnedTabs = Self.firstCopies(snapshot.tabs.compactMap { tab in
            guard tab.isPinned, let id = tab.id, let owner = owners[tab.spaceID],
                  tab.personaID == nil || tab.personaID == owner else { return nil }
            if let folder = tab.folderID, !allowed.contains(folder) || folderSpaces[folder] != tab.spaceID { return nil }
            return PinnedTab(id: id, personaID: owner, spaceID: tab.spaceID, folderID: tab.folderID,
                             savedPage: tab.savedPage, customTitle: tab.customTitle, engine: tab.pendingSyncEngine ?? tab.engine ?? defaultEngine)
        })
    }

    /// The state with each ID once in each list, as the first copy has it. Applying it never meets an ID twice, which a dictionary keyed by ID would trap on.
    public var withFirstCopies: SidebarSyncState {
        SidebarSyncState(personas: Self.firstCopies(personas), spaces: Self.firstCopies(spaces), folders: Self.firstCopies(folders),
                         favorites: Self.firstCopies(favorites), pinnedTabs: Self.firstCopies(pinnedTabs))
    }

    /// `items` without each item whose ID an earlier item has.
    static func firstCopies<Item: Identifiable>(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// Explicit incoming deletions, separated by type because local-only items outside the mirror survive.
public struct SidebarSyncDeletions {
    public var personas: Set<UUID> = []
    public var spaces: Set<UUID> = []
    public var folders: Set<UUID> = []
    public var favorites: Set<UUID> = []
    public var tabs: Set<UUID> = []

    public init() {}
}

/// Local IDs that adopt existing server IDs at the first sync. A space or folder moves its
/// local-only contents as well as its synced rows. Persona identities never change.
public struct SidebarSyncReplacements {
    public var spaces: [UUID: UUID] = [:]
    public var folders: [UUID: UUID] = [:]
    public var favorites: [UUID: UUID] = [:]
    public var tabs: [UUID: UUID] = [:]
    public init() {}
}
