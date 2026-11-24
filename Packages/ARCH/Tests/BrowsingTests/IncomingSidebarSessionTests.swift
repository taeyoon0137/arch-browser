import ARCHEngine
@testable import Browsing
import Events
import Foundation
import Testing

@MainActor @Suite struct IncomingSidebarSessionTests {
    private func temporarySession(_ body: (BrowserSession, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        registry.register(SessionTestEngine(kind: .chromium))
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        try await body(session, directory)
    }

    /// Counts the calls that stand in for deleting the removed live folders' Keychain items.
    private final class KeychainRemovals: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func record() { lock.withLock { calls += 1 } }
    }

    /// A version 16 file, as the builds with live folders write it: a live folder whose source made two item tabs, beside a tab the user put in it, and its stored items in `live-folders.json`. Live folders were removed (`docs/bookmarks.md`, Live sources): the folder loads as an ordinary pinned folder with the user's tab, the item tabs go, and once the session has saved, `live-folders.json` and the Keychain items go.
    @Test func aSavedLiveFolderLoadsAsAnOrdinaryFolderAndItsStoredDataGoesOnceTheSessionSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = UUID(), folder = UUID(), kept = UUID(), first = UUID(), second = UUID()
        func record(_ id: UUID, item: String?) -> SessionSnapshot.TabRecord {
            var record = SessionSnapshot.TabRecord(id: id, spaceID: space, url: URL(string: "https://fixture.invalid/\(id.uuidString)"), title: "Tab", isPinned: true, folderID: folder,
                                                   savedPage: SavedPage(url: URL(string: "https://fixture.invalid/\(id.uuidString)")!, title: "Tab"))
            record.liveItemID = item
            return record
        }
        let snapshot = SessionSnapshot(version: 16, spaces: [Space(id: space, name: "Personal")], currentSpaceID: space, favorites: [],
                                       tabs: [record(first, item: "a"), record(kept, item: nil), record(second, item: "b")],
                                       folders: [TabFolder(id: folder, spaceID: space, name: "News", isPinned: true)], splitViews: [[0, 1]])
        let text = try #require(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        let live = #""live":{"source":{"feed":{"address":"https:\/\/fixture.invalid\/feed","isPrivate":true}},"itemLimit":50},"name":"News""#
        try Data(text.replacingOccurrences(of: #""name":"News""#, with: live).utf8).write(to: directory.appendingPathComponent("session.json"))
        try Data(#"{"version":1,"folders":{}}"#.utf8).write(to: directory.appendingPathComponent("live-folders.json"))

        let removals = KeychainRemovals()
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory, removeLiveFolderKeychainItems: { removals.record() })
        #expect(session.folders.map(\.id) == [folder] && session.folders.allSatisfy(\.isPinned))
        #expect(session.tabs.map(\.id) == [kept] && session.tabs.allSatisfy { $0.folderID == folder && $0.isPinned })
        // The split view of an item tab and the user's tab has one tab left, so it goes.
        #expect(session.splitTabIDs.isEmpty)
        // Nothing goes before the session saved.
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("live-folders.json").path) && removals.count == 0)

