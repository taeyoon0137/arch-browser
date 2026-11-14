// The browser import's way into the session: what one profile of another browser brings to the sidebar, the Persona it goes to, and the record of what earlier imports made, which `imports.json` keeps so that importing a profile again adds only what is not there yet. A `Plan` resolves a row against the session's sidebar without changing it, so tests check it without engines; `BrowserSession.addImport(_:to:record:)` applies it.
import Foundation

/// What one profile of another browser brings to the sidebar: favorites, and spaces with pinned tabs and folders. Import reads it from the browser's files, with web addresses only.
public struct SidebarImport {
    public var profile: Profile
    /// The profile's name in its browser, which a new Persona for it takes.
    public var profileName: String
    public var favorites: [Item]
    public var spaces: [SourceSpace]

    public init(profile: Profile, profileName: String, favorites: [Item], spaces: [SourceSpace]) {
        self.profile = profile
        self.profileName = profileName
        self.favorites = favorites
        self.spaces = spaces
    }

    /// A profile of another browser, as the record keys it.
    public struct Profile: Codable, Hashable {
        /// The browser's identifier.
        public var source: String
        /// The profile's folder, such as `Default`.
        public var folder: String

        public init(source: String, folder: String) {
            self.source = source
            self.folder = folder
        }
    }

    /// A bookmark or tab that becomes a favorite or a pinned tab.
    public struct Item: Equatable {
        /// The browser's ID for the item, which the record keys on, or nil when its file gives none.
        public var sourceID: String?
        public var url: URL
        public var title: String
        /// The name the user gave the tab, which the pinned tab keeps as its own name.
        public var customTitle: String?

        public init(sourceID: String?, url: URL, title: String, customTitle: String? = nil) {
            self.sourceID = sourceID
            self.url = url
            self.title = title
            self.customTitle = customTitle
        }
    }

    /// A folder that becomes a pinned folder. Browser import keeps folders one level deep, since its record and merging by name use the joined names as keys (bookmark rule 6), so the name is the source folder's path.
    public struct Folder: Equatable {
        public var sourceID: String?
        public var name: String
        public var items: [Item]

        public init(sourceID: String?, name: String, items: [Item]) {
            self.sourceID = sourceID
            self.name = name
            self.items = items
        }
    }

    /// A space of the browser, or the space that takes the profile's bookmark folders.
    public struct SourceSpace: Equatable {
        /// What the record keys the space on.
        public enum Origin: Hashable {
            /// One of the browser's spaces, by the browser's ID for it.
            case space(String)
            /// The space for the profile's bookmark folders, named after the browser. A row has at most one.
            case bookmarks
        }

        public var origin: Origin
        /// `nil` for a space the user did not name, which takes the next free "Space <n>" name, as new spaces do.
        public var name: String?
        /// `nil` for a space without a theme, which takes the next tint of the rotation, as new spaces do.
        public var tint: SpaceTint?
        /// The pinned tabs outside folders, in sidebar order.
        public var pinnedItems: [Item]
        public var folders: [Folder]

        public init(origin: Origin, name: String?, tint: SpaceTint?, pinnedItems: [Item], folders: [Folder]) {
            self.origin = origin
            self.name = name
            self.tint = tint
            self.pinnedItems = pinnedItems
            self.folders = folders
        }
    }

    /// The Persona a row goes to.
    public enum Destination: Hashable {
        case persona(Persona.ID)
        /// A new Persona named after the profile.
        case newPersona
    }

    /// What a row added.
    public struct Counts: Equatable {
        /// 1 when the row made its Persona.
        public var personas = 0
        /// The spaces made from the row's spaces. A new Persona's Personal space does not count.
        public var spaces = 0
        public var pinnedTabs = 0
        public var favorites = 0
        /// The row's favorites that the Persona has already.
        public var presentFavorites = 0
    }

