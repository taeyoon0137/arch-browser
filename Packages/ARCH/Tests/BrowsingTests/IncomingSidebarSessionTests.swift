import ARCHEngine
@testable import Browsing
import Foundation
import LiveFolders
import Testing

@MainActor @Suite struct IncomingSidebarSessionTests {
    private func temporarySession(_ body: (BrowserSession, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("session.unreadable.json"))
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        registry.register(SessionTestEngine(kind: .chromium))
        let session = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil)
        try await body(session, directory)
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
