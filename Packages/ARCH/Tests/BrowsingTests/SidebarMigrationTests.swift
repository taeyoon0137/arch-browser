// The import sheet's reviewed selection survives a real session save, relaunch and second import.
import ARCHEngine
@testable import Browsing
import Foundation
@testable import Import
import Testing

@MainActor @Suite struct SidebarMigrationTests {
    @Test func aReimportPreservesTheUsersMovedAndRenamedPinsAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source")
        let profile = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let stateFile = sourceDirectory.appendingPathComponent("Local State")
        let sidebarFile = sourceDirectory.appendingPathComponent("Sidebar.json")
        let state = Data(#"{"profile":{"info_cache":{"Default":{"name":"Imported Work"}},"profiles_order":["Default"]}}"#.utf8)
        let sidebar = Data(sidebarJSON.utf8)
        try state.write(to: stateFile)
        try sidebar.write(to: sidebarFile)
        let source = BrowserSource(name: "Fixture Browser", bundleIdentifier: "fixture.import", layout: .chromium(userData: sourceDirectory, sidebarFile: sidebarFile), privacySetting: .fullDiskAccess)

        func launch() throws -> BrowserSession {
            let registry = EngineRegistry()
            registry.register(SessionTestEngine())
            return try BrowserSession(testRegistry: registry, directory: profile)
        }
        func reviewedImport(_ session: BrowserSession, newPersona: Bool) throws -> (SidebarImport.Counts, SidebarImport.Destination) {
            let model = BrowserImportModel(personas: session.$personas, currentPersonaID: Persona.defaultID, record: .init(directory: profile))
            model.show([ImportedBrowser.read(source)])
            let key = try #require(model.choices.keys.first)
            if newPersona { model.choices[key]?.destination = .newPersona }
            let selection = model.selection
            try #require(selection.failures.isEmpty && selection.rows.count == 1)
            let selected = selection.rows[0]
            var record = model.record
            let counts = session.addImport(selected.row, to: selected.destination, record: &record)
            record.write()
            return (counts, selected.destination)
        }

        let ownerID: UUID, movedPinID: UUID
        let spaceIDs: [UUID], orderedIDs: [UUID]
        let favorites: [Favorite], folders: [TabFolder]
        let savedPage: SavedPage?
        let nextPage = try #require(URL(string: "https://fixture.invalid/updated"))
        do {
            let session = try launch()
            let (first, _) = try reviewedImport(session, newPersona: true)
            #expect(first.personas == 1 && first.spaces == 2 && first.favorites == 2 && first.pinnedTabs == 5)
            let owner = try #require(session.personas.first { $0.name == "Imported Work" })
            let spaces = session.spaces(in: owner.id)
            try #require(spaces.map(\.name) == ["Work", "Research"])
            #expect(spaces.map(\.tint) == [.blue, .gray])
            folders = session.folders.filter { $0.spaceID == spaces[0].id }
            try #require(folders.map(\.name) == ["Reference", "Reference ▸ Notes"])
            func path(_ tab: Tab) -> String? { tab.savedPage?.url.lastPathComponent }
            let pins = session.tabs.filter { $0.personaID == owner.id }
            #expect(pins.allSatisfy { $0.isPinned && !$0.isLoaded })
            #expect(pins.filter { $0.folderID == nil && $0.spaceID == spaces[0].id }.compactMap(path) == ["one", "five"])
            #expect(pins.filter { $0.folderID == folders[0].id }.compactMap(path) == ["two"])
            #expect(pins.filter { $0.folderID == folders[1].id }.compactMap(path) == ["three"])
            #expect(pins.filter { $0.spaceID == spaces[1].id }.compactMap(path) == ["four"])
            favorites = session.favorites.filter { $0.resolvedPersonaID == owner.id }
            #expect(favorites.map(\.title) == ["Favorite B", "Favorite A"])

            let pin = try #require(pins.first { path($0) == "two" })
            session.loadPage(of: pin)
            #expect(pins.filter(\.isLoaded).map(\.id) == [pin.id])
            let contents = try #require(pin.webContents as? PageDouble)
            contents.load(nextPage, in: pin)
            #expect(pin.url == nextPage && path(pin) == "two")
            let window = BrowserWindowModel(session: session, record: .init(id: UUID(), frame: nil, currentSpaceID: spaces[0].id, selectedTabID: pin.id, isSidebarVisible: true), kind: .main)
            window.renameTab(pin.id, to: "My reference")
            window.renameSpace(spaces[0].id, to: "My work")
            session.moveTab(pin.id, toSpace: spaces[1].id)
            ownerID = owner.id
            movedPinID = pin.id
            spaceIDs = spaces.map(\.id)
            orderedIDs = session.tabs.map(\.id)
            savedPage = pin.savedPage
            try session.saveNow().get()
        }
        let session = try launch()

        let (second, destination) = try reviewedImport(session, newPersona: false)
        #expect(destination == .persona(ownerID))
        #expect(second.personas == 0 && second.spaces == 0 && second.favorites == 0 && second.pinnedTabs == 0)
        #expect(session.spaces(in: ownerID).map(\.name) == ["My work", "Research"])
        #expect(session.spaces(in: ownerID).map(\.id) == spaceIDs)
        #expect(session.folders.filter { $0.spaceID == spaceIDs[0] } == folders)
        #expect(session.tabs.map(\.id) == orderedIDs && session.favorites.filter { $0.resolvedPersonaID == ownerID } == favorites)
        let moved = try #require(session.tabs.first { $0.id == movedPinID })
        #expect(moved.isPinned && moved.spaceID == spaceIDs[1] && moved.folderID == nil && moved.customTitle == "My reference")
        #expect(moved.url == nextPage && moved.savedPage == savedPage)
        #expect(try Data(contentsOf: stateFile) == state)
        #expect(try Data(contentsOf: sidebarFile) == sidebar)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path).sorted() == ["Local State", "Sidebar.json"])
    }
}