    /// The destination a row's menu starts with, so that importing a profile again goes to the same Persona whichever window opens the sheet: the Persona the record names for the profile while it exists, else a Persona named like the profile, else the current Persona for the browser's first profile and a new Persona for any other.
    public func defaultDestination(record: Record, personas: [Persona], currentPersonaID: Persona.ID, isFirstProfile: Bool) -> Destination {
        if let id = record.entry(for: profile)?.personaID, personas.contains(where: { $0.id == id }) { return .persona(id) }
        if let persona = personas.first(where: { $0.name == profileName }) { return .persona(persona.id) }
        return isFirstProfile ? .persona(currentPersonaID) : .newPersona
    }
}

// MARK: Record

extension SidebarImport {
    /// What earlier imports made, kept in `imports.json` in the app's Application Support folder. Names and addresses alone cannot find an imported item again: a pinned tab's address follows its page, an untitled space gets a new "Space <n>" name each time, and a source item's address changes as the user goes on using the other browser. So the record keeps, for each source profile, the Persona it went to last and, for each Persona it went to, the Arch IDs of what it brought, by the source's IDs.
    public struct Record {
        private let fileURL: URL
        private(set) var entries: [Entry]
        /// Set while the record is empty in place of a file that did not decode. The first write moves that file aside.
        private var hasUnreadableFile = false

        /// Reads the record in `directory`, the session's folder (`BrowserSession.userDataDirectory`). A missing file, or one that does not decode, gives an empty record, so names and addresses decide, as on a first import. A file that does not decode stays as it is until the first write moves it to `imports.unreadable.json`, as an unreadable `site-search.json` is moved, so that the import never overwrites the IDs it holds.
        public init(directory: URL) {
            fileURL = directory.appendingPathComponent("imports.json")
            guard let data = try? Data(contentsOf: fileURL) else {
                entries = []
                return
            }
            let file = try? JSONDecoder().decode(File.self, from: data)
            entries = file?.profiles ?? []
            hasUnreadableFile = file == nil
        }

        /// Writes readable JSON, as the other stores do.
        public mutating func write() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(File(profiles: entries)) else { return }
            let directory = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if hasUnreadableFile {
                _ = try? FileManager.default.replaceItemAt(directory.appendingPathComponent("imports.unreadable.json"), withItemAt: fileURL)
                hasUnreadableFile = false
            }
            try? data.write(to: fileURL, options: .atomic)
        }

        func entry(for profile: Profile) -> Entry? {
            entries.first { $0.profile == profile }
        }

        /// Replaces the entry of the same profile, or adds `entry` at the end.
        mutating func update(_ entry: Entry) {
            if let index = entries.firstIndex(where: { $0.profile == entry.profile }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }

        /// Drops the IDs of items that are gone from their Personas and the Personas that are gone, then the entries left with neither their last Persona nor any IDs.
        mutating func removeGoneItems(in sidebar: Sidebar) {
            entries = entries.compactMap { entry in
                var entry = entry
                entry.personas = entry.personas.compactMap { items in
                    guard sidebar.personas.contains(where: { $0.id == items.personaID }) else { return nil }
                    let kept = items.keeping(sidebar.itemIDs(in: items.personaID))
                    return kept.isEmpty ? nil : kept
                }
                let hasPersona = sidebar.personas.contains { $0.id == entry.personaID }
                return hasPersona || !entry.personas.isEmpty ? entry : nil
            }
        }

        private struct File: Codable {
            var profiles: [Entry]
        }

        struct Entry: Codable, Equatable {
            var profile: Profile
            /// The Persona the profile went to last.
            var personaID: Persona.ID
            /// What the profile brought to each Persona it went to.
            var personas: [Items]

            /// What the profile brought to the Persona, empty when it never went there.
            func items(in personaID: Persona.ID) -> Items {
                personas.first { $0.personaID == personaID } ?? Items(personaID: personaID)
            }

            /// Replaces the IDs for the Persona of `items`.
            mutating func update(_ items: Items) {
                if let index = personas.firstIndex(where: { $0.personaID == items.personaID }) {
                    personas[index] = items
                } else {
                    personas.append(items)
                }
            }
        }

        /// The Arch IDs of what a profile brought to one Persona, by the source's IDs: spaces by the browser's space IDs, the bookmarks space on its own, pinned folders by folder IDs, and favorites and pinned tabs by item IDs. A space or folder that an imported one merged into counts as brought; a favorite or pinned tab skipped for its address does not.
        struct Items: Codable, Equatable {
            var personaID: Persona.ID
            var spaces: [String: UUID] = [:]
            var bookmarksSpace: UUID?
            var folders: [String: UUID] = [:]
            var favorites: [String: UUID] = [:]
            var pinnedTabs: [String: UUID] = [:]

            var isEmpty: Bool {
                spaces.isEmpty && bookmarksSpace == nil && folders.isEmpty && favorites.isEmpty && pinnedTabs.isEmpty
            }

            /// The IDs among `existing` only.
            func keeping(_ existing: Set<UUID>) -> Items {
                var items = self
                items.spaces = spaces.filter { existing.contains($0.value) }
                items.bookmarksSpace = bookmarksSpace.flatMap { existing.contains($0) ? $0 : nil }
                items.folders = folders.filter { existing.contains($0.value) }
                items.favorites = favorites.filter { existing.contains($0.value) }
                items.pinnedTabs = pinnedTabs.filter { existing.contains($0.value) }
                return items
            }
        }
    }
}

