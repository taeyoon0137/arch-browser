// Loading and saving `session.json`: files of each version gain what they lack through `normalized()`, files this build cannot read or fully understand stay on disk, a scheduled save writes the snapshot taken last, or nothing without one, and the page state is sealed in a file only the user can read.
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Browsing

@Suite struct SessionSnapshotTests {
    @Test(arguments: [1, 4, 7])
    func olderFilesLoadWithAnIDForEveryTabRecord(version: Int) throws {
        let folder = try SessionFolder()
        try folder.write(try #require(olderFiles[version]))
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.spaces.map(\.id) == [spaceA, spaceB])
        #expect(snapshot.currentSpaceID == spaceB)
        #expect(snapshot.favorites.map(\.id) == [favoriteID])
        #expect(snapshot.tabs.map(\.url) == ["a", "b", "c"].map { URL(string: "https://example.org/\($0)") })
        #expect(snapshot.tabs.map(\.spaceID) == [spaceA, spaceA, spaceB])
        #expect(snapshot.selectedTabIndex == 2)
        #expect(snapshot.closedTabs?.map(\.url) == [URL(string: "https://example.org/closed")])
        let ids = snapshot.allTabIDs
        #expect(!ids.contains(nil))
        #expect(Set(ids).count == ids.count)
    }

