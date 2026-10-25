// The browser import's plan on sidebars built as values: merges by name and address without a record, the record's IDs after the user moved, renamed, or removed what an import brought, new Personas, the default destination, and `imports.json`. Rows hold made-up addresses only.
import Foundation
import Testing
@testable import Browsing

@Suite struct SidebarImportTests {
    private static let profile = SidebarImport.Profile(source: "test.browser", folder: "Default")

    private static func url(_ host: String) -> URL {
        URL(string: "https://\(host)/")!
    }

    private static func item(_ id: String, _ host: String, customTitle: String? = nil) -> SidebarImport.Item {
        SidebarImport.Item(sourceID: id, url: url(host), title: host, customTitle: customTitle)
    }

    /// Favorites a and b; a space Work with c pinned and a folder Docs with d; and the bookmarks space Browser with a folder holding e.
    private static let row = SidebarImport(profile: profile, profileName: "Work Profile", favorites: [item("fa", "a.example"), item("fb", "b.example")], spaces: [
        SidebarImport.SourceSpace(origin: .space("work"), name: "Work", tint: .green, pinnedItems: [item("c", "c.example", customTitle: "My C")], folders: [
            SidebarImport.Folder(sourceID: "docs", name: "Docs", items: [item("d", "d.example")]),
        ]),
        SidebarImport.SourceSpace(origin: .bookmarks, name: "Browser", tint: nil, pinnedItems: [], folders: [
            SidebarImport.Folder(sourceID: "recipes", name: "Other Bookmarks / Recipes", items: [item("e", "e.example")]),
        ]),
    ])

    /// The default Persona with its space Personal.
    private static func sidebar() -> SidebarImport.Sidebar {
        SidebarImport.Sidebar(personas: [Persona(id: Persona.defaultID, name: "Default")], spaces: [Space(name: "Personal", personaID: Persona.defaultID)],
                              folders: [], favorites: [], tabs: [])
    }

    private static func plan(_ row: SidebarImport = row, to destination: SidebarImport.Destination = .persona(Persona.defaultID), entry: SidebarImport.Record.Entry? = nil,
                             in sidebar: SidebarImport.Sidebar) -> SidebarImport.Plan {
        SidebarImport.Plan(row, to: destination, entry: entry, in: sidebar)
    }

    @Test func withoutARecordSpacesAndFoldersMergeByNameAndPresentItemsStayOut() throws {
        var sidebar = Self.sidebar()
        let work = Space(name: "Work", personaID: Persona.defaultID)
        let docs = TabFolder(spaceID: work.id, name: "Docs", isPinned: true)
        sidebar.spaces.append(work)
        sidebar.folders.append(docs)
        // c is pinned inside the folder, and the row pins it outside folders.
        sidebar.tabs.append(SidebarImport.Sidebar.TabState(id: UUID(), spaceID: work.id, isPinned: true, url: Self.url("c.example")))
        sidebar.favorites.append(Favorite(url: Self.url("a.example"), title: "A", personaID: Persona.defaultID))

        let plan = Self.plan(in: sidebar)
        #expect(plan.newPersona == nil)
        #expect(plan.spaces.map(\.name) == ["Browser"])
        #expect(plan.spaces.map(\.tint) == [BrowserSession.newSpaceTint(among: sidebar.spaces)])
        let browser = try #require(plan.spaces.first)
        #expect(plan.folders.map(\.name) == ["Other Bookmarks / Recipes"])
        #expect(plan.folders.map(\.spaceID) == [browser.id])
        #expect(plan.pinnedTabs.map(\.url) == [Self.url("d.example"), Self.url("e.example")])
        #expect(plan.pinnedTabs.map(\.spaceID) == [work.id, browser.id])
        #expect(plan.pinnedTabs.map(\.folderID) == [docs.id, plan.folders[0].id])
        #expect(plan.favorites.map(\.url) == [Self.url("b.example")])
        #expect(plan.favorites.map(\.personaID) == [Persona.defaultID])
        #expect(plan.counts == SidebarImport.Counts(spaces: 1, pinnedTabs: 2, favorites: 1, presentFavorites: 1))
        // The space and folder that the row merged into count as what it brought.
        let items = plan.entry.items(in: Persona.defaultID)
        #expect(items.spaces == ["work": work.id])
        #expect(items.bookmarksSpace == browser.id)
        #expect(items.folders == ["docs": docs.id, "recipes": plan.folders[0].id])
        #expect(Set(items.pinnedTabs.keys) == ["d", "e"])
        #expect(Set(items.favorites.keys) == ["fb"])
    }

    @Test func aSecondIdenticalImportAddsNothing() {
        var sidebar = Self.sidebar()
        let first = Self.plan(in: sidebar)
        #expect(first.counts == SidebarImport.Counts(spaces: 2, pinnedTabs: 3, favorites: 2))
        #expect(first.pinnedTabs.first?.customTitle == "My C")
        sidebar.apply(first)
        for entry in [nil, first.entry] {
            let second = Self.plan(entry: entry, in: sidebar)
            #expect(second.spaces.isEmpty)
            #expect(second.folders.isEmpty)
            #expect(second.favorites.isEmpty)
            #expect(second.pinnedTabs.isEmpty)
            #expect(second.counts == SidebarImport.Counts(presentFavorites: 2))
        }
    }