// MARK: Plan

extension SidebarImport {
    /// The session's sidebar as a plan resolves a row against it.
    struct Sidebar {
        var personas: [Persona]
        var spaces: [Space]
        var folders: [TabFolder]
        var favorites: [Favorite]
        var tabs: [TabState]

        /// A space's tab: pinned ones are found by their current address and their saved page's, and recorded ones by ID.
        struct TabState {
            var id: UUID
            var spaceID: UUID
            var isPinned: Bool
            var url: URL?
            /// A pinned tab's saved page, which stays its bookmark wherever its page went (bookmark rule 2).
            var savedURL: URL?
        }

        /// The IDs of the Persona's spaces, pinned folders, favorites, and tabs. A recorded item counts only while it is among them, so an item the user removed imports again.
        func itemIDs(in personaID: Persona.ID) -> Set<UUID> {
            let spaceIDs = Set(spaces.filter { $0.resolvedPersonaID == personaID }.map(\.id))
            return spaceIDs
                .union(folders.filter { $0.isPinned && spaceIDs.contains($0.spaceID) }.map(\.id))
                .union(favorites.filter { $0.resolvedPersonaID == personaID }.map(\.id))
                .union(tabs.filter { spaceIDs.contains($0.spaceID) }.map(\.id))
        }
    }

    /// What a row adds to the session: its Persona, and the spaces, folders, favorites, and pinned tabs that are not there yet, resolved against the sidebar and the row's record entry without changing either.
    ///
    /// A recorded item counts while it is in the Persona, wherever the user moved it, and keeps out the source item it came from. Without a recorded item, names and addresses decide: a space merges into one of the Persona's with its name, a folder into a pinned folder of the space with its name, and favorites and pinned tabs come once per address in the Persona's favorites or in the space's pinned tabs, inside or outside folders, where a pinned tab's saved page counts as well as its current address.
    struct Plan {
        /// The Persona to add, for a new destination or for one deleted since the user picked it.
        let newPersona: Persona?
        let personaID: Persona.ID
        /// The spaces to add, in order, last in the Persona's group. As with folders, a space is made only when a pinned tab or folder goes into it. A new Persona left without spaces gets one named Personal, as New Persona does, so that every Persona has a space.
        let spaces: [Space]
        /// The pinned folders to add after the folders already there. A folder with nothing left to add is not made.
        let folders: [TabFolder]
        let favorites: [Favorite]
        /// The pinned tabs to open, in sidebar order within each space and folder.
        let pinnedTabs: [PinnedTab]
        let counts: Counts
        /// The row's entry with the Persona as the last one used and the IDs of what the row brought to it.
        let entry: Record.Entry

        /// A pinned tab to open, saved at its imported address and title (bookmark rule 2).
        struct PinnedTab: Equatable {
            let id: UUID
            let url: URL
            let title: String
            let customTitle: String?
            let spaceID: UUID
            let folderID: UUID?
        }