        try session.saveNow().get()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("live-folders.json").path) && removals.count == 1)
        let saved = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        #expect([#""live""#, #""liveItemID""#].allSatisfy { saved.range(of: Data($0.utf8)) == nil })
        // Later saves remove nothing again.
        try session.saveNow().get()
        #expect(removals.count == 1)
    }

    /// Without live folders in `session.json` or a `live-folders.json`, saving touches no Keychain item; a `live-folders.json` left alone, as beside a file that did not decode, still goes.
    @Test(arguments: [false, true])
    func onlyLeftoverLiveFolderDataIsRemoved(_ leftover: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if leftover {
            try Data("unreadable".utf8).write(to: directory.appendingPathComponent("session.json"))
            try Data("{}".utf8).write(to: directory.appendingPathComponent("live-folders.unreadable.json"))
        }
        let removals = KeychainRemovals()
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory, removeLiveFolderKeychainItems: { removals.record() })
        try session.saveNow().get()
        #expect(removals.count == (leftover ? 1 : 0))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("live-folders.unreadable.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.unreadable.json").path) == leftover)
    }

    @Test func anUnavailableChromiumProfileFallsBackOnlyForThatPersonaAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = EngineRegistry(defaults: defaults)
        let chromium = SessionTestEngine(kind: .chromium)
        registry.register(chromium)
        registry.register(SessionTestEngine(kind: .webKit))
        registry.defaultKind = .chromium
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let persona = session.addPersona(named: "Work")
        chromium.unavailableStorageID = persona.id

        let fallback = try #require(session.runtime(for: .chromium, in: persona.id))
        #expect(fallback.kind == .webKit)
        #expect(fallback.personaID == persona.id)
        #expect(fallback === session.runtime(for: .webKit, in: persona.id))
        #expect(session.runtime(for: .chromium, in: Persona.defaultID)?.kind == .chromium)
        chromium.unavailableStorageID = nil
        #expect(session.runtime(for: .chromium, in: persona.id)?.kind == .chromium)
    }

    @Test func aPersonaWithoutAnyProfileKeepsItsTabsUnopenedAndDropsItsPopups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        let engine = SessionTestEngine()
        registry.register(engine)
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let persona = session.addPersona(named: "Work")
        let space = try #require(session.spaces(in: persona.id).first)
        // No engine opens a profile for the Persona, as when its folder cannot open, and a Persona that is not listed, as after a synced deletion, has none either.
        engine.unavailableStorageID = persona.id
        #expect(session.runtime(for: engine.engineKind, in: persona.id) == nil)
        #expect(session.runtime(for: engine.engineKind, in: UUID()) == nil)

        // Its tab keeps its address in a stand-in instead of stopping the app.
        let address = try #require(URL(string: "https://example.org/"))
        let tab = session.openTab(url: address, in: space.id, select: false)
        #expect(tab.webContents is UnloadedWebContents && tab.url == address && !tab.isLoaded)

        // A popup its page opens joins no list.
        let count = session.tabs.count
        let popup = UnloadedWebContents(url: address.appendingPathComponent("popup"), title: "", engine: engine.engineKind, state: nil)
        tab.openNewTab?(popup, popup.url, .newForegroundTab)
        #expect(session.tabs.count == count && !session.tabs.contains { $0.webContents === popup })

        // Once a profile opens, the Persona's pages open as before.
        engine.unavailableStorageID = nil
        #expect(session.runtime(for: engine.engineKind, in: persona.id) != nil)
    }

    @Test func aClosedPinReopensAlongsideItsReinstatedSyncRecordWithDistinctIDs() async throws {
        try await temporarySession { session, _ in
            let space = try #require(session.spaces.first)
            let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(window) }
            let saved = SavedPage(url: URL(string: "https://reader.example/saved")!, title: "Saved")
            let localURL = URL(string: "https://reader.example/chapter")!
            let tab = session.adopt(PageStub(engine: .webKit, url: localURL), spaceID: space.id, personaID: space.resolvedPersonaID, pinned: true, select: false)
            tab.savedPage = saved
            let before = session.sidebarSyncState
            let removed = SidebarSyncState(personas: before.personas, spaces: before.spaces, folders: before.folders, favorites: before.favorites, pinnedTabs: [])
            var deletions = SidebarSyncDeletions()
            deletions.tabs.insert(tab.id)
            session.applySidebarSync(removed, deletions: deletions)
            #expect(session.hasClosedTabs)
            session.applySidebarSync(before, deletions: .init())
            let reinstated = try #require(session.tabs.first)
            #expect(reinstated.id == tab.id && !reinstated.isLoaded)

            session.reopenLastClosedTab()
            let recovered = try #require(window.selectedTab)
            #expect(Set(session.tabs.map(\.id)).count == session.tabs.count)
            #expect(recovered !== reinstated && recovered.id != reinstated.id)
            #expect(recovered.url == localURL && recovered.savedPage == saved && recovered.personaID == tab.personaID)
            #expect(reinstated.id == tab.id && reinstated.savedPage == saved && !reinstated.isLoaded)
            #expect(!session.hasClosedTabs)
        }
    }

    /// An incoming folder color applies to new and existing folders; a record without a color clears it. The folder menu's Color syncs through the same path.
    @Test func anIncomingFoldersColorAppliesAndClears() async throws {
        try await temporarySession { session, directory in
            let current = session.sidebarSyncState, space = try #require(current.spaces.first)
            let folderID = UUID()
            func state(_ tint: SpaceTint?) -> SidebarSyncState {
                let folder = SidebarSyncState.Folder(id: folderID, personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Read", tint: tint)
                return .init(personas: current.personas, spaces: current.spaces, folders: [folder], favorites: [], pinnedTabs: [])
            }
            session.applySidebarSync(state(.orange), deletions: .init())
            #expect(session.folders.first { $0.id == folderID }?.tint == .orange)
            session.applySidebarSync(state(.automatic), deletions: .init())
            #expect(session.folders.first { $0.id == folderID }?.tint == .automatic)
            session.applySidebarSync(state(nil), deletions: .init())
            #expect(session.folders.first { $0.id == folderID }?.tint == nil)
            session.setTint(.green, ofFolder: folderID)
            #expect(session.sidebarSyncState.folders.map(\.tint) == [.green])
            try session.saveNow().get()
            let store = SessionStore(directory: directory, seal: SessionStateSeal { nil })
            #expect(try #require(store.load()).folders?.map(\.tint) == [.green])
            session.setTint(nil, ofFolder: folderID)
            #expect(session.sidebarSyncState.folders.map(\.tint) == [nil])
            try session.saveNow().get()
            #expect(try #require(store.load()).folders?.map(\.tint) == [nil])
        }
    }

    @Test func aNewPinStaysUnloadedWhileAnExistingPageKeepsItsCurrentAddressAndReplayClosesOnlyOnce() async throws {
        try await temporarySession { session, directory in
            let current = session.sidebarSyncState
            let space = try #require(current.spaces.first)
            let saved = SavedPage(url: URL(string: "about:blank#saved")!, title: "Saved")
            let shown = URL(string: "about:blank#current")!
            let loadedPage = PageStub(engine: .webKit, url: shown)
            let loaded = session.adopt(loadedPage, spaceID: space.id, personaID: space.resolvedPersonaID, pinned: true, select: false)
            let folder = SidebarSyncState.Folder(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Read")
            func pin(_ id: UUID, _ saved: SavedPage, engine: EngineKind = .webKit) -> SidebarSyncState.PinnedTab {
                .init(id: id, personaID: space.resolvedPersonaID, spaceID: space.id, folderID: folder.id, savedPage: saved, customTitle: nil, engine: engine)
            }
            let id = UUID()
            func state(_ pins: [SidebarSyncState.PinnedTab]) -> SidebarSyncState {
                .init(personas: current.personas, spaces: current.spaces, folders: [folder], favorites: [], pinnedTabs: pins)
            }
            let first = state([pin(loaded.id, saved), pin(id, saved)])
            session.applySidebarSync(first, deletions: .init())
            let incoming = try #require(session.tabs.first { $0.id == id })
            #expect(loaded.webContents === loadedPage && loaded.url == shown && loaded.savedPage == saved)
            #expect(!incoming.isLoaded && incoming.url == saved.url && incoming.folderID == folder.id)
            #expect(session.windows.isEmpty)
            let changed = SavedPage(url: URL(string: "about:blank#new")!, title: "New")
            let second = state([pin(id, changed, engine: .chromium), pin(loaded.id, changed)])
            session.applySidebarSync(second, deletions: .init())
            #expect(!incoming.isLoaded && incoming.engineKind == .chromium && incoming.url == changed.url)
            #expect(loaded.url == shown && loaded.savedPage == changed)
            #expect(session.sidebarSyncState.pinnedTabs.map(\.id) == [id, loaded.id])
            var removed = SidebarSyncDeletions()
            removed.tabs = [id]
            for _ in 0..<2 { session.applySidebarSync(state([pin(loaded.id, changed)]), deletions: removed) }
            #expect(session.undoableCloseCount == 1 && session.hasClosedTabs)
            try session.saveNow().get()
            let result = try #require(SessionStore(directory: directory, seal: SessionStateSeal { nil }).load())
            #expect(result.closedTabs?.compactMap(\.id) == [id])
            #expect(session.windows.isEmpty)
        }
    }

    /// A pin from another Mac joins as browser import's pins do, so no `tabOpened` posts for it and its first load is the user's; a pinned tab whose folder alone changes, which reorders nothing, still shows there at once; and unpinning drops a synced engine that waits.
    @Test func incomingPinsJoinWithoutTabOpenedAndAFolderChangePublishes() async throws {
        try await temporarySession { session, _ in
            let current = session.sidebarSyncState, space = try #require(current.spaces.first)
            var opened: [UUID] = []
            let subscription = session.events.subscribe(BrowserEventFilter()) { event in
                if case .tabOpened(let tab, _) = event.payload { opened.append(tab.id) }
            }
            defer { _ = subscription }
            let local = session.adopt(PageStub(engine: .webKit, url: URL(string: "about:blank#local")), spaceID: space.id, personaID: space.resolvedPersonaID, pinned: true, select: false)
            local.savedPage = SavedPage(url: URL(string: "about:blank#local")!, title: "Local")
            #expect(opened == [local.id])
            let folder = SidebarSyncState.Folder(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Read")
            func pin(_ id: UUID, in folderID: UUID?, _ address: String) -> SidebarSyncState.PinnedTab {
                .init(id: id, personaID: space.resolvedPersonaID, spaceID: space.id, folderID: folderID,
                      savedPage: SavedPage(url: URL(string: address)!, title: "Page"), customTitle: nil, engine: .webKit)
            }
            func state(_ pins: [SidebarSyncState.PinnedTab]) -> SidebarSyncState {
                .init(personas: current.personas, spaces: current.spaces, folders: [folder], favorites: [], pinnedTabs: pins)
            }
            let remote = UUID()
            session.applySidebarSync(state([pin(local.id, in: nil, "about:blank#local"), pin(remote, in: nil, "about:blank#remote")]), deletions: .init())
            #expect(opened == [local.id] && session.tabs.contains { $0.id == remote })
            let joined = try #require(session.tabs.first { $0.id == remote })
            #expect(!joined.isRestored && joined.recordedURL == nil)
            var published = 0
            let watch = session.objectWillChange.sink { published += 1 }
            defer { watch.cancel() }
            session.applySidebarSync(state([pin(local.id, in: folder.id, "about:blank#local"), pin(remote, in: nil, "about:blank#remote")]), deletions: .init())
            #expect(local.folderID == folder.id && published > 0)
            local.pendingSyncEngine = .chromium
            local.isPinned = false
            #expect(local.pendingSyncEngine == nil)
        }
    }

    @Test func aSelectedTabsEngineWaitsAndSurvivesASaveBeforeTheWindowHidesIt() async throws {
        try await temporarySession { session, directory in
            let state = session.sidebarSyncState, space = try #require(state.spaces.first)
            let url = URL(string: "about:blank#local")!
            let page = session.makeWebContents(url: url, engine: .webKit, state: nil, in: space.resolvedPersonaID)
            let tab = session.adopt(page, spaceID: space.id, personaID: space.resolvedPersonaID, pinned: true, select: false)
            let record = SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true)
            // Construct the supported hidden window; do not present it or take keyboard focus.
            let window = session.makeWindow(from: record, kind: .main)
            defer { session.windowWillClose(window) }
            window.selectTab(tab.id)
            let pin = SidebarSyncState.PinnedTab(id: tab.id, personaID: tab.personaID, spaceID: space.id, folderID: nil,
                                                savedPage: tab.savedPage, customTitle: nil, engine: .chromium)
            let incoming = SidebarSyncState(personas: state.personas, spaces: state.spaces, folders: [], favorites: [], pinnedTabs: [pin])
            session.applySidebarSync(incoming, deletions: .init())
            #expect(window.selectedTabID == tab.id && tab.engineKind == .webKit)
            #expect(session.sidebarSyncState.pinnedTabs.first?.engine == .chromium)
            try session.saveNow().get()
            let store = SessionStore(directory: directory, seal: SessionStateSeal { nil })
            #expect(store.load()?.tabs.first { $0.id == tab.id }?.pendingSyncEngine == .chromium)
            window.selectTab(nil)
            let deadline = ContinuousClock.now + .seconds(3)
            while tab.engineKind != .chromium && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(window.selectedTabID == nil && tab.engineKind == .chromium && tab.pendingSyncEngine == nil)
        }
    }

    /// A state that lists a Persona, space, folder, favorite, and pinned tab twice applies each once, as its first copy. Before, the first sync's apply trapped on the repeated space (`Dictionary(uniqueKeysWithValues:)`), and the pin's two copies made two tabs with one ID.
    @Test func aStateThatListsAnIDTwiceAppliesItsFirstCopy() async throws {
        try await temporarySession { session, _ in
            let original = session.sidebarSyncState
            let persona = Persona(name: "Work")
            let space = Space(name: "Room", personaID: persona.id)
            var laterSpace = space
            laterSpace.name = "Later"
            let folder = SidebarSyncState.Folder(id: UUID(), personaID: persona.id, spaceID: space.id, parentID: nil, name: "Folder")
            let favorite = Favorite(url: URL(string: "about:blank#favorite")!, title: "Favorite", personaID: persona.id)
            let pin = SidebarSyncState.PinnedTab(id: UUID(), personaID: persona.id, spaceID: space.id, folderID: folder.id,
                                                 savedPage: SavedPage(url: URL(string: "about:blank#pin")!, title: "Pin"), customTitle: nil, engine: .webKit)
            let twice = SidebarSyncState(personas: original.personas + [persona, persona], spaces: original.spaces + [space, laterSpace],
                                         folders: [folder, folder], favorites: [favorite, favorite], pinnedTabs: [pin, pin])
            session.applyFirstSidebarSync(twice, replacements: .init())
            session.applySidebarSync(twice, deletions: .init())
            #expect(session.sidebarSyncState == twice.withFirstCopies)
            #expect(session.tabs.filter { $0.id == pin.id }.count == 1 && session.spaces.filter { $0.id == space.id }.map(\.name) == ["Room"])
            #expect(session.personas.filter { $0.id == persona.id }.count == 1 && session.folders.filter { $0.id == folder.id }.count == 1)
        }
    }

    /// A `session.json` that lists a favorite twice, as a hand-edited file can, loads both, the later copy with an ID of its own (`SessionSnapshot.normalized()`), so a reorder from another Mac moves each favorite once. Before, both copies kept one ID, and the reversed order put the other favorite in two places and lost the later copy.
    @Test func aFavoriteListedTwiceInTheFileLoadsAsTwoThatASyncedReorderMovesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let first = Favorite(url: URL(string: "about:blank#first")!, title: "First", personaID: Persona.defaultID)
        let other = Favorite(url: URL(string: "about:blank#other")!, title: "Other", personaID: Persona.defaultID)
        do {
            let session = try BrowserSession(testRegistry: registry, directory: directory)
            session.addFavorites([first, other], in: Persona.defaultID)
            try session.saveNow().get()
        }
        let file = directory.appendingPathComponent("session.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var favorites = try #require(json["favorites"] as? [[String: Any]])
        var later = favorites[0]
        later["title"] = "Later"
        favorites.insert(later, at: 1)
        json["favorites"] = favorites
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let ids = session.favorites.map(\.id)
        #expect(session.favorites.map(\.title) == ["First", "Later", "Other"])
        #expect(ids.count == 3 && ids[0] == first.id && ids[2] == other.id && Set(ids).count == 3)
        let state = session.sidebarSyncState
        session.applySidebarSync(.init(personas: state.personas, spaces: state.spaces, folders: state.folders,
                                       favorites: state.favorites.reversed(), pinnedTabs: state.pinnedTabs), deletions: .init())
        #expect(session.favorites.map(\.id) == ids.reversed() && session.favorites.map(\.title) == ["Other", "Later", "First"])
    }

    @Test func firstSyncMovesLocalChildrenAndSelectionToTheMatchedIDsOnlyOnce() async throws {
        try await temporarySession { session, directory in
            let original = session.sidebarSyncState
            let oldSpace = try #require(original.spaces.first)
            let oldFolder = session.makeFolder(in: oldSpace.id, pinned: true)
            let pinPage = PageStub(engine: .webKit, url: URL(string: "about:blank#pin"))
            let pin = session.adopt(pinPage, spaceID: oldSpace.id, personaID: oldSpace.resolvedPersonaID, pinned: true, select: false, folderID: oldFolder.id)
            let open = session.adopt(PageStub(engine: .webKit, url: nil), spaceID: oldSpace.id, personaID: oldSpace.resolvedPersonaID,
                                     pinned: false, select: false, folderID: oldFolder.id)
            let favorite = Favorite(url: URL(string: "about:blank#favorite")!, title: "Local", personaID: oldSpace.resolvedPersonaID)
            session.addFavorites([favorite], in: oldSpace.resolvedPersonaID)
            let favoriteTab = session.openTab(for: favorite)
            let remoteFavorite = Favorite(url: favorite.url, title: "Remote", personaID: oldSpace.resolvedPersonaID)
            let newSpace = Space(name: oldSpace.name, personaID: oldSpace.resolvedPersonaID)
            let newFolder = SidebarSyncState.Folder(id: UUID(), personaID: oldSpace.resolvedPersonaID, spaceID: newSpace.id,
                                                     parentID: nil, name: oldFolder.name)
            let newPin = SidebarSyncState.PinnedTab(id: UUID(), personaID: oldSpace.resolvedPersonaID, spaceID: newSpace.id,
                                                     folderID: newFolder.id, savedPage: pin.savedPage, customTitle: nil, engine: .webKit)
            let state = SidebarSyncState(personas: original.personas, spaces: [newSpace], folders: [newFolder], favorites: [remoteFavorite], pinnedTabs: [newPin])
            let record = SessionSnapshot.WindowRecord(id: UUID(), frame: nil, currentSpaceID: oldSpace.id, selectedTabID: nil, isSidebarVisible: true)
            let window = session.makeWindow(from: record, kind: .main)
            defer { session.windowWillClose(window) }
            window.selectTab(pin.id)
            var replacements = SidebarSyncReplacements()
            replacements.spaces[oldSpace.id] = newSpace.id
            replacements.folders[oldFolder.id] = newFolder.id
            replacements.tabs[pin.id] = newPin.id
            replacements.favorites[favorite.id] = remoteFavorite.id
            for _ in 0..<2 { session.applyFirstSidebarSync(state, replacements: replacements) }
            #expect(session.sidebarSyncState == state)
            #expect(window.currentSpaceID == newSpace.id && window.selectedTabID == newPin.id)
            // The loaded local pin's page, with its history and input, is the server tab's now.
            #expect(session.tabs.first { $0.id == newPin.id }?.webContents === pinPage)
            #expect(open.spaceID == newSpace.id && open.folderID == newFolder.id)
            #expect(session.openTab(for: remoteFavorite) === favoriteTab)
            #expect(!session.hasClosedTabs && session.undoableCloseCount == 0)
            try session.saveNow().get()
            let stored = try #require(SessionStore(directory: directory, seal: SessionStateSeal { nil }).load())
            #expect(stored.windows?.first?.selectedTabID == newPin.id)
            #expect(stored.spaces.map(\.id) == [newSpace.id])
            #expect(stored.favoriteTabs?.first?.favoriteID == remoteFavorite.id)
        }
    }

    @Test func aSpaceTombstoneKeepsLocalOpenTabsAndAPersonaTombstoneRetainsItsClosedTabs() async throws {
        try await temporarySession { session, directory in
            let personal = try #require(session.spaces.first)
            let doomedSpace = session.makeSpace(in: personal.resolvedPersonaID, named: "Old room")
            let folder = session.makeFolder(in: doomedSpace.id, pinned: false)
            let open = session.adopt(PageStub(engine: .webKit, url: nil), spaceID: doomedSpace.id, personaID: personal.resolvedPersonaID,
                                     pinned: false, select: false, folderID: folder.id)
            let other = session.addPersona(named: "Work")
            let otherSpace = try #require(session.spaces(in: other.id).first)
            let workTab = session.adopt(PageStub(engine: .webKit, url: nil), spaceID: otherSpace.id, personaID: other.id, pinned: true, select: false)
            let state = session.sidebarSyncState
            let surviving = SidebarSyncState(personas: state.personas.filter { $0.id != other.id }, spaces: [personal],
                                             folders: [], favorites: [], pinnedTabs: [])
            var removed = SidebarSyncDeletions()
            removed.spaces = [doomedSpace.id, otherSpace.id]
            removed.personas.insert(other.id)
            for _ in 0..<2 { session.applySidebarSync(surviving, deletions: removed) }
            #expect(session.spaces.map(\.id) == [personal.id])
            #expect(open.spaceID == personal.id && open.folderID == folder.id)
            #expect(session.folders.first { $0.id == folder.id }?.spaceID == personal.id)
            try session.saveNow().get()
            let file = try #require(SessionStore(directory: directory, seal: SessionStateSeal { nil }).load())
            #expect(file.closedTabs?.compactMap(\.id) == [workTab.id])
            #expect(file.removedPersonaIDs?.contains(other.id) == true)
        }
    }

    @Test func incomingIDsCannotClaimOpenAgentOrPrivateFeedItems() async throws {
        try await temporarySession { session, _ in
            let initial = session.sidebarSyncState, space = try #require(initial.spaces.first)
            // Session-local fixtures use no configured service or network source.
            let openTab = session.adopt(PageStub(engine: .webKit, url: nil), spaceID: space.id, personaID: space.resolvedPersonaID,
                                        pinned: false, select: false)
            let agent = TabFolder(spaceID: space.id, name: "Agent", isPinned: false, agentSessionID: UUID())
            session.appendFolder(agent)
            let agentTab = session.adopt(PageStub(engine: .webKit, url: nil), spaceID: space.id, personaID: space.resolvedPersonaID,
                                         pinned: false, select: false, folderID: agent.id)
            let other = SidebarSyncState.Folder(id: agent.id, personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Claimed")
            let data = [openTab, agentTab].map { SidebarSyncState.PinnedTab(id: $0.id, personaID: space.resolvedPersonaID,
                spaceID: space.id, folderID: nil, savedPage: nil, customTitle: "Claimed", engine: .webKit) }
            let incoming = SidebarSyncState(personas: initial.personas, spaces: initial.spaces, folders: [other], favorites: [], pinnedTabs: data)
            var removed = SidebarSyncDeletions()
            removed.folders.insert(agent.id)
            removed.tabs = [openTab.id, agentTab.id]
            session.applySidebarSync(incoming, deletions: removed)
            #expect(session.folders.contains { $0.id == agent.id && $0.name == "Agent" && $0.isAgentFolder })
            #expect(session.tabs.contains { $0 === agentTab } && agentTab.folderID == agent.id && agentTab.customTitle == nil)
            // The open tab is another item, which never syncs: it takes a new ID with its page, and the pin joins under the ID (`docs/sync.md`, IDs listed twice).
            let kept = try #require(session.tabs.first { !$0.isPinned && $0.agentOwnerID == nil })
            #expect(kept.id != openTab.id && kept.customTitle == nil && !session.hasClosedTabs)
            #expect(session.tabs.contains { $0.id == openTab.id && $0.isPinned && $0.customTitle == "Claimed" })
            #expect(Set(session.allTabs.map(\.id)).count == session.allTabs.count)
        }
    }

    /// A first sync whose server folder this Mac keeps inside the local folder it matched, and which the apply leaves where it is, as when its server parent does not apply here: moving the local folder's children into the server folder would make that folder its own parent, and every walk down the sidebar's tree would recurse until the app stops. The local folder stays instead.
    @Test func aFirstSyncReplacementNeverMakesAFolderItsOwnParent() async throws {
        try await temporarySession { session, _ in
            let initial = session.sidebarSyncState, space = try #require(initial.spaces.first)
            let local = session.makeFolder(in: space.id, pinned: true)
            let server = session.makeFolder(in: space.id, pinned: true, inside: local.id)
            let incoming = SidebarSyncState(personas: initial.personas, spaces: initial.spaces,
                folders: [.init(id: server.id, personaID: space.resolvedPersonaID, spaceID: space.id, parentID: UUID(), name: server.name)],
                favorites: [], pinnedTabs: [])
            var replacements = SidebarSyncReplacements()
            replacements.folders[local.id] = server.id
            session.applyFirstSidebarSync(incoming, replacements: replacements)
            #expect(session.folders.allSatisfy { folder in !session.folderTree.ancestors(of: folder.id).contains { $0.id == folder.id } })
            #expect(session.folders.first { $0.id == server.id }?.parentID == local.id)
            #expect(session.folderTree.rows(in: space.id, pinned: true).map(\.id) == [local.id, server.id])
        }
    }

    /// A pin that sync adds with the ID of a favorite's tab saved from the last session, as when this Mac's data came from the Mac that pinned that tab, keeps its ID, and the favorite's tab takes another when it opens, so no two tabs share one.
    @Test func aFavoritesSavedTabYieldsItsIDToASyncedPin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let first = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(first.spaces.first)
        let favorite = Favorite(url: URL(string: "about:blank#favorite")!, title: "Favorite", personaID: space.resolvedPersonaID)
        first.addFavorites([favorite], in: space.resolvedPersonaID)
        let savedID = first.openTab(for: try #require(first.favorites.first)).id
        try first.saveNow().get()
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let state = session.sidebarSyncState
        let pin = SidebarSyncState.PinnedTab(id: savedID, personaID: space.resolvedPersonaID, spaceID: space.id, folderID: nil,
                                             savedPage: SavedPage(url: URL(string: "about:blank#pin")!, title: "Pin"), customTitle: nil, engine: .webKit)
        session.applySidebarSync(.init(personas: state.personas, spaces: state.spaces, folders: [], favorites: state.favorites, pinnedTabs: [pin]), deletions: .init())
        let opened = session.openTab(for: try #require(session.favorites.first))
        #expect(session.tabs.contains { $0.id == savedID && $0.isPinned } && opened.id != savedID)
        #expect(Set(session.allTabs.map(\.id)).count == session.allTabs.count)
    }
}
