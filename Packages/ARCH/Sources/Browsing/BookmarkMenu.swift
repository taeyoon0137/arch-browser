// The Bookmarks menu in the menu bar (bookmark rule 7, `docs/bookmarks.md`, Bookmarks menu): the favorites of the sidebar target's Persona, then every space's pinned folders and tabs, one submenu per space. `BookmarkMenu.entries(for:personas:spaces:favorites:tree:)` gives its contents as values without AppKit, which the app turns into menu items each time the menu opens; the session selects what the user chooses.
import AppKit

public enum BookmarkMenu {
    /// An item of the menu or of one of its submenus.
    public enum Entry: Equatable {
        /// The Persona's name above its favorites, with two or more Personas (Persona rule 7).
        case heading(String)
        /// A favorite, named by its title, or by its host when it has none, with its address for the tooltip.
        case favorite(id: UUID, title: String, url: URL)
        /// A pinned tab, named as its row names it, with its address for the tooltip.
        case tab(id: UUID, title: String, url: URL?)
        /// A space, titled with its label, or a folder, titled with its name, and what it holds.
        case submenu(title: String, entries: [Entry])
        case divider
        /// The disabled item of a menu without bookmarks.
        case noBookmarks
    }

    /// What choosing an entry selects.
    public enum Choice: Equatable {
        case favorite(UUID)
        case tab(UUID)
    }

    /// The menu for a window of `personaID`: the Persona's favorites in their order, headed by its name with two or more Personas; then, for each Persona in order, each of its spaces that has pinned tabs as a submenu titled with the space's label (Persona rule 7), its Personas' groups apart. A space's submenu holds its pinned folders as nested submenus, each listing its folders before its tabs as the sidebar does, then the pinned tabs outside folders. Folders and spaces whose pinned lists hold no tab at any depth are left out, since they offer nothing to choose. Without favorites and pinned tabs, the menu says so.
    static func entries(for personaID: Persona.ID, personas: [Persona], spaces: [Space], favorites: [Favorite], tree: FolderTree) -> [Entry] {
        var sections: [[Entry]] = []
        let personaFavorites = favorites.filter { $0.resolvedPersonaID == personaID }
        if !personaFavorites.isEmpty {
            let heading = BrowserSession.displayedName(ofPersona: personaID, among: personas).map { [Entry.heading($0)] } ?? []
            sections.append(heading + personaFavorites.map { .favorite(id: $0.id, title: $0.title.isEmpty ? $0.url.host ?? $0.url.absoluteString : $0.title, url: $0.url) })
        }
        for persona in personas {
            let submenus: [Entry] = spaces.filter { $0.resolvedPersonaID == persona.id }.compactMap { space in
                let contents = Self.entries(folders: tree.topFolders(in: space.id, pinned: true), tabs: tree.tabsOutsideFolders(in: space.id, pinned: true), tree: tree)
                return contents.isEmpty ? nil : .submenu(title: BrowserSession.label(ofSpace: space, among: personas), entries: contents)
            }
            if !submenus.isEmpty { sections.append(submenus) }
        }
        return sections.isEmpty ? [.noBookmarks] : Array(sections.joined(separator: [.divider]))
    }

    /// The folders that hold tabs at any depth, as submenus, then the tabs.
    private static func entries(folders: [TabFolder], tabs: [Tab], tree: FolderTree) -> [Entry] {
        let submenus: [Entry] = folders.compactMap { folder in
            let contents = Self.entries(folders: tree.subfolders(of: folder.id), tabs: tree.tabs(inFolder: folder.id), tree: tree)
            return contents.isEmpty ? nil : .submenu(title: folder.name, entries: contents)
        }
        return submenus + tabs.map { .tab(id: $0.id, title: $0.displayTitle, url: $0.url) }
    }
}

extension BrowserSession {
    /// The Bookmarks menu for the window that choosing an entry selects in, the sidebar target, read without opening one.
    public var bookmarkMenuEntries: [BookmarkMenu.Entry] {
        BookmarkMenu.entries(for: sidebarTargetPersonaID, personas: personas, spaces: spaces, favorites: favorites, tree: folderTree)
    }

    /// A Bookmarks menu entry: the sidebar target selects the pinned tab, or opens the favorite as a click on its tile does, and comes forward, also from behind a small window or Settings. Selecting the tab follows window rule 2, as a click on its row does, and takes the window to the tab's space, of any Persona. A tab or favorite that went away while the menu showed, or a favorite of another Persona than the window's, selects nothing.
    public func openBookmark(_ choice: BookmarkMenu.Choice) {
        let window: BrowserWindowModel
        switch choice {
        case .tab(let id):
            guard tabs.contains(where: { $0.id == id && $0.isListedInSidebar }) else { return }
            window = sidebarTarget()
            window.selectTab(id)
        case .favorite(let id):
            guard let favorite = favorites.first(where: { $0.id == id }) else { return }
            window = sidebarTarget()
            guard favorite.resolvedPersonaID == window.personaID else { return }
            window.openFavorite(favorite)
        }
        guard let nsWindow = window.nsWindow else { return }
        if nsWindow.isMiniaturized { nsWindow.deminiaturize(nil) }
        nsWindow.makeKeyAndOrderFront(nil)
    }
}
