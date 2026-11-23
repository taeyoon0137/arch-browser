// The Bookmarks menu (`docs/bookmarks.md`, Bookmarks menu; bookmark rule 7): the window's Persona's favorites, then each space's pinned folders and tabs as one submenu per space, with spaces titled "Persona / Space" and the favorites headed by the Persona's name once there are two Personas (Persona rule 7), and live folders with their unread counts and unread items. Tabs run on `PageStub`, without a session or an engine, so the menu bar and choosing an entry are regression check 71.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct BookmarkMenuTests {
    private let defaultPersona = Persona(id: Persona.defaultID, name: "Default")
    private let work = Persona(name: "Work")

    /// A folder at the top of the space's pinned list, of its open list without `pinned`, or inside `parent`.
    private func folder(_ name: String, in space: Space, parent: TabFolder? = nil, pinned: Bool = true) -> TabFolder {
        var folder = TabFolder(spaceID: space.id, name: name, isPinned: parent?.isPinned ?? pinned)
        folder.parentID = parent?.id
        return folder
    }

    /// A tab of the space in `folder`, or outside folders in the pinned or open list, named `name`.
    private func tab(_ name: String, in space: Space, folder: TabFolder? = nil, pinned: Bool = true) -> Tab {
        let page = PageStub(engine: .webKit, url: URL(string: "https://example.org/\(name)"))
        let tab = Tab(id: UUID(), webContents: page, spaceID: space.id, isPinned: folder?.isPinned ?? pinned, personaID: space.resolvedPersonaID)
        tab.folderID = folder?.id
        tab.customTitle = name
        return tab
    }

    private func favorite(_ title: String, of persona: Persona) -> Favorite {
        Favorite(url: URL(string: "https://\(title.lowercased()).example")!, title: title, personaID: persona.id)
    }

    /// Each entry on a line, after two spaces for each submenu that holds it: a heading after "# ", a favorite after "* ", a submenu with " >" after its title.
    private func outline(_ entries: [BookmarkMenu.Entry], depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        return entries.flatMap { entry -> [String] in
            switch entry {
            case .heading(let title): return [indent + "# " + title]
            case .favorite(_, let title, _): return [indent + "* " + title]
            case .tab(_, let title, _): return [indent + title]
            case .submenu(let title, let entries): return [indent + title + " >"] + outline(entries, depth: depth + 1)
            case .divider: return [indent + "---"]
            case .noBookmarks: return [indent + "No Bookmarks"]
            }
        }
    }

    // MARK: One Persona

    @Test func withOnePersonaTheMenuListsFavoritesThenEachSpaceByItsName() {
        let personal = Space(name: "Personal", personaID: Persona.defaultID)
        let research = Space(name: "Research", personaID: Persona.defaultID)
        let tabs = [tab("Mail", in: personal), tab("Papers", in: research)]
        let entries = BookmarkMenu.entries(for: Persona.defaultID, personas: [defaultPersona], spaces: [personal, research],
                                           favorites: [favorite("Calendar", of: defaultPersona), favorite("Music", of: defaultPersona)], tree: FolderTree(folders: [], tabs: tabs))
        // No heading names the only Persona.
        #expect(outline(entries) == ["* Calendar", "* Music", "---", "Personal >", "  Mail", "Research >", "  Papers"])
    }

    @Test func spacesWithoutPinnedTabsAreLeftOut() {
        let personal = Space(name: "Personal", personaID: Persona.defaultID)
        let openOnly = Space(name: "Open Only", personaID: Persona.defaultID)
        let emptyFolders = Space(name: "Empty Folders", personaID: Persona.defaultID)
        let outer = folder("Outer", in: emptyFolders)
        let inner = folder("Inner", in: emptyFolders, parent: outer)
        let openFolder = folder("Open Folder", in: openOnly, pinned: false)
        let tabs = [tab("Mail", in: personal), tab("Article", in: openOnly, pinned: false), tab("Draft", in: openOnly, folder: openFolder)]
        let entries = BookmarkMenu.entries(for: Persona.defaultID, personas: [defaultPersona], spaces: [personal, openOnly, emptyFolders],
                                           favorites: [], tree: FolderTree(folders: [openFolder, outer, inner], tabs: tabs))
        // A space whose open tabs alone hold tabs, and one whose pinned folders hold none at any depth, offer nothing to choose.
        #expect(outline(entries) == ["Personal >", "  Mail"])
    }

    @Test func nestedFoldersListTheirFoldersBeforeTheirTabsAtEveryLevel() {
        let space = Space(name: "Personal", personaID: Persona.defaultID)
        let projects = folder("Projects", in: space)
        let docs = folder("Docs", in: space, parent: projects)
        let specs = folder("Specs", in: space, parent: docs)
        let empty = folder("Empty", in: space, parent: projects)
        let reading = folder("Reading", in: space)
        let open = folder("Open", in: space, pinned: false)
        let tabs = [
            tab("Loose", in: space), tab("Board", in: space, folder: projects), tab("Spec", in: space, folder: specs),
            tab("Guide", in: space, folder: docs), tab("Paper", in: space, folder: reading), tab("Unpinned", in: space, folder: open),
        ]
        let entries = BookmarkMenu.entries(for: Persona.defaultID, personas: [defaultPersona], spaces: [space],
                                           favorites: [], tree: FolderTree(folders: [projects, docs, specs, empty, reading, open], tabs: tabs))
        #expect(outline(entries) == [
            "Personal >",
            "  Projects >",
            "    Docs >",
            "      Specs >",
            "        Spec",
            "      Guide",
            "    Board",
            "  Reading >",
            "    Paper",
            "  Loose",
        ])
    }

    @Test func entriesCarryWhatChoosingThemSelectsAndTheirAddresses() throws {
        let space = Space(name: "Personal", personaID: Persona.defaultID)
        let pinned = tab("Mail", in: space)
        let untitled = Favorite(url: URL(string: "https://music.example/library")!, title: "", personaID: Persona.defaultID)
        let entries = BookmarkMenu.entries(for: Persona.defaultID, personas: [defaultPersona], spaces: [space],
                                           favorites: [untitled], tree: FolderTree(folders: [], tabs: [pinned]))
        // A favorite without a title is named by its host.
        #expect(entries.first == .favorite(id: untitled.id, title: "music.example", url: untitled.url))
        let submenu = try #require(entries.last)
        #expect(submenu == .submenu(title: "Personal", entries: [.tab(id: pinned.id, title: "Mail", url: URL(string: "https://example.org/Mail"))]))
    }

    @Test func withoutFavoritesAndPinnedTabsTheMenuSaysNoBookmarks() {
        let space = Space(name: "Personal", personaID: Persona.defaultID)
        let entries = BookmarkMenu.entries(for: Persona.defaultID, personas: [defaultPersona], spaces: [space],
                                           favorites: [], tree: FolderTree(folders: [], tabs: [tab("Article", in: space, pinned: false)]))
        #expect(entries == [.noBookmarks])
    }

    // MARK: Two Personas

    @Test func withTwoPersonasSpacesShowPersonaSlashSpaceInPersonaOrder() {
        let research = Space(name: "Research", personaID: work.id)
        let defaultPersonal = Space(name: "Personal", personaID: Persona.defaultID)
        let workPersonal = Space(name: "Personal", personaID: work.id)
        let tabs = [tab("Papers", in: research), tab("Mail", in: defaultPersonal), tab("Tracker", in: workPersonal)]
        // The spaces come in a different order than the Personas; the menu follows the Personas, then each Persona's spaces in their order.
        let entries = BookmarkMenu.entries(for: work.id, personas: [defaultPersona, work], spaces: [research, defaultPersonal, workPersonal],
                                           favorites: [favorite("Calendar", of: defaultPersona), favorite("Chat", of: work)], tree: FolderTree(folders: [], tabs: tabs))
        #expect(outline(entries) == [
            "# Work",
            "* Chat",
            "---",
            "Default / Personal >",
            "  Mail",
            "---",
            "Work / Research >",
            "  Papers",
            "Work / Personal >",
            "  Tracker",
        ])
    }

    @Test func withTwoPersonasTheFavoritesAreTheWindowsPersonasUnderItsNameAlone() {
        let defaultPersonal = Space(name: "Personal", personaID: Persona.defaultID)
        let favorites = [favorite("Calendar", of: defaultPersona), favorite("Chat", of: work)]
        let entries = BookmarkMenu.entries(for: Persona.defaultID, personas: [defaultPersona, work], spaces: [defaultPersonal],
                                           favorites: favorites, tree: FolderTree(folders: [], tabs: []))
        #expect(outline(entries) == ["# Default", "* Calendar"])
        // A Persona without favorites and pinned tabs, while another Persona has favorites, still shows No Bookmarks.
        let workSpace = Space(name: "Personal", personaID: work.id)
        let workEntries = BookmarkMenu.entries(for: work.id, personas: [defaultPersona, work], spaces: [defaultPersonal, workSpace],
                                               favorites: [favorite("Calendar", of: defaultPersona)], tree: FolderTree(folders: [], tabs: []))
        #expect(workEntries == [.noBookmarks])
    }
}
