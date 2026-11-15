import ARCHEngine
@testable import Browsing
import Events
import Foundation
import LiveFolders
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

    @Test(arguments: [false, true])
    func aFreshOrUnreadableSessionKeepsKeychainItemsItsStoreDoesNotList(_ unreadable: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if unreadable { try Data("unreadable".utf8).write(to: directory.appendingPathComponent("session.json")) }

        let addresses = InMemoryLiveFolderKeychain()
        let orphan = UUID(), feed = try #require(URL(string: "https://fixture.invalid/feed?key=fixture"))
        try await addresses.setAddress(feed, for: orphan, folderName: "Local feed")
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory, addresses: addresses)
        // This write is queued after the initial registration's cleanup.
        try await session.liveFolderService.setPrivateAddress(feed, for: UUID(), folderName: "New feed")

        #expect(try await addresses.address(for: orphan) == feed)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.unreadable.json").path) == unreadable)
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

        let fallback = session.runtime(for: .chromium, in: persona.id)
        #expect(fallback.kind == .webKit)
        #expect(fallback.personaID == persona.id)
        #expect(fallback === session.runtime(for: .webKit, in: persona.id))
        #expect(session.runtime(for: .chromium, in: Persona.defaultID).kind == .chromium)
        chromium.unavailableStorageID = nil
        #expect(session.runtime(for: .chromium, in: persona.id).kind == .chromium)
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

    @Test func aNewPinStaysUnloadedWhileAnExistingPageKeepsItsCurrentAddressAndReplayClosesOnlyOnce() async throws {
        try await temporarySession { session, directory in
            let current = session.sidebarSyncState
            let space = try #require(current.spaces.first)
            let saved = SavedPage(url: URL(string: "about:blank#saved")!, title: "Saved")
            let shown = URL(string: "about:blank#current")!
            let loadedPage = PageStub(engine: .webKit, url: shown)
            let loaded = session.adopt(loadedPage, spaceID: space.id, personaID: space.resolvedPersonaID, pinned: true, select: false)
            let folder = SidebarSyncState.Folder(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Read", live: nil)
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
            let folder = SidebarSyncState.Folder(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Read", live: nil)
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

    /// A live folder that another Mac moved to another space takes its item tabs, which do not sync, and they stay its items across a save and a load.
    @Test func aLiveFolderMovedToAnotherSpaceKeepsItsItemTabs() async throws {
        try await temporarySession { session, directory in
            let home = try #require(session.spaces.first)
            let work = session.makeSpace(in: home.resolvedPersonaID, named: "Work")
            let news = TabFolder(spaceID: home.id, name: "News", isPinned: true,
                                 live: LiveFolderConfiguration(source: .feed(address: URL(string: "https://fixture.invalid/feed")!, isPrivate: false)))
            session.appendFolder(news)
            let item = session.adopt(PageStub(engine: .webKit, url: URL(string: "about:blank#item")), spaceID: home.id, personaID: home.resolvedPersonaID,
                                     pinned: true, select: false, folderID: news.id)
            item.liveItemID = "item-1"
            let state = session.sidebarSyncState
            let moved = state.folders.map { folder in
                folder.id == news.id ? SidebarSyncState.Folder(id: folder.id, personaID: folder.personaID, spaceID: work.id, parentID: nil, name: folder.name, live: folder.live) : folder
            }
            session.applySidebarSync(SidebarSyncState(personas: state.personas, spaces: state.spaces, folders: moved, favorites: state.favorites, pinnedTabs: state.pinnedTabs), deletions: .init())
            #expect(item.spaceID == work.id && item.folderID == news.id && item.liveItemID == "item-1")
            try session.saveNow().get()
            let file = try #require(SessionStore(directory: directory, seal: SessionStateSeal { nil }).load())
            let record = try #require(file.tabs.first { $0.id == item.id })
            #expect(record.spaceID == work.id && record.folderID == news.id && record.liveItemID == "item-1")
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
                                                     parentID: nil, name: oldFolder.name, live: nil)
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
            let other = SidebarSyncState.Folder(id: agent.id, personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Claimed", live: nil)
            let data = [openTab, agentTab].map { SidebarSyncState.PinnedTab(id: $0.id, personaID: space.resolvedPersonaID,
                spaceID: space.id, folderID: nil, savedPage: nil, customTitle: "Claimed", engine: .webKit) }
            let unsafe = SidebarSyncState.Folder(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, parentID: nil, name: "Private",
                live: LiveFolderConfiguration(source: .feed(address: URL(string: "https://example.test/feed?token=fixture")!, isPrivate: true)))
            let incoming = SidebarSyncState(personas: initial.personas, spaces: initial.spaces, folders: [other, unsafe], favorites: [], pinnedTabs: data)
            var removed = SidebarSyncDeletions()
            removed.folders.insert(agent.id)
            removed.tabs = [openTab.id, agentTab.id]
            session.applySidebarSync(incoming, deletions: removed)
            #expect(session.folders.contains { $0.id == agent.id && $0.name == "Agent" && $0.isAgentFolder })
            #expect(!session.folders.contains { $0.id == unsafe.id })
            #expect(session.tabs.contains { $0 === agentTab } && agentTab.folderID == agent.id && agentTab.customTitle == nil)
            #expect(session.tabs.contains { $0 === openTab } && !openTab.isPinned && !session.hasClosedTabs)
        }
    }
}
