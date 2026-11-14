import ARCHEngine
@testable import Browsing
import CloudKit
import Foundation
import Testing
@testable import Sync

@MainActor @Suite struct TwoMacRecoveryTests {
    /// Two independent controllers share only this zone's records and change history.
    /// The token belongs to each fake engine. An absent token requests the complete zone.
    @MainActor private final class Zone {
        let database = SyncDatabase(containerIdentifier: "fixture.two-macs", environment: "Test")
        var records: [String: CKRecord] = [:]
        var pages: [SyncFetchedChanges] = []

        func accept(_ batch: FakeSyncEngine.Batch) {
            var page = SyncFetchedChanges(records: batch.records)
            for record in batch.records { records[record.recordID.recordName] = record }
            for name in batch.deletedRecordNames {
                if let old = records.removeValue(forKey: name) {
                    page.deletions.append(.init(recordID: old.recordID, recordType: old.recordType))
                }
            }
            pages.append(page)
        }
    }

    /// This test never opens a page. Restored pins remain unloaded and use about: addresses.
    private final class NoPages: Engine, EngineApplication, EngineBrowserContext, EngineBrowser {
        let kind: EngineKind = .webKit
        var engineKind: EngineKind { kind }
        let capabilities: Set<EngineCapability> = []
        let extensionRuntimeVersion: String? = nil
        weak var delegate: (any EngineApplicationDelegate)?
        func makeApplication(configuration: EngineApplicationConfiguration) throws -> any EngineApplication { self }
        func removeStoredData(forStorage identifier: UUID, configuration: EngineApplicationConfiguration, completion: @escaping (Bool) -> Void) { completion(true) }
        func createBrowserContext(storageIdentifier: UUID?, completion: @escaping (Result<any EngineBrowserContext, Error>) -> Void) { completion(.success(self)) }
        func createBrowser(context: any EngineBrowserContext) -> any EngineBrowser { self }
        var preferences = EnginePreferences()
        let extensions: (any EngineExtensions)? = nil
        var downloads: any EngineDownloads { Downloads() }
        private final class Downloads: EngineDownloads {
            weak var delegate: (any EngineDownloadsDelegate)?
            let items: [any EngineDownloadItem] = []
        }
        var cookiesDidChange: (() -> Void)?
        func createWebContents(_ configuration: EngineWebContentsConfiguration) -> any EngineWebContents {
            UnloadedWebContents(url: configuration.initialURL, title: "", engine: .webKit, state: nil)
        }
        func closeAllWebContents() {}
        func closeWebContents(_ webContents: any EngineWebContents) {}
        func takeOwnership(of webContents: any EngineWebContents) {}
        func allCookies(completion: @escaping ([EngineCookie]) -> Void) { completion([]) }
        func setCookies(_ cookies: [EngineCookie], completion: @escaping () -> Void) { completion() }
        func removeCookies(where predicate: @escaping (EngineCookie) -> Bool, completion: @escaping () -> Void) { completion() }
        func removeSiteData(for origins: [URL], completion: @escaping () -> Void) { completion() }
    }

    @MainActor private final class Mac {
        let name = UUID().uuidString
        let directory: URL
        let defaults: UserDefaults
        let zone: Zone
        var session: BrowserSession!
        var controller: SyncController!
        var engine: FakeSyncEngine!
        var firstFetches = 0