        init(_ row: SidebarImport, to destination: Destination, entry: Record.Entry?, in sidebar: Sidebar) {
            // A Persona deleted while the sheet was open gives way to a new one named after the profile.
            if case .persona(let id) = destination, sidebar.personas.contains(where: { $0.id == id }) {
                newPersona = nil
                personaID = id
            } else {
                let persona = Persona(name: row.profileName)
                newPersona = persona
                personaID = persona.id
            }
            var builder = Builder(personaID: personaID, recorded: entry?.items(in: personaID), in: sidebar)
            builder.addFavorites(row.favorites)
            row.spaces.forEach { builder.add($0) }
            if newPersona != nil, builder.spaces.isEmpty { builder.addPersonalSpace() }
            spaces = builder.spaces
            folders = builder.folders
            favorites = builder.favorites
            pinnedTabs = builder.pinnedTabs
            var counts = builder.counts
            counts.personas = newPersona == nil ? 0 : 1
            self.counts = counts
            var updated = entry ?? Record.Entry(profile: row.profile, personaID: personaID, personas: [])
            updated.personaID = personaID
            updated.update(builder.made)
            self.entry = updated
        }

        /// What a plan has decided so far, and the sidebar it resolves the next items against.
        private struct Builder {
            let personaID: Persona.ID
            /// What the profile brought to the Persona, without the recorded items that are gone, and with what the plan adds.
            private(set) var made: Record.Items
            private(set) var spaces: [Space] = []
            private(set) var folders: [TabFolder] = []
            private(set) var favorites: [Favorite] = []
            private(set) var pinnedTabs: [PinnedTab] = []
            private(set) var counts = Counts()
            /// Every space, for the next "Space <n>" name and tint.
            private var allSpaces: [Space]
            /// The Persona's spaces and pinned folders, which imported ones merge into.
            private var personaSpaces: [Space]
            private var pinnedFolders: [TabFolder]
            private var favoriteAddresses: Set<URL>
            /// The addresses pinned in each space, inside or outside folders: each pinned tab's current address and saved page.
            private var pinnedAddresses: [UUID: Set<URL>] = [:]

            init(personaID: Persona.ID, recorded: Record.Items?, in sidebar: Sidebar) {
                self.personaID = personaID
                made = (recorded ?? Record.Items(personaID: personaID)).keeping(sidebar.itemIDs(in: personaID))
                allSpaces = sidebar.spaces
                let personaSpaces = sidebar.spaces.filter { $0.resolvedPersonaID == personaID }
                self.personaSpaces = personaSpaces
                pinnedFolders = sidebar.folders.filter { folder in folder.isPinned && personaSpaces.contains { $0.id == folder.spaceID } }
                favoriteAddresses = Set(sidebar.favorites.filter { $0.resolvedPersonaID == personaID }.map(\.url))
                for tab in sidebar.tabs where tab.isPinned {
                    pinnedAddresses[tab.spaceID, default: []].formUnion([tab.url, tab.savedURL].compactMap { $0 })
                }
            }

            mutating func addFavorites(_ items: [Item]) {
                for item in items {
                    guard item.sourceID.flatMap({ made.favorites[$0] }) == nil, favoriteAddresses.insert(item.url).inserted else {
                        counts.presentFavorites += 1
                        continue
                    }
                    let favorite = Favorite(url: item.url, title: item.title, personaID: personaID)
                    favorites.append(favorite)
                    counts.favorites += 1
                    if let id = item.sourceID { made.favorites[id] = favorite.id }
                }
            }