    @Test func aNewPersonaTakesTheImportedSpacesOrPersonal() throws {
        let plan = Self.plan(to: .newPersona, in: Self.sidebar())
        let persona = try #require(plan.newPersona)
        #expect(persona.name == "Work Profile")
        #expect(plan.personaID == persona.id)
        #expect(plan.spaces.map(\.name) == ["Work", "Browser"])
        #expect(plan.spaces.map(\.tint) == [.green, SpaceTint.colors[2]])
        #expect(plan.spaces.allSatisfy { $0.personaID == persona.id })
        #expect(plan.favorites.allSatisfy { $0.personaID == persona.id })
        #expect(plan.counts == SidebarImport.Counts(personas: 1, spaces: 2, pinnedTabs: 3, favorites: 2))

        // A space with nothing to pin is not made, as a folder is not.
        var favoritesOnly = Self.row
        favoritesOnly.spaces = [SidebarImport.SourceSpace(origin: .space("empty"), name: "Empty", tint: nil, pinnedItems: [], folders: [])]
        let personal = Self.plan(favoritesOnly, to: .newPersona, in: Self.sidebar())
        #expect(personal.spaces.map(\.name) == ["Personal"])
        #expect(personal.spaces.map(\.personaID) == [personal.newPersona?.id])
        #expect(personal.counts == SidebarImport.Counts(personas: 1, favorites: 2))
    }

    @Test func aDestinationDeletedSinceItWasPickedBecomesANewPersona() {
        let plan = Self.plan(to: .persona(UUID()), in: Self.sidebar())
        #expect(plan.newPersona?.name == "Work Profile")
        #expect(plan.spaces.map(\.name) == ["Work", "Browser"])
    }