        init(zone: Zone) throws {
            self.zone = zone
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            defaults = UserDefaults(suiteName: name)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Suppress live-folder credential cleanup in this synthetic profile.
            try Data().write(to: directory.appendingPathComponent("session.unreadable.json"))
            try launch()
        }
        var file: URL { directory.appendingPathComponent("session.json") }
        var syncFile: URL { directory.appendingPathComponent("sync.json") }
        func launch() throws {
            controller = nil
            engine = nil
            session = nil
            let registry = EngineRegistry(defaults: defaults)
            registry.register(NoPages())
            session = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil)
            let target = zone.database
            controller = SyncController(sidebar: session, directory: directory, defaults: defaults, check: { .available(target) },
                factory: FakeSyncEngine.factory { [unowned self] engine in
                    self.engine = engine
                    var cursor = engine.startedFrom.flatMap { try? JSONDecoder().decode(Int.self, from: $0) }
                    engine.onFetch = { [unowned self, unowned engine] in
                        let changes: [SyncFetchedChanges]
                        if let cursor { changes = Array(zone.pages.dropFirst(cursor)) }
                        else {
                            firstFetches += 1
                            changes = [.init(records: Array(zone.records.values))]
                        }
                        cursor = zone.pages.count
                        engine.fetchToken = try? JSONEncoder().encode(cursor)
                        return changes.map(SyncEvent.fetchedChanges)
                    }
                    engine.onSavedBatch = { [unowned self] batch in zone.accept(batch) }
                })
        }
        func flush() async throws {
            try session.saveNow().get()
            await withCheckedContinuation { completion in DispatchQueue.main.async { completion.resume() } }
            try await engine.sendChanges()
        }
        func clean() {
            defaults.removePersistentDomain(forName: name)
            controller = nil
            session = nil
            engine = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test(arguments: [false, true]) func losingOneSessionFileCannotDeleteTheOtherMacsGroupsAndBookmarks(missing: Bool) async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let space = try #require(a.session.spaces.first)
        let folder = a.session.makeFolder(in: space.id, pinned: true)
        let item = Favorite(url: URL(string: "about:blank#kept")!, title: "Imported", personaID: space.resolvedPersonaID)
        a.session.addFavorites([item], in: space.resolvedPersonaID)
        let pin = SidebarSyncState.PinnedTab(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, folderID: folder.id,
                                            savedPage: .init(url: URL(string: "about:blank#pin")!, title: "Saved page"), customTitle: nil, engine: .webKit)
        let local = a.session.sidebarSyncState
        a.session.applySidebarSync(.init(personas: local.personas, spaces: local.spaces, folders: local.folders,
                                          favorites: local.favorites, pinnedTabs: [pin]), deletions: .init())
        await a.controller.setEnabled(true)
        try await a.flush()
        await b.controller.setEnabled(true)
        try await b.flush()
        let expected = a.session.sidebarSyncState
        #expect(b.session.sidebarSyncState == expected && zone.records.count == 5)
        await b.controller.refresh()
        try await b.flush()
        // Leave the good mirror and its token behind, exactly as after a damaged local session.
        if missing { try FileManager.default.removeItem(at: b.file) }
        else { try Data("damaged".utf8).write(to: b.file) }
        try b.launch()
        let recovered = Favorite(url: URL(string: "about:blank#new")!, title: "Added during recovery", personaID: Persona.defaultID)
        b.session.addFavorites([recovered], in: Persona.defaultID)
        // The fallback may already have been autosaved when the app restarts offline.
        try b.session.saveNow().get()
        try b.launch()
        #expect(b.session.needsFullSidebarSync)
        await b.controller.refreshIfRequested()
        try await b.flush()
        #expect(b.session.sidebarSyncState.folders == expected.folders && b.session.sidebarSyncState.pinnedTabs == expected.pinnedTabs)
        #expect(Set(b.session.favorites.map(\.id)) == [item.id, recovered.id])
        #expect(b.firstFetches == 2 && !b.session.needsFullSidebarSync)
        #expect(zone.records[pin.id.uuidString] != nil && zone.records[item.id.uuidString] != nil && zone.records[folder.id.uuidString] != nil)
        await a.controller.refresh()
        #expect(a.session.sidebarSyncState == b.session.sidebarSyncState)
    }
    @Test func offlinePinEditLosesToDeletionAfterFailedDiskWriteAndRelaunch() async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let initial = a.session.sidebarSyncState, space = try #require(initial.spaces.first)
        let favorite = Favorite(url: URL(string: "about:blank#keep")!, title: "Keep", personaID: space.resolvedPersonaID)
        let pin = SidebarSyncState.PinnedTab(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, folderID: nil,
                                             savedPage: SavedPage(url: URL(string: "about:blank#old")!, title: "Old"), customTitle: nil, engine: .webKit)
        a.session.applySidebarSync(.init(personas: initial.personas, spaces: initial.spaces, folders: [], favorites: [favorite], pinnedTabs: [pin]),
                                   deletions: .init())
        await a.controller.setEnabled(true)
        try await a.flush()
        await b.controller.setEnabled(true)
        try await b.flush()
        let onB = try #require(b.session.tabs.first { $0.id == pin.id })
        onB.customTitle = "Edited offline"
        try b.session.saveNow().get()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(b.engine.pendingChanges.contains(.saveRecord(pin.id.uuidString)))
        let preFetch = try Data(contentsOf: b.syncFile)
        let disk = try Data(contentsOf: b.file)
        let onA = try #require(a.session.tabs.first { $0.id == pin.id })
        a.session.togglePinned(onA)
        try await a.flush()
        #expect(zone.records[pin.id.uuidString] == nil)
        // A directory at the old file name forces the session's atomic rename to fail.
        try FileManager.default.removeItem(at: b.file)
        try FileManager.default.createDirectory(at: b.file, withIntermediateDirectories: false)
        await b.controller.refresh()
        #expect(!b.controller.canSendRecords && b.controller.lastError != nil)
        #expect(try Data(contentsOf: b.syncFile) == preFetch)
        try FileManager.default.removeItem(at: b.file)
        try disk.write(to: b.file)
        try b.launch()
        #expect(b.session.tabs.first { $0.id == pin.id }?.customTitle == "Edited offline")
        await b.controller.refreshIfRequested()
        try await b.flush()
        #expect(b.controller.canSendRecords && b.session.sidebarSyncState.pinnedTabs.isEmpty)
        #expect(zone.records[pin.id.uuidString] == nil && zone.records[favorite.id.uuidString] != nil)
        #expect(b.firstFetches == 1 && b.session.undoableCloseCount == 1)
        await a.controller.refresh()
        #expect(a.session.tabs.contains { $0.id == pin.id && !$0.isPinned })
        #expect(a.session.sidebarSyncState.favorites.map(\.id) == [favorite.id])
    }
}