private let sidebarJSON = """
{
  "sidebar": {"containers": [{
    "spaces": [
      "s1", {"id":"s1","title":"Work","profile":{"default":true},"containerIDs":["pinned","p1"],
             "customInfo":{"windowTheme":{"primaryColorPalette":{"midTone":{"red":0.2,"green":0.4,"blue":0.9}}}}},
      "s2", {"id":"s2","title":"Research","profile":{"default":true},"containerIDs":["pinned","p2"],
             "customInfo":{"windowTheme":{"primaryColorPalette":{"midTone":{"red":0.5,"green":0.5,"blue":0.5}}}}}
    ],
    "topAppsContainerIDs": [{"default":true},"f"],
    "items": [
      "p1", {"id":"p1","childrenIds":["n1","n5","d1"]},
      "p2", {"id":"p2","childrenIds":["n4"]},
      "d1", {"id":"d1","title":"Reference","data":{"list":{}},"childrenIds":["n2","d2"]},
      "d2", {"id":"d2","title":"Notes","data":{"list":{}},"childrenIds":["n3"]},
      "f", {"id":"f","childrenIds":["fb","fa"]},
      "fb", {"id":"fb","data":{"tab":{"savedURL":"https://fixture.invalid/b","savedTitle":"Favorite B"}}},
      "fa", {"id":"fa","data":{"tab":{"savedURL":"https://fixture.invalid/a","savedTitle":"Favorite A"}}},
      "n1", {"id":"n1","data":{"tab":{"savedURL":"https://fixture.invalid/one","savedTitle":"One"}}},
      "n2", {"id":"n2","data":{"tab":{"savedURL":"https://fixture.invalid/two","savedTitle":"Two"}}},
      "n3", {"id":"n3","data":{"tab":{"savedURL":"https://fixture.invalid/three","savedTitle":"Three"}}},
      "n5", {"id":"n5","data":{"tab":{"savedURL":"https://fixture.invalid/five","savedTitle":"Five"}}},
      "n4", {"id":"n4","data":{"tab":{"savedURL":"https://fixture.invalid/four","savedTitle":"Four"}}}
    ]
  }]}
}
"""