    @Test func withTheRecordAMovedTabAndARenamedSpaceComeInOnce() throws {
        var sidebar = Self.sidebar()
        let first = Self.plan(in: sidebar)
        sidebar.apply(first)
        let work = try #require(first.spaces.first { $0.name == "Work" })
        let pinnedC = try #require(first.entry.items(in: Persona.defaultID).pinnedTabs["c"])
        sidebar.spaces[try #require(sidebar.spaces.firstIndex { $0.id == work.id })].name = "Projects"
        sidebar.tabs[try #require(sidebar.tabs.firstIndex { $0.id == pinnedC })].url = Self.url("elsewhere.example")

        let second = Self.plan(entry: first.entry, in: sidebar)
        #expect(second.spaces.isEmpty)
        #expect(second.pinnedTabs.isEmpty)
        #expect(second.counts == SidebarImport.Counts(presentFavorites: 2))
        // Names and addresses alone would bring the space and its tab back.
        let withoutRecord = Self.plan(in: sidebar)
        #expect(withoutRecord.spaces.map(\.name) == ["Work"])
        #expect(withoutRecord.pinnedTabs.map(\.url) == [Self.url("c.example"), Self.url("d.example")])
    }

    @Test func aRecordedSpaceTheUserDeletedDoesNotComeBackEmpty() throws {
        var sidebar = Self.sidebar()
        let first = Self.plan(in: sidebar)
        sidebar.apply(first)
        // As `BrowserSession.deleteSpace(_:)` does, the space's folder and tab move to the space before it.
        let browser = try #require(first.spaces.first { $0.name == "Browser" })
        let work = try #require(first.spaces.first { $0.name == "Work" })
        sidebar.spaces.removeAll { $0.id == browser.id }
        for index in sidebar.folders.indices where sidebar.folders[index].spaceID == browser.id { sidebar.folders[index].spaceID = work.id }
        for index in sidebar.tabs.indices where sidebar.tabs[index].spaceID == browser.id { sidebar.tabs[index].spaceID = work.id }

        let second = Self.plan(entry: first.entry, in: sidebar)
        #expect(second.spaces.isEmpty)
        #expect(second.folders.isEmpty)
        #expect(second.pinnedTabs.isEmpty)
        #expect(second.counts == SidebarImport.Counts(presentFavorites: 2))
        #expect(second.entry.items(in: Persona.defaultID).bookmarksSpace == nil)
    }

    @Test func anUntitledSpaceMergesIntoTheSpaceItBecame() {
        let row = SidebarImport(profile: Self.profile, profileName: "Work Profile", favorites: [], spaces: [
            SidebarImport.SourceSpace(origin: .space("untitled"), name: nil, tint: nil, pinnedItems: [Self.item("u", "u.example")], folders: []),
        ])
        var sidebar = Self.sidebar()
        let first = Self.plan(row, in: sidebar)
        #expect(first.spaces.map(\.name) == ["Space 1"])
        sidebar.apply(first)
        let second = Self.plan(row, entry: first.entry, in: sidebar)
        #expect(second.spaces.isEmpty)
        #expect(second.pinnedTabs.isEmpty)
        #expect(Self.plan(row, in: sidebar).spaces.map(\.name) == ["Space 2"])
    }

    @Test func aRecordedItemThatIsGoneImportsAgain() throws {
        var sidebar = Self.sidebar()
        let first = Self.plan(in: sidebar)
        sidebar.apply(first)
        let items = first.entry.items(in: Persona.defaultID)
        let favoriteB = try #require(items.favorites["fb"])
        let pinnedD = try #require(items.pinnedTabs["d"])
        sidebar.favorites.removeAll { $0.id == favoriteB }
        sidebar.tabs.removeAll { $0.id == pinnedD }

        let second = Self.plan(entry: first.entry, in: sidebar)
        #expect(second.favorites.map(\.url) == [Self.url("b.example")])
        #expect(second.pinnedTabs.map(\.url) == [Self.url("d.example")])
        #expect(second.pinnedTabs.map(\.folderID) == [items.folders["docs"]])
        #expect(second.entry.items(in: Persona.defaultID).pinnedTabs["d"] == second.pinnedTabs.first?.id)
        #expect(second.entry.items(in: Persona.defaultID).favorites["fb"] == second.favorites.first?.id)
    }

    @Test func theDefaultDestinationIsTheRecordedPersonaWhileItExists() throws {
        let folder = try TemporaryFolder()
        let recorded = Persona(name: "Recorded")
        let named = Persona(name: "Work Profile")
        let current = Persona.defaultID
        var record = SidebarImport.Record(directory: folder.url)
        let personas = [Persona(id: Persona.defaultID, name: "Default"), recorded, named]
        #expect(Self.row.defaultDestination(record: record, personas: personas, currentPersonaID: current, isFirstProfile: false) == .persona(named.id))
        record.update(SidebarImport.Record.Entry(profile: Self.profile, personaID: recorded.id, personas: []))
        #expect(Self.row.defaultDestination(record: record, personas: personas, currentPersonaID: current, isFirstProfile: false) == .persona(recorded.id))
        let remaining = [Persona(id: Persona.defaultID, name: "Default")]
        #expect(Self.row.defaultDestination(record: record, personas: remaining, currentPersonaID: current, isFirstProfile: true) == .persona(current))
        #expect(Self.row.defaultDestination(record: record, personas: remaining, currentPersonaID: current, isFirstProfile: false) == .newPersona)
    }

    @Test func theRecordIsWrittenAndReadWithoutGoneItems() throws {
        let folder = try TemporaryFolder()
        var sidebar = Self.sidebar()
        let first = Self.plan(in: sidebar)
        sidebar.apply(first)
        var record = SidebarImport.Record(directory: folder.url)
        record.update(first.entry)
        var otherPersona = SidebarImport.Record.Items(personaID: UUID())
        otherPersona.favorites["fa"] = UUID()
        var withGonePersona = first.entry
        withGonePersona.update(otherPersona)
        record.update(withGonePersona)
        record.update(SidebarImport.Record.Entry(profile: SidebarImport.Profile(source: "test.browser", folder: "Profile 2"), personaID: UUID(), personas: []))
        record.write()
        #expect(SidebarImport.Record(directory: folder.url).entries == record.entries)

        let pinnedD = try #require(first.entry.items(in: Persona.defaultID).pinnedTabs["d"])
        sidebar.tabs.removeAll { $0.id == pinnedD }
        record.removeGoneItems(in: sidebar)
        var expected = first.entry
        expected.personas[0].pinnedTabs["d"] = nil
        #expect(record.entries == [expected])
    }

    @Test func anUndecodableRecordIsEmptyAndMovesAsideAtTheFirstWrite() throws {
        let folder = try TemporaryFolder()
        let unreadable = folder.url.appendingPathComponent("imports.unreadable.json")
        try Data("{".utf8).write(to: folder.url.appendingPathComponent("imports.json"))
        var record = SidebarImport.Record(directory: folder.url)
        #expect(record.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: unreadable.path))

        record.update(SidebarImport.Record.Entry(profile: Self.profile, personaID: Persona.defaultID, personas: []))
        record.write()
        #expect(try Data(contentsOf: unreadable) == Data("{".utf8))
        #expect(SidebarImport.Record(directory: folder.url).entries == record.entries)
        // A later write leaves the moved file as it is.
        record.write()
        #expect(try Data(contentsOf: unreadable) == Data("{".utf8))
    }
}

private extension SidebarImport.Sidebar {
    /// What `BrowserSession.addImport(_:to:record:)` does to the session, on the values a plan reads.
    mutating func apply(_ plan: SidebarImport.Plan) {
        if let persona = plan.newPersona { personas.append(persona) }
        spaces += plan.spaces
        folders += plan.folders
        favorites += plan.favorites
        tabs += plan.pinnedTabs.map { TabState(id: $0.id, spaceID: $0.spaceID, isPinned: true, url: $0.url) }
    }
}

/// A folder of its own for one test's files, removed when the test ends.
private final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSidebarImportTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
