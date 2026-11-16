import ARCHEngine
@testable import Browsing
import Foundation
import LiveFolders
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

    @Test func restoringOlderSnapshotsKeepsPrivateFeedsTheirItemsAndAgentTabsLocal() throws {
        let publicFeed = TabFolder(spaceID: space.id, name: "News", isPinned: true,
            live: LiveFolderConfiguration(source: .feed(address: page, isPrivate: false)))
        let secretFeed = TabFolder(spaceID: space.id, name: "Private", isPinned: true,
            live: LiveFolderConfiguration(source: .feed(address: page, isPrivate: true)))
        let legacyFeed = TabFolder(spaceID: space.id, name: "Unmarked", isPinned: true,
            live: LiveFolderConfiguration(source: .feed(address: URL(string: "https://example.test/feed?private=fixture")!, isPrivate: false)))
        let agent = TabFolder(spaceID: space.id, name: "Agent", isPinned: false, agentSessionID: UUID())
        let ordinary = TabFolder(spaceID: space.id, name: "Pinned", isPinned: true)
        let open = TabFolder(spaceID: space.id, name: "Open", isPinned: false)
        let folders = [ordinary, open, publicFeed, secretFeed, legacyFeed, agent]
        let tabs = folders.map { folder in
            let tab = Tab(id: UUID(), webContents: PageStub(engine: .webKit, url: page), spaceID: space.id,
                          isPinned: folder.isPinned, personaID: Persona.defaultID)
            tab.folderID = folder.id
            if folder.live != nil { tab.liveItemID = "fixture-item" }
            return tab
        }
        var saved = snapshot(tabs, folders: folders)
        saved.version = 15
        let restored = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(saved)).normalized()
        let result = state(restored)
        #expect(result.folders.map(\.id) == [ordinary.id, publicFeed.id])
        #expect(result.pinnedTabs.map(\.id) == [tabs[0].id])
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