            /// Adds the space's pinned tabs and folders to its recorded space, or else to one of the Persona's with its name, or else to a new space. Like a folder, a new space is made only once a pinned tab or folder goes into it, so that a space with nothing left to add does not come back empty after the user deleted it and its tabs and folders moved to another space.
            mutating func add(_ source: SourceSpace) {
                let recordedID: UUID?
                switch source.origin {
                case .space(let id): recordedID = made.spaces[id]
                case .bookmarks: recordedID = made.bookmarksSpace
                }
                let space = personaSpaces.first { $0.id == recordedID } ?? source.name.flatMap { name in personaSpaces.first { $0.name == name } } ?? newSpace(for: source)
                let items = itemsToPin(source.pinnedItems, in: space.id)
                if !items.isEmpty { make(space) }
                pin(items, in: space.id, folderID: nil)
                source.folders.forEach { add($0, to: space) }
                guard personaSpaces.contains(where: { $0.id == space.id }) else { return }
                switch source.origin {
                case .space(let id): made.spaces[id] = space.id
                case .bookmarks: made.bookmarksSpace = space.id
                }
            }

            mutating func addPersonalSpace() {
                append(Space(name: BrowserSession.newPersonaSpaceName, tint: BrowserSession.newSpaceTint(among: allSpaces), personaID: personaID))
            }

            /// A new space of the Persona for the source space, named and tinted as new spaces are when the source gives no name or tint. It joins the plan once `make(_:)` adds it.
            private func newSpace(for source: SourceSpace) -> Space {
                Space(name: source.name ?? BrowserSession.newSpaceName(among: allSpaces), tint: source.tint ?? BrowserSession.newSpaceTint(among: allSpaces), personaID: personaID)
            }

            /// Adds a new space from `newSpace(for:)` to the plan the first time something goes into it. A space of the Persona, including one added before, stays as it is.
            private mutating func make(_ space: Space) {
                guard !personaSpaces.contains(where: { $0.id == space.id }) else { return }
                append(space)
                counts.spaces += 1
            }

            private mutating func append(_ space: Space) {
                allSpaces.append(space)
                personaSpaces.append(space)
                spaces.append(space)
            }

            /// Pins the folder's items in its recorded folder, wherever in the Persona the user moved it, or else in a pinned folder of the space with its name, or else in a new one when any are left to add, making the space for it if need be.
            private mutating func add(_ source: Folder, to space: Space) {
                let recordedID = source.sourceID.flatMap { made.folders[$0] }
                var folder = pinnedFolders.first { $0.id == recordedID } ?? pinnedFolders.first { $0.spaceID == space.id && $0.name == source.name }
                let items = itemsToPin(source.items, in: folder?.spaceID ?? space.id)
                if folder == nil, !items.isEmpty {
                    make(space)
                    let created = TabFolder(spaceID: space.id, name: source.name, isPinned: true)
                    pinnedFolders.append(created)
                    folders.append(created)
                    folder = created
                }
                guard let folder else { return }
                if let id = source.sourceID { made.folders[id] = folder.id }
                pin(items, in: folder.spaceID, folderID: folder.id)
            }

            /// The items that are neither recorded nor pinned in the space already, nor earlier in the row.
            private mutating func itemsToPin(_ items: [Item], in spaceID: UUID) -> [Item] {
                var kept: [Item] = []
                for item in items {
                    guard item.sourceID.flatMap({ made.pinnedTabs[$0] }) == nil, pinnedAddresses[spaceID, default: []].insert(item.url).inserted else { continue }
                    kept.append(item)
                }
                return kept
            }

            private mutating func pin(_ items: [Item], in spaceID: UUID, folderID: UUID?) {
                for item in items {
                    let tab = PinnedTab(id: UUID(), url: item.url, title: item.title, customTitle: item.customTitle, spaceID: spaceID, folderID: folderID)
                    pinnedTabs.append(tab)
                    counts.pinnedTabs += 1
                    if let id = item.sourceID { made.pinnedTabs[id] = tab.id }
                }
            }
        }
    }
}

extension SidebarImport.Sidebar.TabState {
    /// A space's tab as the plan sees it, with its current address and, for a pinned tab, its saved page's. Nil for a favorite's tab, which belongs to no space.
    init?(_ tab: Tab) {
        guard let spaceID = tab.spaceID else { return nil }
        self.init(id: tab.id, spaceID: spaceID, isPinned: tab.isPinned, url: tab.url, savedURL: tab.savedPage?.url)
    }
}