    @Test func version4FilesKeepTheirEnginesNamesAndHomePages() throws {
        let folder = try SessionFolder()
        try folder.write(version4File)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.spaces.map(\.homeURL) == [URL(string: "https://example.org/home"), nil])
        #expect(snapshot.tabs.map(\.engine) == [.chromium, .webKit, .chromium])
        #expect(snapshot.tabs.map(\.customTitle) == ["Renamed", nil, nil])
        #expect(snapshot.tabs[0].state == Data([0, 1]))
    }

    @Test func version7FilesGiveTheFavoritesTabAnID() throws {
        let folder = try SessionFolder()
        try folder.write(version7File)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.favoriteTabs?.map(\.favoriteID) == [favoriteID])
        #expect(snapshot.favoriteTabs?.first?.id != nil)
        #expect(snapshot.splitViews == [[0, 1]])
    }

    @Test func savedIDsLoadUnchanged() throws {
        let folder = try SessionFolder()
        try folder.write(version8File)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.allTabIDs == [tab1, tab2, tab3, favoriteTab, closedTab])
    }

    @Test func repeatedIDsAreReplacedAfterTheirFirstUse() throws {
        let folder = try SessionFolder()
        try folder.write(version8File.replacingOccurrences(of: tab3.uuidString, with: tab1.uuidString)
            .replacingOccurrences(of: favoriteTab.uuidString, with: tab1.uuidString)
            .replacingOccurrences(of: closedTab.uuidString, with: tab2.uuidString))
        let snapshot = try #require(folder.store.load())
        let ids = snapshot.allTabIDs.compactMap { $0 }
        #expect(ids.count == 5)
        #expect(Set(ids).count == 5)
        #expect(Array(ids.prefix(2)) == [tab1, tab2])
    }

    /// WebKit's state keeps a form a page sent, a password among it, so the file holds the state only sealed. State from a build before sealing loads as it was and is sealed when the session saves.
    @Test func pageStateIsSealedInAFileOnlyTheUserReads() throws {
        let folder = try SessionFolder()
        try folder.write(version4File)
        var snapshot = try #require(folder.store.load())
        #expect(snapshot.tabs[0].state == Data([0, 1]))
        let state = Data("user=alice&pw=HUNTER2SECRET".utf8)
        snapshot.tabs[1].state = state
        snapshot.favoriteTabs = [SessionSnapshot.FavoriteTabRecord(id: UUID(), favoriteID: favoriteID, url: nil, engine: .webKit, state: state)]
        folder.store.saveNow(snapshot)
        let file = try folder.contents(of: "session.json")
        #expect(file.range(of: Data("HUNTER2SECRET".utf8)) == nil && file.range(of: Data(state.base64EncodedString().utf8)) == nil)
        #expect(file.range(of: Data(#""AAE=""#.utf8)) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.url.appendingPathComponent("session.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reloaded = try #require(folder.store.load())
        #expect(reloaded.tabs.map(\.state) == [Data([0, 1]), state, nil])
        #expect(reloaded.favoriteTabs?.first?.state == state)
        // Without the key, as after the user denies the keychain prompt, the tabs load without their state.
        let keyless = SessionStore(directory: folder.url, seal: SessionStateSeal { nil })
        #expect(try #require(keyless.load()).tabs.allSatisfy { $0.state == nil })
        keyless.saveNow(reloaded)
        #expect(try #require(folder.store.load()).tabs.allSatisfy { $0.state == nil })
    }

    @Test func savedSnapshotsLoadWithTheSameIDs() throws {
        let folder = try SessionFolder()
        try folder.write(version7File)
        let loaded = try #require(folder.store.load())
        folder.store.saveNow(loaded)
        let reloaded = try #require(folder.store.load())
        #expect(!loaded.allTabIDs.contains(nil))
        #expect(reloaded.allTabIDs == loaded.allTabIDs)
    }

    @Test(arguments: [1, 4, 7, 8])
    func olderFilesLoadIntoTheDefaultPersona(version: Int) throws {
        let folder = try SessionFolder()
        try folder.write(try #require(filesWithoutPersonas[version]))
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.personas == [Persona(id: Persona.defaultID, name: "Default")])
        #expect(snapshot.spaces.map(\.id) == [spaceA, spaceB])
        #expect(snapshot.spaces.map(\.personaID) == [Persona.defaultID, Persona.defaultID])
        #expect(snapshot.favorites.map(\.personaID) == [Persona.defaultID])
        #expect(snapshot.tabs.map(\.personaID) == Array(repeating: Persona.defaultID, count: 3))
        #expect(snapshot.closedTabs?.map(\.personaID) == [Persona.defaultID])
    }

    @Test func personasKeepTheirOrderAndRepairWhatTheyLack() throws {
        let folder = try SessionFolder()
        try folder.write(version9File)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.personas?.map(\.id) == [workPersona, Persona.defaultID, homePersona])
        // Each Persona's spaces sit together. A space of an unlisted Persona joins the first, one without a Persona joins the default, and a Persona without spaces gets one.
        #expect(snapshot.spaces.count == 5)
        #expect(Array(snapshot.spaces.map(\.id).prefix(4)) == [spaceW, spaceB, spaceA, spaceC])
        #expect(snapshot.spaces.map(\.personaID) == [workPersona, workPersona, Persona.defaultID, Persona.defaultID, homePersona])
        #expect(snapshot.spaces.last?.name == "Personal")
        #expect(snapshot.favorites.map(\.personaID) == [Persona.defaultID, workPersona])
        // Open tabs take their space's Persona; a tab whose space is gone keeps its own.
        #expect(snapshot.tabs.map(\.personaID) == [Persona.defaultID, workPersona, homePersona])
        // Closed tabs keep their own Persona, or take their space's, or the default Persona.
        #expect(snapshot.closedTabs?.map(\.personaID) == [homePersona, workPersona, Persona.defaultID])
    }

    @Test func theDefaultPersonaIsAddedFirstAndARepeatedPersonaKeepsItsFirstPlace() throws {
        let folder = try SessionFolder()
        try folder.write(version9File.replacingOccurrences(of: #"{ "id": "\#(Persona.defaultID)", "name": "Default" }"#, with: #"{ "id": "\#(workPersona)", "name": "Repeated" }"#))
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.personas == [Persona(id: Persona.defaultID, name: "Default"), Persona(id: workPersona, name: "Work"), Persona(id: homePersona, name: "Home")])
        // The default Persona is now first, so the space of an unlisted Persona joins it.
        #expect(Array(snapshot.spaces.map(\.id).prefix(4)) == [spaceA, spaceB, spaceC, spaceW])
        #expect(snapshot.spaces.map(\.personaID) == [Persona.defaultID, Persona.defaultID, Persona.defaultID, workPersona, homePersona])
    }

    /// A file that lists a space or folder twice, as a hand-edited file can, keeps its first copy, with the tabs and folders that the file places in it by its ID, as a repeated Persona keeps its first place. A favorite listed twice keeps both, the later one with a new ID, as a repeated tab record does.
    @Test func aRepeatedSpaceOrFolderKeepsItsFirstCopyAndARepeatedFavoriteGetsANewID() {
        let space = Space(id: spaceA, name: "Personal"), other = Space(id: spaceB, name: "Other")
        var laterSpace = space
        laterSpace.name = "Later"
        let folder = TabFolder(id: workFolder, spaceID: spaceA, name: "Work", isPinned: true)
        var laterFolder = folder
        laterFolder.name = "Later"
        laterFolder.spaceID = spaceB
        let child = TabFolder(id: docsFolder, spaceID: spaceA, name: "Docs", isPinned: true, parentID: workFolder)
        let favorite = Favorite(id: favoriteID, url: URL(string: "https://example.org/")!, title: "Favorite")
        var laterFavorite = favorite
        laterFavorite.title = "Later"
        let tab = SessionSnapshot.TabRecord(id: tab1, spaceID: spaceA, url: URL(string: "https://example.org/a"), title: "A", isPinned: true, folderID: docsFolder)
        let snapshot = SessionSnapshot(spaces: [space, laterSpace, other], currentSpaceID: spaceA, favorites: [favorite, laterFavorite], tabs: [tab],
                                       folders: [folder, laterFolder, child]).normalized()
        #expect(snapshot.spaces.map(\.id) == [spaceA, spaceB] && snapshot.spaces.map(\.name) == ["Personal", "Other"])
        #expect(snapshot.folders?.map(\.name) == ["Work", "Docs"] && snapshot.folders?.map(\.spaceID) == [spaceA, spaceA])
        #expect(snapshot.folders?.map(\.parentID) == [nil, workFolder] && snapshot.tabs.map(\.folderID) == [docsFolder])
        #expect(snapshot.favorites.map(\.title) == ["Favorite", "Later"] && snapshot.favorites.first?.id == favoriteID)
        #expect(Set(snapshot.favorites.map(\.id)).count == 2)
    }

    @Test func savedPersonasLoadUnchanged() throws {
        let folder = try SessionFolder()
        try folder.write(version9File)
        let loaded = try #require(folder.store.load())
        folder.store.saveNow(loaded)
        let reloaded = try #require(folder.store.load())
        #expect(reloaded.personas == loaded.personas)
        #expect(reloaded.spaces == loaded.spaces)
        #expect(reloaded.favorites == loaded.favorites)
        #expect(reloaded.tabs.map(\.personaID) == loaded.tabs.map(\.personaID))
        #expect(reloaded.closedTabs?.map(\.personaID) == loaded.closedTabs?.map(\.personaID))
    }

    @Test func onlyPersonasThatAreGoneStayListedForRemoval() throws {
        let folder = try SessionFolder()
        try folder.write(version10File)
        let loaded = try #require(folder.store.load())
        // The default Persona and the listed Work Persona keep their data. The unlisted Persona is gone, though a space still names it.
        #expect(loaded.removedPersonaIDs == [removedPersona, unlistedPersona])
        folder.store.saveNow(loaded)
        #expect(try #require(folder.store.load()).removedPersonaIDs == [removedPersona, unlistedPersona])
    }

    @Test func filesBeforeVersion10ListNoPersonasForRemoval() throws {
        let folder = try SessionFolder()
        try folder.write(version9File)
        #expect(try #require(folder.store.load()).removedPersonaIDs == nil)
    }

    @Test func anEmptySnapshotGetsTheDefaultPersonaAndOneSpace() {
        let snapshot = SessionSnapshot.empty.normalized()
        #expect(snapshot.personas == [Persona(id: Persona.defaultID, name: "Default")])
        #expect(snapshot.spaces.map(\.name) == ["Personal"])
        #expect(snapshot.spaces.map(\.personaID) == [Persona.defaultID])
        #expect(snapshot.windows?.map(\.currentSpaceID) == snapshot.spaces.map(\.id))
        #expect(snapshot.windows?.first?.selectedTabID == nil)
    }

    @Test(arguments: [1, 4, 7, 8])
    func olderFilesOpenOneWindowOnTheirSelection(version: Int) throws {
        let folder = try SessionFolder()
        try folder.write(try #require(filesWithoutPersonas[version]))
        let snapshot = try #require(folder.store.load())
        let window = try #require(snapshot.windows?.first)
        #expect(snapshot.windows?.count == 1)
        #expect(window.currentSpaceID == spaceB)
        #expect(window.selectedTabID == snapshot.tabs[2].id)
        #expect(window.frame == nil)
        #expect(window.isSidebarVisible)
    }

    @Test func olderFilesOpenTheirWindowOnTheSelectedFavoritesTab() throws {
        let folder = try SessionFolder()
        try folder.write(version8File.replacingOccurrences(of: #""selectedTabIndex": 2,"#, with: #""selectedFavoriteID": "\#(favoriteID)","#))
        let window = try #require(folder.store.load()?.windows?.first)
        // A favorite's tab shows in any space, so the window keeps the saved one.
        #expect(window.currentSpaceID == spaceB)
        #expect(window.selectedTabID == favoriteTab)
    }

    @Test func windowsKeepTheirOrderAndRepairWhatTheyLack() throws {
        let folder = try SessionFolder()
        try folder.write(version11File)
        let windows = try #require(folder.store.load()?.windows)
        #expect(windows.map(\.id) == [window1, window2, window3, window4, window5])
        #expect(windows.map(\.frame) == [frontFrame, nil, nil, nil, nil])
        #expect(windows.map(\.isSidebarVisible) == [false, true, true, true, true])
        // The front window moves to its tab's space, and a window on a missing space goes to the first. A window whose tab the front window selects, or whose tab does not reopen, has none, while a favorite's tab keeps the window's space.
        #expect(windows.map(\.currentSpaceID) == [spaceA, spaceA, spaceB, spaceB, spaceA])
        #expect(windows.map(\.selectedTabID) == [tab1, nil, nil, favoriteTab, nil])
    }

    @Test func anEmptyWindowListOpensOneWindowOnTheSelection() throws {
        let folder = try SessionFolder()
        try folder.write(version8File.replacingOccurrences(of: #""version": 8,"#, with: #""version": 11, "windows": [],"#))
        let windows = try #require(folder.store.load()?.windows)
        #expect(windows.map(\.currentSpaceID) == [spaceB])
        #expect(windows.map(\.selectedTabID) == [tab3])
    }

    @Test func savedWindowsLoadUnchanged() throws {
        let folder = try SessionFolder()
        try folder.write(version11File)
        let loaded = try #require(folder.store.load())
        folder.store.saveNow(loaded)
        let reloaded = try #require(folder.store.load())
        let windows = try #require(loaded.windows)
        let reloadedWindows = try #require(reloaded.windows)
        #expect(reloadedWindows.map(\.id) == windows.map(\.id))
        #expect(reloadedWindows.map(\.frame) == windows.map(\.frame))
        #expect(reloadedWindows.map(\.currentSpaceID) == windows.map(\.currentSpaceID))
        #expect(reloadedWindows.map(\.selectedTabID) == windows.map(\.selectedTabID))
        #expect(reloadedWindows.map(\.isSidebarVisible) == windows.map(\.isSidebarVisible))
    }

    @Test func suggestedTitlesAndTheirRefusalsLoadAndSaveWithTheirAddresses() throws {
        let folder = try SessionFolder()
        try folder.write(version12File)
        let loaded = try #require(folder.store.load())
        #expect(loaded.tabs.map(\.suggestedTitle) == [SuggestedTitle(title: "Example Article", url: URL(string: "https://example.org/a")!),
                                                      SuggestedTitle(title: nil, url: URL(string: "https://example.org/b")!), nil])
        folder.store.saveNow(loaded)
        #expect(try #require(folder.store.load()).tabs.map(\.suggestedTitle) == loaded.tabs.map(\.suggestedTitle))
    }

    @Test func version12FilesSavePinnedTabsAtThePagesTheyShow() throws {
        let folder = try SessionFolder()
        try folder.write(version12File)
        let loaded = try #require(folder.store.load())
        #expect(loaded.tabs.map(\.isPinned) == [true, false, false])
        #expect(loaded.tabs.map(\.savedPage) == [SavedPage(url: URL(string: "https://example.org/a")!, title: "A"), nil, nil])
        #expect(loaded.closedTabs?.map(\.savedPage) == [nil])
        // A closed pinned record gets one too, so that ⇧⌘T reopens the tab saved at the page it closed on.
        try folder.write(version12File.replacingOccurrences(of: #""title": "Closed", "isPinned": false,"#, with: #""title": "Closed", "isPinned": true,"#))
        let closedPinned = try #require(folder.store.load())
        #expect(closedPinned.closedTabs?.map(\.savedPage) == [SavedPage(url: URL(string: "https://example.org/closed")!, title: "Closed")])
    }

    /// A version 13 file, as the builds that seal page state write it before saved pages, folder parents, and live folders: its sealed state opens, its pinned records, open and closed, gain their saved pages, and its folders stay at the top level.
    @Test func version13FilesKeepTheirSealedStateAndGainSavedPages() throws {
        let folder = try SessionFolder()
        let state = Data("back-forward list".utf8)
        let pinned = SessionSnapshot.TabRecord(id: tab1, spaceID: spaceA, url: URL(string: "https://example.org/a")!, title: "A", isPinned: true, folderID: docsFolder, engine: .webKit, state: state)
        let closed = SessionSnapshot.TabRecord(id: closedTab, spaceID: spaceA, url: URL(string: "https://example.org/closed")!, title: "Closed", isPinned: true)
        let docs = TabFolder(id: docsFolder, spaceID: spaceA, name: "Docs", isPinned: true)
        folder.store.saveNow(SessionSnapshot(version: 13, spaces: [Space(id: spaceA, name: "A")], currentSpaceID: spaceA, favorites: [], tabs: [pinned], folders: [docs], closedTabs: [closed]))
        let file = try folder.contents(of: "session.json")
        #expect(file.range(of: state) == nil)
        #expect(["savedPage", "parentID", "live", "liveItemID"].allSatisfy { file.range(of: Data("\"\($0)\"".utf8)) == nil })
        let loaded = try #require(folder.store.load())
        #expect(loaded.tabs.map(\.state) == [state])
        #expect(loaded.tabs.map(\.savedPage) == [SavedPage(url: URL(string: "https://example.org/a")!, title: "A")])
        #expect(loaded.closedTabs?.map(\.savedPage) == [SavedPage(url: URL(string: "https://example.org/closed")!, title: "Closed")])
        #expect(loaded.folders?.map(\.parentID) == [nil] && loaded.tabs.map(\.folderID) == [docsFolder])
    }

    /// A folder without a color, as in every file before version 17, loads with none and writes no `tint`; folder colors save and load.
    @Test func folderColorsLoadAndSaveAndOlderFoldersHaveNone() throws {
        let folder = try SessionFolder()
        var docs = TabFolder(id: docsFolder, spaceID: spaceA, name: "Docs", isPinned: true)
        try folder.store.saveNow(SessionSnapshot(version: 16, spaces: [Space(id: spaceA, name: "A")], currentSpaceID: spaceA, favorites: [], tabs: [], folders: [docs])).get()
        let older = try JSONSerialization.jsonObject(with: folder.contents(of: "session.json")) as? [String: Any]
        let savedFolders = try #require(older?["folders"] as? [[String: Any]])
        #expect(savedFolders.count == 1 && savedFolders[0]["tint"] == nil)
        #expect(try #require(folder.store.load()).folders?.map(\.tint) == [nil])
        for tint in SpaceTint.allCases {
            docs.tint = tint
            try folder.store.saveNow(SessionSnapshot(version: SessionSnapshot.currentVersion, spaces: [Space(id: spaceA, name: "A", tint: .pink)], currentSpaceID: spaceA, favorites: [], tabs: [], folders: [docs])).get()
            let loaded = try #require(folder.store.load())
            #expect(loaded.version == 17)
            #expect(loaded.folders?.map(\.tint) == [tint] && loaded.spaces.map(\.tint) == [.pink])
        }
    }

    @Test func savedPagesLoadAndSaveWithOpenAndClosedRecords() throws {
        let folder = try SessionFolder()
        try folder.write(version14File)
        let loaded = try #require(folder.store.load())
        let saved = SavedPage(url: URL(string: "https://example.org/saved")!, title: "Saved")
        // The unpinned records' saved pages go, and the pinned ones keep theirs wherever their pages went.
        #expect(loaded.tabs.map(\.url) == ["a", "b", "c"].map { URL(string: "https://example.org/\($0)") })
        #expect(loaded.tabs.map(\.savedPage) == [saved, nil, nil])
        #expect(loaded.closedTabs?.map(\.savedPage) == [saved, nil])
        folder.store.saveNow(loaded)
        let reloaded = try #require(folder.store.load())
        #expect(reloaded.tabs.map(\.savedPage) == loaded.tabs.map(\.savedPage))
        #expect(reloaded.closedTabs?.map(\.savedPage) == loaded.closedTabs?.map(\.savedPage))
    }

    @Test func version14FoldersLoadAtTheTopLevel() throws {
        let folder = try SessionFolder()
        try folder.write(version14FileWithFolders)
        let loaded = try #require(folder.store.load())
        #expect(loaded.folders?.map(\.id) == [workFolder, docsFolder])
        #expect(loaded.folders?.map(\.parentID) == [nil, nil])
        #expect(loaded.tabs.map(\.folderID) == [docsFolder, nil, nil])
    }

    @Test func folderParentsLoadAndSaveAndThoseTheFileCannotKeepAreCleared() throws {
        let folder = try SessionFolder()
        try folder.write(version15File)
        let loaded = try #require(folder.store.load())
        // Docs stays in Work; Loose names a folder that is not in the file, and Mixed one of the open list.
        #expect(loaded.folders?.map(\.id) == [workFolder, docsFolder, looseFolder, mixedFolder])
        #expect(loaded.folders?.map(\.parentID) == [nil, workFolder, nil, nil])
        folder.store.saveNow(loaded)
        #expect(try #require(folder.store.load()).folders?.map(\.parentID) == loaded.folders?.map(\.parentID))
    }

    /// A version 16 file, as the builds with live folders write it. Live folders were removed (`docs/bookmarks.md`, Live sources): a live folder loads as an ordinary folder in its place, also one whose configuration a later build wrote, the tabs the user put in it stay, the item tabs its source made go, the split views and the selected tab index follow the records that stay, and the file is saved without the folders' sources and the items.
    @Test func version16LiveFoldersLoadAsOrdinaryFoldersWithoutTheirItemTabs() throws {
        let folder = try SessionFolder()
        let work = TabFolder(id: workFolder, spaceID: spaceA, name: "Work", isPinned: true)
        let news = TabFolder(id: docsFolder, spaceID: spaceA, name: "News", isPinned: true, parentID: workFolder)
        let pulls = TabFolder(id: looseFolder, spaceID: spaceA, name: "Pulls", isPinned: true)
        func record(_ id: UUID, folder: UUID?, item: String?) -> SessionSnapshot.TabRecord {
            var record = SessionSnapshot.TabRecord(id: id, spaceID: spaceA, url: URL(string: "https://blog.example.org/\(id)")!, title: "Post", isPinned: true, folderID: folder)
            record.liveItemID = item
            return record
        }
        let records = [record(tab1, folder: docsFolder, item: "a"), record(tab2, folder: docsFolder, item: nil), record(tab3, folder: looseFolder, item: "b"), record(favoriteTab, folder: nil, item: nil)]
        let snapshot = SessionSnapshot(version: 16, spaces: [Space(id: spaceA, name: "A")], currentSpaceID: spaceA, favorites: [], tabs: records,
                                       folders: [work, news, pulls], selectedTabIndex: 3, splitViews: [[0, 1], [1, 3]])
        var file = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var folders = try #require(file["folders"] as? [[String: Any]])
        folders[1]["live"] = ["source": ["feed": ["address": "https://blog.example.org/feed.xml", "isPrivate": true]], "itemLimit": 10, "refreshMinutes": 60]
        // A source that a later build could add.
        folders[2]["live"] = ["source": ["laterSource": ["query": "x"]]]
        file["folders"] = folders
        file.removeValue(forKey: "windows")
        try JSONSerialization.data(withJSONObject: file).write(to: folder.store.fileURL)

        let store = folder.store
        let loaded = try #require(store.load())
        #expect(store.loadedLiveFolders)
        #expect(loaded.folders?.map(\.id) == [workFolder, docsFolder, looseFolder])
        #expect(loaded.folders?.map(\.parentID) == [nil, workFolder, nil] && loaded.folders?.allSatisfy(\.isPinned) == true)
        #expect(loaded.tabs.map(\.id) == [tab2, favoriteTab] && loaded.tabs.map(\.folderID) == [docsFolder, nil])
        #expect(loaded.tabs.allSatisfy { $0.liveItemID == nil })
        #expect(loaded.splitViews == [[0, 1]] && loaded.selectedTabIndex == 1)
        #expect(loaded.windows?.map(\.selectedTabID) == [favoriteTab])
        try store.saveNow(loaded).get()
        let saved = try folder.contents(of: "session.json")
        #expect(["live", "liveItemID"].allSatisfy { saved.range(of: Data("\"\($0)\"".utf8)) == nil })
        let next = folder.store
        #expect(try #require(next.load()).tabs.map(\.id) == [tab2, favoriteTab])
        #expect(!next.loadedLiveFolders)
    }

    @Test func version15FilesLoadWithoutLiveFolders() throws {
        let folder = try SessionFolder()
        try folder.write(version15File)
        let store = folder.store
        let loaded = try #require(store.load())
        #expect(!store.loadedLiveFolders)
        #expect(loaded.tabs.allSatisfy { $0.liveItemID == nil })
    }

    /// What runs after the next write, as the removed live folders' stored data goes, runs once, and only after a write that succeeds.
    @Test func whatRunsAfterTheNextWriteWaitsForOneThatSucceeds() throws {
        final class Runs: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int { lock.withLock { value } }
            func record() { lock.withLock { value += 1 } }
        }
        let folder = try SessionFolder()
        let store = folder.store
        let newer = version8File.replacingOccurrences(of: #""version": 8,"#, with: #""version": 99,"#)
        try folder.write(newer)
        let backup = folder.url.appendingPathComponent("session-v99.json")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        let snapshot = try #require(store.load())
        let runs = Runs()
        store.runAfterNextWrite { runs.record() }
        #expect(throws: (any Error).self) { try store.saveNow(snapshot).get() }
        #expect(runs.count == 0)
        try FileManager.default.removeItem(at: backup)
        try store.saveNow(snapshot).get()
        #expect(runs.count == 1)
        try store.saveNow(snapshot).get()
        #expect(runs.count == 1)
    }

    @Test func newerFilesLeaveACopyAndStillLoad() throws {
        let folder = try SessionFolder()
        let newer = version8File.replacingOccurrences(of: #""version": 8,"#, with: #""version": 99, "laterField": [1, 2],"#)
        try folder.write("an older copy", to: "session-v99.json")
        try folder.write(newer)
        let snapshot = try #require(folder.store.load())
        #expect(snapshot.tabs.count == 3)
        #expect(try folder.contents(of: "session-v99.json") == Data(newer.utf8))
        #expect(try folder.contents(of: "session.json") == Data(newer.utf8))
    }

    @Test func currentFilesLeaveNoCopy() throws {
        let folder = try SessionFolder()
        // A file of the version this build writes, whichever version that is.
        try folder.write(version8File.replacingOccurrences(of: #""version": 8,"#, with: #""version": \#(SessionSnapshot.currentVersion),"#))
        _ = try #require(folder.store.load())
        #expect(try folder.fileNames() == ["session.json"])
    }

    /// A directory in place of the backup makes the rename fail even on a writable volume.
    @Test func aFailedBackupPreservesTheNewerSessionUntilTheWriteCanRetry() throws {
        let folder = try SessionFolder()
        let store = folder.store
        let newer = version8File.replacingOccurrences(of: #""version": 8,"#, with: #""version": 99, "laterField": true,"#)
        try folder.write(newer)
        let backup = folder.url.appendingPathComponent("session-v99.json")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)

        var snapshot = try #require(store.load())
        snapshot.tabs.removeAll()
        #expect(throws: (any Error).self) { try store.saveNow(snapshot).get() }
        #expect(try folder.contents(of: "session.json") == Data(newer.utf8))
        #expect(try folder.fileNames() == ["session-v99.json", "session.json"])

        try FileManager.default.removeItem(at: backup)
        try store.saveNow(snapshot).get()
        #expect(try folder.contents(of: "session-v99.json") == Data(newer.utf8))
        #expect(try #require(folder.store.load()).tabs.isEmpty)
    }

    @Test func unreadableFilesMoveAside() throws {
        let folder = try SessionFolder()
        let unreadable = version8File + "x"
        try folder.write("an older unreadable file", to: "session.unreadable.json")
        try folder.write(unreadable)
        #expect(folder.store.load() == nil)
        #expect(try folder.fileNames() == ["session.unreadable.json"])
        #expect(try folder.contents(of: "session.unreadable.json") == Data(unreadable.utf8))
    }

    @Test func aFileThatCannotBeReadMovesAsideAndSavingRecovers() throws {
        let folder = try SessionFolder()
        try folder.write(version11File)
        let file = folder.url.appendingPathComponent("session.json")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let store = folder.store
        #expect(store.load() == nil)
        #expect(try folder.fileNames() == ["session.unreadable.json"])
        try store.saveNow(SessionSnapshot(spaces: [], currentSpaceID: spaceA, favorites: [], tabs: [])).get()
        #expect(try folder.fileNames() == ["session.json", "session.unreadable.json"])
    }

    @Test func aMissingFileLoadsNothing() throws {
        let folder = try SessionFolder()
        #expect(folder.store.load() == nil)
        #expect(try folder.fileNames().isEmpty)
    }

    @Test func anUnencodableSessionPreservesTheLastSaveAndANewSaveRecovers() throws {
        let folder = try SessionFolder()
        let store = folder.store
        try folder.write(version11File)
        var snapshot = try #require(store.load())
        snapshot.windows?[0].frame = CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)
        #expect(throws: (any Error).self) { try store.saveNow(snapshot).get() }
        #expect(try folder.contents(of: "session.json") == Data(version11File.utf8))
        snapshot.windows?[0].frame = nil
        try store.saveNow(snapshot).get()
        #expect(try #require(store.load()).windows?.first?.frame == nil)
    }

    @Test func theClosedListKeepsTheNewestRecordsWithoutTheirPageState() {
        let records = (0..<(SessionSnapshot.maximumClosedTabs + 5)).map { index in
            SessionSnapshot.TabRecord(id: UUID(), spaceID: spaceA, url: URL(string: "https://example.org/\(index)"), title: "Page \(index)", isPinned: false,
                                      lastActivatedAt: Date(), state: Data([1, 2]), suggestedTitle: SuggestedTitle(title: "Name", url: URL(string: "https://example.org/\(index)")!))
        }
        let snapshot = SessionSnapshot(spaces: [], currentSpaceID: spaceA, favorites: [], tabs: [], closedTabs: records).normalized()
        let closed = snapshot.closedTabs ?? []
        #expect(closed.map(\.id) == records.suffix(SessionSnapshot.maximumClosedTabs).map(\.id))
        #expect(closed.allSatisfy { $0.state == nil && $0.lastActivatedAt == nil && $0.suggestedTitle == nil })
        #expect(closed.last?.url == records.last?.url && closed.last?.title == records.last?.title)
    }

    @MainActor
    @Test func sustainedChangesCaptureTheLatestSessionBeforeTheyStop() async throws {
        let folder = try SessionFolder()
        let store = folder.store
        try folder.write(version11File)
        var snapshot = try #require(store.load())
        snapshot.tabs[0].isPinned.toggle()
        let pin = snapshot.tabs[0].isPinned
        let start = DispatchTime.now()
        var work: (deadline: DispatchTime, item: DispatchWorkItem)?
        var revision = 0
        var captured: [Int] = []
        func edit(at time: DispatchTime) {
            revision += 1
            let scheduled = revision
            snapshot.tabs[1].title = "Update \(scheduled)"
            store.scheduleSave(at: time, enqueue: { work = ($0, $1) }) {
                #expect(scheduled == revision)
                captured.append(scheduled)
                return snapshot
            }
        }

        // Edits arrive every 50 ms. The five-second callback can already be due and still waiting for main.
        for tick in 0...101 { edit(at: start + .milliseconds(tick * 50)) }
        let due = try #require(work)
        #expect(due.deadline == start + .seconds(5))
        #expect(!due.item.isCancelled)
        due.item.perform()
        #expect(captured == [102])

        let finalEdit = start + .milliseconds(5100)
        edit(at: finalEdit)
        let quiet = try #require(work)
        #expect(quiet.deadline == finalEdit + .milliseconds(500))
        let last = revision
        var wroteLast = false
        store.didWrite = { wroteLast = $0.tabs[1].title == "Update \(last)" }
        quiet.item.perform()
        let clock = ContinuousClock()
        let writeDeadline = clock.now + .seconds(5)
        while !wroteLast && clock.now < writeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(wroteLast)
        #expect(captured == [last - 1, last])
        let saved = try #require(store.load())
        #expect(saved.tabs[0].isPinned == pin && saved.tabs[1].title == "Update \(last)")
    }

    @MainActor
    @Test func aScheduledSaveWritesTheLastSnapshotAndNothingWithoutOne() async throws {
        let folder = try SessionFolder()
        try folder.write(version11File)
        let store = folder.store
        var snapshot = try #require(store.load())
        store.scheduleSave { nil }
        try await Task.sleep(for: .milliseconds(700))
        #expect(try folder.contents(of: "session.json") == Data(version11File.utf8))

        snapshot.tabs.removeLast()
        let first = snapshot
        snapshot.tabs.removeLast()
        let last = snapshot
        store.scheduleSave { first }
        store.scheduleSave { last }
        try await Task.sleep(for: .milliseconds(700))
        // The write follows on a queue of its own.
        var written = try #require(folder.store.load())
        var attempts = 0
        while written.tabs.count != last.tabs.count, attempts < 20 {
            try await Task.sleep(for: .milliseconds(50))
            written = try #require(folder.store.load())
            attempts += 1
        }
        #expect(written.tabs.map(\.id) == last.tabs.map(\.id))

        // Saving now replaces a save that is still waiting.
        store.scheduleSave { first }
        store.saveNow(snapshot)
        try await Task.sleep(for: .milliseconds(700))
        #expect(try #require(folder.store.load()).tabs.map(\.id) == last.tabs.map(\.id))
    }
}

/// A folder of its own for one test's files, removed when the test ends.
private final class SessionFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchBrowsingTests-\(UUID().uuidString)", isDirectory: true)
    /// Seals with a key of the folder's own, so that the tests never touch the Keychain.
    private let seal: SessionStateSeal = {
        let key = SymmetricKey(size: .bits256)
        return SessionStateSeal { key }
    }()
    var store: SessionStore { SessionStore(directory: url, seal: seal) }

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to name: String = "session.json") throws {
        try Data(text.utf8).write(to: url.appendingPathComponent(name))
    }

    func contents(of name: String) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent(name))
    }

    func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

private extension SessionSnapshot {
    /// The IDs of the open tabs, the favorites' tabs, and the closed tabs, in that order.
    var allTabIDs: [UUID?] {
        tabs.map(\.id) + (favoriteTabs ?? []).map(\.id) + (closedTabs ?? []).map(\.id)
    }
}

private let spaceA = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F01")!
private let spaceB = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F02")!
private let favoriteID = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F03")!
private let tab1 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F11")!
private let tab2 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F12")!
private let tab3 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F13")!
private let favoriteTab = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F14")!
private let closedTab = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F15")!
private let spaceW = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F21")!
private let spaceC = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F22")!
private let missingSpace = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F23")!
private let workFavoriteID = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F24")!
private let workPersona = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F31")!
private let homePersona = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F32")!
private let unlistedPersona = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F33")!
private let removedPersona = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F34")!
private let window1 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F41")!
private let window2 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F42")!
private let window3 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F43")!
private let window4 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F44")!
private let window5 = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F45")!
private let frontFrame = CGRect(x: 100, y: 200, width: 1000, height: 700)
private let workFolder = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F51")!
private let docsFolder = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F52")!
private let looseFolder = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F53")!
private let mixedFolder = UUID(uuidString: "6A1E0C52-3D7B-4E2A-9F10-5B8C2D4E6F54")!

/// The files without tab IDs, by version.
private let olderFiles = [1: version1File, 4: version4File, 7: version7File]

/// The files without Personas, by version.
private let filesWithoutPersonas = [1: version1File, 4: version4File, 7: version7File, 8: version8File]

/// A file without a version: no engines, page states, or home pages.
private let version1File = """
{
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "isPinned": true },
    { "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false },
    { "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false }
  ],
  "selectedTabIndex": 2,
  "closedTabs": [ { "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false } ]
}
"""

/// A version 4 file: engines, page states, a renamed tab, and a home page.
private let version4File = """
{
  "version": 4,
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue", "homeURL": "https://example.org/home" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "customTitle": "Renamed", "isPinned": true, "lastActivatedAt": 790000000, "engine": "chromium", "state": "AAE=" },
    { "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false, "lastActivatedAt": 790000100, "engine": "webKit" },
    { "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false, "lastActivatedAt": 790000200, "engine": "chromium" }
  ],
  "selectedTabIndex": 2,
  "closedTabs": [ { "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false, "engine": "webKit" } ]
}
"""

/// A version 7 file: a favorite's tab, folders, and a split view.
private let version7File = """
{
  "version": 7,
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "isPinned": true, "engine": "chromium" },
    { "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false, "engine": "chromium" },
    { "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false, "engine": "webKit" }
  ],
  "folders": [],
  "selectedTabIndex": 2,
  "closedTabs": [ { "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false, "engine": "chromium" } ],
  "splitViews": [[0, 1]],
  "favoriteTabs": [ { "favoriteID": "\(favoriteID)", "url": "https://example.com/page", "engine": "chromium" } ]
}
"""

/// A version 8 file, in which every tab record has its ID.
private let version8File = """
{
  "version": 8,
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue" },
    { "id": "\(spaceB)", "name": "Work", "symbol": "briefcase.fill", "tint": "green" }
  ],
  "currentSpaceID": "\(spaceB)",
  "favorites": [ { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" } ],
  "tabs": [
    { "id": "\(tab1)", "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "isPinned": true, "engine": "chromium" },
    { "id": "\(tab2)", "spaceID": "\(spaceA)", "url": "https://example.org/b", "title": "B", "isPinned": false, "engine": "chromium" },
    { "id": "\(tab3)", "spaceID": "\(spaceB)", "url": "https://example.org/c", "title": "C", "isPinned": false, "engine": "webKit" }
  ],
  "selectedTabIndex": 2,
  "closedTabs": [ { "id": "\(closedTab)", "spaceID": "\(spaceA)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false, "engine": "chromium" } ],
  "favoriteTabs": [ { "id": "\(favoriteTab)", "favoriteID": "\(favoriteID)", "url": "https://example.com/page", "engine": "chromium" } ]
}
"""

/// A version 9 file with three Personas, the default one second, and records that need repair: a space and a favorite of an unlisted Persona, a space and a favorite without one, an open tab whose Persona differs from its space's, an open tab whose space is gone, and closed tabs with and without a Persona.
private let version9File = """
{
  "version": 9,
  "personas": [
    { "id": "\(workPersona)", "name": "Work" },
    { "id": "\(Persona.defaultID)", "name": "Default" },
    { "id": "\(homePersona)", "name": "Home" }
  ],
  "spaces": [
    { "id": "\(spaceA)", "name": "Personal", "symbol": "circle.fill", "tint": "blue", "personaID": "\(Persona.defaultID)" },
    { "id": "\(spaceW)", "name": "Work", "symbol": "briefcase.fill", "tint": "green", "personaID": "\(workPersona)" },
    { "id": "\(spaceB)", "name": "Orphan", "symbol": "circle.fill", "tint": "pink", "personaID": "\(unlistedPersona)" },
    { "id": "\(spaceC)", "name": "Older", "symbol": "circle.fill", "tint": "teal" }
  ],
  "currentSpaceID": "\(spaceW)",
  "favorites": [
    { "id": "\(favoriteID)", "url": "https://example.com", "title": "Example" },
    { "id": "\(workFavoriteID)", "url": "https://example.net", "title": "Work", "personaID": "\(unlistedPersona)" }
  ],
  "tabs": [
    { "id": "\(tab1)", "spaceID": "\(spaceA)", "url": "https://example.org/a", "title": "A", "isPinned": true, "engine": "chromium", "personaID": "\(workPersona)" },
    { "id": "\(tab2)", "spaceID": "\(spaceW)", "url": "https://example.org/b", "title": "B", "isPinned": false, "engine": "chromium" },
    { "id": "\(tab3)", "spaceID": "\(missingSpace)", "url": "https://example.org/c", "title": "C", "isPinned": false, "engine": "webKit", "personaID": "\(homePersona)" }
  ],
  "selectedTabIndex": 1,
  "closedTabs": [
    { "id": "\(closedTab)", "spaceID": "\(spaceW)", "url": "https://example.org/closed", "title": "Closed", "isPinned": false, "engine": "chromium", "personaID": "\(homePersona)" },
    { "spaceID": "\(spaceB)", "url": "https://example.org/closed-orphan", "title": "Orphan", "isPinned": false, "engine": "chromium" },
    { "spaceID": "\(missingSpace)", "url": "https://example.org/closed-gone", "title": "Gone", "isPinned": false, "engine": "webKit" }
  ]
}
"""

/// A version 10 file: the version 9 file with Personas listed for removal, among them the default Persona, a listed Persona, and the unlisted Persona that a space still names.
private let version10File = version9File.replacingOccurrences(of: #""version": 9,"#, with: """
"version": 10,
  "removedPersonaIDs": ["\(removedPersona)", "\(Persona.defaultID)", "\(workPersona)", "\(unlistedPersona)"],
""")

/// A version 11 file: the version 8 file with five windows, front to back. The front window has a frame, a hidden sidebar, and a tab of another space. The others are on a missing space, on the front window's tab, on a favorite's tab, and on a closed tab.
private let version11File = version8File.replacingOccurrences(of: #""version": 8,"#, with: """
"version": 11,
  "windows": [
    { "id": "\(window1)", "frame": [[100, 200], [1000, 700]], "currentSpaceID": "\(spaceB)", "selectedTabID": "\(tab1)", "isSidebarVisible": false },
    { "id": "\(window2)", "currentSpaceID": "\(missingSpace)", "isSidebarVisible": true },
    { "id": "\(window3)", "currentSpaceID": "\(spaceB)", "selectedTabID": "\(tab1)", "isSidebarVisible": true },
    { "id": "\(window4)", "currentSpaceID": "\(spaceB)", "selectedTabID": "\(favoriteTab)", "isSidebarVisible": true },
    { "id": "\(window5)", "currentSpaceID": "\(spaceA)", "selectedTabID": "\(closedTab)", "isSidebarVisible": true }
  ],
""")

/// A version 12 file: the version 8 file with a suggested title for its first tab and the user's refusal of one for its second.
private let version12File = version8File
    .replacingOccurrences(of: #""version": 8,"#, with: #""version": 12,"#)
    .replacingOccurrences(of: #""title": "A", "isPinned": true,"#, with: #""title": "A", "suggestedTitle": { "title": "Example Article", "url": "https://example.org/a" }, "isPinned": true,"#)
    .replacingOccurrences(of: #""title": "B", "isPinned": false,"#, with: #""title": "B", "suggestedTitle": { "url": "https://example.org/b" }, "isPinned": false,"#)

/// A version 14 file whose pinned tab, saved at another page, and an unpinned tab carry saved pages, as do a pinned and an unpinned closed record.
private let version14File = version8File
    .replacingOccurrences(of: #""version": 8,"#, with: #""version": 14,"#)
    .replacingOccurrences(of: #""title": "A", "isPinned": true,"#, with: #""title": "A", "isPinned": true, "savedPage": { "url": "https://example.org/saved", "title": "Saved" },"#)
    .replacingOccurrences(of: #""title": "B", "isPinned": false,"#, with: #""title": "B", "isPinned": false, "savedPage": { "url": "https://example.org/stray", "title": "Stray" },"#)
    .replacingOccurrences(of: #""closedTabs": [ { "#, with: #""closedTabs": [ { "id": "\#(UUID())", "spaceID": "\#(spaceA)", "url": "https://example.org/gone", "title": "Gone", "isPinned": true, "savedPage": { "url": "https://example.org/saved", "title": "Saved" } }, { "savedPage": { "url": "https://example.org/stray", "title": "Stray" }, "#)

/// A version 14 file whose pinned tab sits in Docs, the second of two pinned folders, which have no parents before version 15.
private let version14FileWithFolders = version14File
    .replacingOccurrences(of: #""title": "A", "isPinned": true,"#, with: #""title": "A", "isPinned": true, "folderID": "\#(docsFolder)","#)
    .replacingOccurrences(of: #""selectedTabIndex": 2,"#, with: """
"folders": [
    { "id": "\(workFolder)", "spaceID": "\(spaceA)", "name": "Work", "isPinned": true, "isCollapsed": false },
    { "id": "\(docsFolder)", "spaceID": "\(spaceA)", "name": "Docs", "isPinned": true, "isCollapsed": true }
  ],
  "selectedTabIndex": 2,
""")

/// A version 15 file whose Docs folder sits in Work, beside a folder whose parent is not in the file and an open folder whose parent is a pinned one.
private let version15File = version14FileWithFolders
    .replacingOccurrences(of: #""version": 14,"#, with: #""version": 15,"#)
    .replacingOccurrences(of: #""name": "Docs", "isPinned": true, "isCollapsed": true }"#, with: """
"name": "Docs", "isPinned": true, "isCollapsed": true, "parentID": "\(workFolder)" },
    { "id": "\(looseFolder)", "spaceID": "\(spaceA)", "name": "Loose", "isPinned": true, "isCollapsed": false, "parentID": "\(UUID())" },
    { "id": "\(mixedFolder)", "spaceID": "\(spaceA)", "name": "Mixed", "isPinned": false, "isCollapsed": false, "parentID": "\(workFolder)" }
""")
