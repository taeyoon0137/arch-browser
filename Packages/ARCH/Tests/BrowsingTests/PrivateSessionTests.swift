// Private sessions exercise fake engines only; no native window, engine process, or page is launched.
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct PrivateSessionTests {
    private func fixture(_ body: (BrowserSession, SessionTestEngine, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPrivateSessionTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = SessionTestEngine()
        let registry = EngineRegistry()
        registry.register(engine)
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        try await body(session, engine, directory)
        for window in session.windows where window.isPrivate { session.windowWillClose(window) }
    }

    @Test func eachPrivateWindowUsesItsOwnEphemeralContextWithoutAPersonaOrSpace() async throws {
        try await fixture { session, engine, _ in
            let personaIDs = session.personas.map(\.id)
            let spaceIDs = session.spaces.map(\.id)
            let persistentRequests = engine.persistentStorageIDs.count
            let first = session.makePrivateWindow()
            let second = session.makePrivateWindow()
            #expect(first.nsWindow == nil && second.nsWindow == nil)
            let a = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/a"), in: first))
            let b = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/b"), in: first))
            let c = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/c"), in: second))
            #expect(a.isPrivate && b.isPrivate && c.isPrivate)
            #expect(a.spaceID == nil && a.folderID == nil && !a.isPinned)
            #expect(session.personas.map(\.id) == personaIDs && session.spaces.map(\.id) == spaceIDs)
            #expect(!personaIDs.contains(a.personaID))
            #expect(engine.ephemeralContextCount == 2)
            #expect(engine.persistentStorageIDs.count == persistentRequests)
            #expect(session.runtime(of: a)?.context === session.runtime(of: b)?.context)
            #expect(session.runtime(of: a)?.context !== session.runtime(of: c)?.context)
            #expect(first.recentTabs.allSatisfy { $0.privateSessionID == first.privateSessionID })
            first.selectTab(c.id)
            #expect(first.selectedTabID != c.id)
            session.moveTab(a.id, toSpace: spaceIDs[0])
            #expect(a.spaceID == nil && a.isPrivate)
        }
    }

    @Test func userTabsAndDifferentAgentsNeverSharePrivateStorage() async throws {
        try await fixture { session, engine, _ in
            let owner = UUID()
            let window = session.makePrivateWindow(ownerID: owner)
            let owned = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/agent"), in: window, ownerID: owner))
            let user = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/user"), in: window))
            let other = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/other"), in: window, ownerID: UUID()))
            #expect(owned.agentOwnerID == owner && user.agentOwnerID == nil)
            #expect(owned.privateSessionID != user.privateSessionID && owned.privateSessionID != other.privateSessionID)
            #expect(session.runtime(of: owned)?.context !== session.runtime(of: user)?.context)
            #expect(session.runtime(of: owned)?.context !== session.runtime(of: other)?.context)
            #expect(engine.ephemeralContextCount == 3)
            #expect(session.windows.allSatisfy { $0.nsWindow == nil })
            #expect(window.privateTabs.map(\.id) == [owned.id])
        }
    }

    @Test func privateVisitsAndWindowsNeverEnterHistoryRestoreSyncOrEvents() async throws {
        try await fixture { session, _, directory in
            let initialSync = session.sidebarSyncState
            var events: [BrowserEvent] = []
            let subscription = session.events.subscribe(BrowserEventFilter(tabKinds: Set(BrowserTabKind.allCases))) { events.append($0) }
            defer { subscription.cancel() }
            let window = session.makePrivateWindow()
            let address = try #require(URL(string: "https://private.invalid/secret"))
            let tab = try #require(session.openPrivateTab(url: address, in: window))
            let page = try #require(tab.webContents as? PageDouble)
            page.load(address, in: tab)
            tab.webContents(page, didCommitDocumentAt: address)
            tab.webContentsDidFinishLoadingDocument(page)
            tab.recordVisit?(address, "Private title")
            session.history.finishWrites()
            #expect(await session.history.suggestions(for: "private.invalid", limit: 10, in: tab.personaID).isEmpty)
            #expect(await session.history.suggestions(for: "private.invalid", limit: 10, in: Persona.defaultID).isEmpty)
            #expect(session.sidebarSyncState == initialSync)
            #expect(events.isEmpty)
            #expect(SessionSnapshot.keptSidebar(tabs: [tab], folders: []).tabs.isEmpty)
            try session.saveNow().get()
            let saved = try String(contentsOf: directory.appendingPathComponent("session.json"), encoding: .utf8)
            for secret in [address.absoluteString, tab.id.uuidString, window.id.uuidString, tab.personaID.uuidString] {
                #expect(!saved.contains(secret))
            }
            let snapshot = try #require(SessionStore(directory: directory, seal: .fixture).load())
            #expect(snapshot.tabs.isEmpty)
            #expect(snapshot.windows?.contains { $0.id == window.id } != true)
            #expect(session.closeTab(tab))
            #expect(session.undoableCloseCount == 0)
            #expect(session.closeLog.entries.isEmpty)
            #expect(events.isEmpty)
        }
    }

    @Test func privateDownloadsStayOutOfTheLibraryAndReleaseTheirContextOnClose() async throws {
        try await fixture { session, _, directory in
            let window = session.makePrivateWindow()
            let tab = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/"), in: window))
            weak var releasedContext: AnyObject?
            let active = PrivateDownload()
            let completed = PrivateDownload()
            let savedFile = directory.appendingPathComponent("saved.txt")
            try Data("saved".utf8).write(to: savedFile)
            completed.targetPath = savedFile
            do {
                let context = try #require(session.runtime(of: tab)?.context)
                releasedContext = context as AnyObject
                context.downloads.delegate?.downloads(context.downloads, didCreate: active)
                context.downloads.delegate?.downloads(context.downloads, didCreate: completed)
                completed.state = .completed
                context.downloads.delegate?.downloads(context.downloads, didUpdate: completed)
            }
            #expect(session.downloads.isEmpty && session.unseenDownloadIDs.isEmpty)
            session.windowWillClose(window)
            #expect(session.allTabs.allSatisfy { !$0.isPrivate })
            #expect(active.state == .cancelled)
            #expect(completed.state == .completed)
            #expect(try Data(contentsOf: savedFile) == Data("saved".utf8))
            #expect(releasedContext == nil)
        }
    }

    @Test func unavailableEphemeralStorageNeverOpensAPersistentProfile() async throws {
        try await fixture { session, engine, _ in
            let requests = engine.persistentStorageIDs.count
            engine.ephemeralStorageUnavailable = true
            let window = session.makePrivateWindow()
            let tab = try #require(session.openPrivateTab(url: URL(string: "https://private.invalid/"), in: window))
            #expect(tab.isPrivate && !tab.isLoaded)
            #expect(engine.persistentStorageIDs.count == requests)
            #expect(session.runtime(of: tab) == nil)
        }
    }

    @Test func privatePermissionAnswersNeverEnterThePersonaStore() async throws {
        try await fixture { session, _, directory in
            let window = session.makePrivateWindow()
            let address = try #require(URL(string: "https://private.invalid/"))
            let tab = try #require(session.openPrivateTab(url: address, in: window))
            let before = session.sitePermissions.answers
            var granted: Bool?
            tab.requestPermission?(EnginePermissionRequest(origin: address, types: [.camera])) { granted = $0 }
            let prompt = try #require(session.prompts.current(for: tab.id))
            session.prompts.answer(prompt.id, with: PromptAnswer(buttonID: "allow"))
            #expect(granted == true)
            #expect(session.sitePermissions.answers == before)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("permissions.json").path))
        }
    }

    private final class PrivateDownload: EngineDownloadItem {
        let sourceURL = URL(string: "https://private.invalid/file")!
        let pageURL: URL? = nil
        let webContents: (any EngineWebContents)? = nil
        var targetPath: URL?
        var state: EngineDownloadState = .inProgress
        let completedBytes: Int64 = 0
        let totalBytes: Int64 = 0
        func pause() { state = .paused }
        func resume() { state = .inProgress }
        func cancel() { state = .cancelled }
        func remove() {}
    }
}
