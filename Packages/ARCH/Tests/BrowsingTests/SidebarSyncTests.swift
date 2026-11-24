import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@MainActor @Suite struct SidebarSyncTests {
    private let space = Space(name: "Personal", personaID: Persona.defaultID)
    private let page = URL(string: "https://example.test/saved")!
    private func snapshot(_ tabs: [Tab] = [], folders: [TabFolder] = []) -> SessionSnapshot {
        let kept = SessionSnapshot.keptSidebar(tabs: tabs, folders: folders)
        return SessionSnapshot(personas: [Persona(id: Persona.defaultID, name: "Personal")],
            spaces: [space], currentSpaceID: space.id, favorites: [],
            tabs: kept.tabs.map { SessionSnapshot.TabRecord($0, spaceID: space.id, lastActivatedAt: .distantPast) }, folders: kept.folders)
    }
    private func state(_ snapshot: SessionSnapshot) -> SidebarSyncState {
        SidebarSyncState(snapshot: snapshot, defaultEngine: .webKit)
    }

    @Test func navigationChangesNoSyncableValueUntilItBecomesTheSavedPage() {
        let view = PageStub(engine: .webKit, url: page)
        let tab = Tab(id: UUID(), webContents: view, spaceID: space.id, isPinned: false, personaID: Persona.defaultID)
        view.report(url: page, title: "Saved")
        tab.isPinned = true
        let initial = state(snapshot([tab]))
        let nextPage = URL(string: "https://example.test/current")!
        view.report(url: nextPage, title: "Different")
        #expect(state(snapshot([tab])) == initial)
        #expect(initial.pinnedTabs.first?.savedPage == SavedPage(url: page, title: "Saved"))
        tab.useCurrentPageAsSavedPage()
        #expect(state(snapshot([tab])).pinnedTabs.first?.savedPage == SavedPage(url: nextPage, title: "Different"))
        tab.isPinned = false
        #expect(state(snapshot([tab])).pinnedTabs.isEmpty)
    }

    /// A snapshot that lists a space, folder, or favorite twice, which a loaded session never does (`SessionSnapshot.normalized()`), still syncs each ID once, as its first copy, so the first-sync plan and the sync apply never meet an ID twice.
    @Test func anItemListedTwiceEntersOnceAsItsFirstCopy() {
        let folder = TabFolder(spaceID: space.id, name: "First", isPinned: true)
        var laterFolder = folder
        laterFolder.name = "Later"
        let favorite = Favorite(url: page, title: "First", personaID: Persona.defaultID)
        var laterFavorite = favorite
        laterFavorite.title = "Later"
        var laterSpace = space
        laterSpace.name = "Later"
        var saved = snapshot(folders: [folder, laterFolder])
        saved.spaces = [space, laterSpace]
        saved.favorites = [favorite, laterFavorite]
        let result = state(saved)
        #expect(result.spaces.map(\.name) == ["Personal"] && result.folders.map(\.name) == ["First"] && result.favorites.map(\.title) == ["First"])
        #expect(result.withFirstCopies == result)
    }

    @Test func restoringOlderSnapshotsKeepsOpenFoldersAndAgentTabsLocal() throws {
        let agent = TabFolder(spaceID: space.id, name: "Agent", isPinned: false, agentSessionID: UUID())
        let ordinary = TabFolder(spaceID: space.id, name: "Pinned", isPinned: true)
        let open = TabFolder(spaceID: space.id, name: "Open", isPinned: false)
        let folders = [ordinary, open, agent]
        let tabs = folders.map { folder in
            let tab = Tab(id: UUID(), webContents: PageStub(engine: .webKit, url: page), spaceID: space.id,
                          isPinned: folder.isPinned, personaID: Persona.defaultID)
            tab.folderID = folder.id
            return tab
        }
        var saved = snapshot(tabs, folders: folders)
        saved.version = 15
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(saved)).normalized()
        let result = state(restored)
        #expect(result.folders.map(\.id) == [ordinary.id])
        #expect(result.pinnedTabs.map(\.id) == [tabs[0].id])
    }

    @Test func aFolderCrossingTheDividerSavesItsContentsAndUpdatesTheSyncableSidebar() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let firstPin = session.makeFolder(in: space.id, pinned: true)
        let lastPin = session.makeFolder(in: space.id, pinned: true)
        let firstOpen = session.makeFolder(in: space.id, pinned: false)
        let lastOpen = session.makeFolder(in: space.id, pinned: false)
        let outer = session.makeFolder(in: space.id, pinned: false)
        let inner = session.makeFolder(in: space.id, pinned: false, inside: outer.id)
        let a = session.openTab(url: page.appendingPathComponent("a"), in: space.id, select: false)
        let b = session.openTab(url: page.appendingPathComponent("b"), in: space.id, select: false)
        let c = session.openTab(url: page.appendingPathComponent("c"), in: space.id, select: false)
        session.moveTab(a.id, toFolder: outer.id)
        session.moveTab(b.id, toFolder: inner.id)
        session.moveTab(c.id, toFolder: inner.id)
        let pages = [a.webContents, b.webContents, c.webContents]
        let tabOrder = session.tabs.map(\.id)
        var observed: [SidebarSyncState] = []
        session.onSidebarSyncSave = { observed.append($0) }
        defer { session.onSidebarSyncSave = nil }

        let pin = try #require(session.folderTree.dropTarget(for: outer.id, at: .aboveFolder(lastPin.id)))
        session.moveFolder(outer.id, to: pin)
        #expect(session.folderTree.topFolders(in: space.id, pinned: true).map(\.id) == [firstPin.id, outer.id, lastPin.id])
        #expect(session.folderTree.folder(inner.id)?.parentID == outer.id)
        #expect([outer.id, inner.id].allSatisfy { session.folderTree.folder($0)?.isPinned == true })
        #expect([a, b, c].allSatisfy { $0.isPinned && $0.savedPage?.url == $0.url })
        #expect([a.folderID, b.folderID, c.folderID] == [outer.id, inner.id, inner.id])
        #expect(session.tabs.map(\.id) == tabOrder)
        try session.saveNow().get()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        let pinned = try #require(observed.last)
        #expect(pinned.folders.filter { $0.parentID == nil }.map(\.id) == [firstPin.id, outer.id, lastPin.id])
        #expect(pinned.folders.first { $0.id == inner.id }?.parentID == outer.id)
        #expect(pinned.pinnedTabs.map(\.id) == [a.id, b.id, c.id])
        #expect(pinned.pinnedTabs.map(\.folderID) == [outer.id, inner.id, inner.id])

        let unpin = try #require(session.folderTree.dropTarget(for: outer.id, at: .aboveFolder(lastOpen.id)))
        session.moveFolder(outer.id, to: unpin)
        #expect(session.folderTree.topFolders(in: space.id, pinned: false).map(\.id) == [firstOpen.id, outer.id, lastOpen.id])
        #expect([outer.id, inner.id].allSatisfy { session.folderTree.folder($0)?.isPinned == false })
        #expect([a, b, c].allSatisfy { !$0.isPinned && $0.savedPage == nil })
        #expect([a.folderID, b.folderID, c.folderID] == [outer.id, inner.id, inner.id])
        #expect(session.tabs.map(\.id) == tabOrder)
        #expect(a.webContents === pages[0] && b.webContents === pages[1] && c.webContents === pages[2])
        try session.saveNow().get()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        let unpinned = try #require(observed.last)
        #expect(observed.count == 2)
        #expect(unpinned.folders.map(\.id) == [firstPin.id, lastPin.id] && unpinned.pinnedTabs.isEmpty)

        let saved = try #require(SessionStore(directory: directory, seal: .fixture).load())
        #expect(saved.folders?.filter { !$0.isPinned && $0.parentID == nil }.map(\.id) == [firstOpen.id, outer.id, lastOpen.id])
        #expect(saved.folders?.first { $0.id == inner.id }?.parentID == outer.id)
        #expect(saved.tabs.map(\.id) == tabOrder.map(Optional.some))
        #expect(saved.tabs.allSatisfy { !$0.isPinned && $0.savedPage == nil })
        #expect(saved.tabs.map(\.folderID) == [outer.id, inner.id, inner.id])
    }

    @Test func successfulWritesDeliverCapturedStatesInFileOrderAndFailuresDeliverNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory, seal: SessionStateSeal { nil })
        var first = snapshot()
        first.spaces[0].name = "First"
        var second = first
        second.spaces[0].name = "Second"
        var observed: [String] = []
        store.didWrite = { observed.append($0.spaces[0].name) }
        // Schedule the next flush on main from the first capture. It runs before the first write's
        // main-queue notification and waits on that write, so both notifications must be ordered.
        await withCheckedContinuation { done in
            store.scheduleSave {
                DispatchQueue.main.async {
                    #expect((try? store.saveNow(second).get()) != nil)
                    DispatchQueue.main.async { done.resume() }
                }
                return first
            }
        }
        #expect(observed == ["First", "Second"])
        #expect(store.load()?.spaces.first?.name == "Second")

        // Leave a directory where the atomic rename expects a file.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        if case .success = store.saveNow(first) { Issue.record("The invalid destination accepted the write") }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(observed == ["First", "Second"])
        try FileManager.default.removeItem(at: store.fileURL)
        try store.saveNow(first).get()
        store.didWrite = { _ in Issue.record("A previous observer's capture reached its replacement") }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(observed == ["First", "Second"])
        #expect(store.load()?.spaces.first?.name == "First")
    }
}
