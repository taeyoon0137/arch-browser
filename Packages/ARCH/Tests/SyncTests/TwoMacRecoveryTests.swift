import ARCHEngine
@testable import Browsing
import CloudKit
import Foundation
import LiveFolders
import Testing
@testable import Sync

@MainActor @Suite struct TwoMacRecoveryTests {
    /// Two independent controllers share only this zone's records and change history.
    /// The token belongs to each fake engine. An absent token requests the complete zone.
    @MainActor private final class Zone {
        let database = SyncDatabase(containerIdentifier: "fixture.two-macs", environment: "Test")
        var records: [String: CKRecord] = [:]
        var pages: [SyncFetchedChanges] = []
        /// Each fetch brings every record twice, as a server that held a record twice would.
        var bringsRecordsTwice = false

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
        private let addresses = InMemoryLiveFolderKeychain()
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
            session = try BrowserSession(registry: registry, userDataDirectory: directory, builtInPlugins: [], cefVersion: nil,
                                         sessionSeal: SessionStateSeal { nil }, liveFolderAddresses: addresses)
            let target = zone.database
            controller = SyncController(sidebar: session, directory: directory, defaults: defaults, check: { .available(target) },
                factory: FakeSyncEngine.factory { [unowned self] engine in
                    self.engine = engine
                    var cursor = engine.startedFrom.flatMap { try? JSONDecoder().decode(Int.self, from: $0) }
                    engine.onFetch = { [unowned self, unowned engine] in
                        var changes: [SyncFetchedChanges]
                        if let cursor { changes = Array(zone.pages.dropFirst(cursor)) }
                        else {
                            firstFetches += 1
                            changes = [.init(records: Array(zone.records.values))]
                        }
                        if zone.bringsRecordsTwice { changes = changes.map { .init(records: $0.records + $0.records, deletions: $0.deletions) } }
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

    /// Puts a second Persona, a pinned folder with a pinned tab of `page` in it, and a favorite in the Mac's sidebar, as a Mac in use has them.
    private func fill(_ mac: Mac, page: String) throws -> (folder: TabFolder, pin: SidebarSyncState.PinnedTab, favorite: Favorite) {
        _ = mac.session.addPersona(named: "Work")
        let space = try #require(mac.session.spaces.first { $0.resolvedPersonaID == Persona.defaultID })
        let folder = mac.session.makeFolder(in: space.id, pinned: true)
        let favorite = Favorite(url: URL(string: "about:blank#\(page)-favorite")!, title: "Favorite", personaID: Persona.defaultID)
        mac.session.addFavorites([favorite], in: Persona.defaultID)
        let pin = SidebarSyncState.PinnedTab(id: UUID(), personaID: Persona.defaultID, spaceID: space.id, folderID: folder.id,
                                             savedPage: .init(url: URL(string: "about:blank#\(page)")!, title: "Saved"), customTitle: nil, engine: .webKit)
        let state = mac.session.sidebarSyncState
        mac.session.applySidebarSync(.init(personas: state.personas, spaces: state.spaces, folders: state.folders, favorites: state.favorites,
                                           pinnedTabs: state.pinnedTabs + [pin]), deletions: .init())
        try mac.session.saveNow().get()
        return (folder, pin, favorite)
    }

    /// Whether each Persona, space, folder, favorite, and tab of the session has an ID of its own.
    private func hasUniqueIDs(_ session: BrowserSession) -> Bool {
        Set(session.personas.map(\.id)).count == session.personas.count && Set(session.spaces.map(\.id)).count == session.spaces.count
            && Set(session.folders.map(\.id)).count == session.folders.count && Set(session.favorites.map(\.id)).count == session.favorites.count
            && Set(session.allTabs.map(\.id)).count == session.allTabs.count
    }

    /// B's data folder came from A, so B's Personas, spaces, folder, pinned tab, and favorite have the record names of A's records, and both Macs changed them before B turned sync on. Each ID joins its record once, the server's values win where both have one (sync decision 4), and B's own space of a name A uses joins A's.
    @Test func aSecondMacThatSharesIDsWithTheServerJoinsWithoutDuplicates() async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let shared = try fill(a, page: "shared")
        try? FileManager.default.removeItem(at: b.file)
        try FileManager.default.copyItem(at: a.file, to: b.file)
        try b.launch()
        let later = a.session.makeSpace(in: Persona.defaultID, named: "Later")
        a.session.moveFolder(shared.folder.id, toSpace: later.id)
        await a.controller.setEnabled(true)
        try await a.flush()
        let renamed = try #require(b.session.tabs.first { $0.id == shared.pin.id })
        renamed.customTitle = "Renamed on B"
        b.session.moveFolder(shared.folder.id, toSpace: b.session.makeSpace(in: Persona.defaultID, named: "Later").id)
        try b.session.saveNow().get()
        await b.controller.setEnabled(true)
        try await b.flush()
        await a.controller.refresh()
        #expect(b.controller.lastError == nil && b.controller.canSendRecords && b.firstFetches == 1)
        #expect(a.session.sidebarSyncState == b.session.sidebarSyncState && hasUniqueIDs(a.session) && hasUniqueIDs(b.session))
        #expect(b.session.spaces.filter { $0.name == "Later" }.map(\.id) == [later.id])
        #expect(b.session.folders.map(\.spaceID) == [later.id] && b.session.favorites.map(\.id) == [shared.favorite.id])
        #expect(b.session.tabs.filter { $0.id == shared.pin.id }.map(\.customTitle) == ["Renamed on B"])
        #expect(zone.records.count == 8)
    }

    /// The usual case: each Mac made its own sidebar, so no ID is shared but the default Persona's. B's Personal space, folder, pinned tab, and favorite join A's by name, saved page, and address, and B's Work Persona stays apart from A's (sync decision 4).
    @Test func aSecondMacWithItsOwnIDsJoinsTheServersItemsByName() async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let onA = try fill(a, page: "same")
        _ = try fill(b, page: "same")
        await a.controller.setEnabled(true)
        try await a.flush()
        await b.controller.setEnabled(true)
        try await b.flush()
        await a.controller.refresh()
        #expect(b.controller.lastError == nil && b.controller.canSendRecords)
        #expect(a.session.sidebarSyncState == b.session.sidebarSyncState && hasUniqueIDs(b.session))
        #expect(b.session.folders.map(\.id) == [onA.folder.id] && b.session.favorites.map(\.id) == [onA.favorite.id])
        #expect(b.session.sidebarSyncState.pinnedTabs.map(\.id) == [onA.pin.id])
        #expect(b.session.personas.filter { $0.name == "Work" }.count == 2)
    }

    /// A first fetch that brings every record twice, and a `sync.json` whose mirror lists a record twice, apply each record once.
    @Test func recordsFetchedOrMirroredTwiceApplyOnce() async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let onA = try fill(a, page: "twice")
        await a.controller.setEnabled(true)
        try await a.flush()
        zone.bringsRecordsTwice = true
        await b.controller.setEnabled(true)
        try await b.flush()
        #expect(b.controller.lastError == nil && a.session.sidebarSyncState == b.session.sidebarSyncState && hasUniqueIDs(b.session))
        zone.bringsRecordsTwice = false
        var file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: b.syncFile)) as? [String: Any])
        let text = try #require(file["records"] as? String)
        let archive = try #require(Data(base64Encoded: text))
        let rows = try #require(NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, CKRecord.self], from: archive) as? [CKRecord])
        file["records"] = try NSKeyedArchiver.archivedData(withRootObject: (rows + rows) as NSArray, requiringSecureCoding: true).base64EncodedString()
        try JSONSerialization.data(withJSONObject: file).write(to: b.syncFile)
        try b.launch()
        let edited = try #require(a.session.tabs.first { $0.id == onA.pin.id })
        edited.customTitle = "After the copy"
        try await a.flush()
        await b.controller.refreshIfRequested()
        try await b.flush()
        #expect(b.controller.lastError == nil && b.firstFetches == 1)
        #expect(a.session.sidebarSyncState == b.session.sidebarSyncState && hasUniqueIDs(b.session))
    }

    /// Lists the first item of `key` twice in the session file, as a hand-edited file can: a copy named "Later" follows it.
    private func listTwice(_ key: String, in file: URL) throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var list = try #require(json[key] as? [[String: Any]])
        var later = list[0]
        later[key == "favorites" ? "title" : "name"] = "Later"
        list.insert(later, at: 1)
        json[key] = list
        try JSONSerialization.data(withJSONObject: json).write(to: file)
    }

    /// The names of the session's spaces, folders, and favorites, in that order.
    private func names(_ session: BrowserSession) -> [String] {
        session.spaces.map(\.name) + session.folders.map(\.name) + session.favorites.map(\.title)
    }

    /// What the zone holds when B turns sync on.
    enum Server: CaseIterable, Sendable {
        case empty
        /// A's sidebar, filled as B's is.
        case otherMac
        /// A default Persona record that this build cannot apply, here one without a name, which holds out every item under it.
        case heldOut
    }

    /// B's `session.json` lists a space, folder, or favorite twice, the later copy named "Later". The load keeps the first copy of a space or folder and gives the later favorite an ID of its own (`SessionSnapshot.normalized()`), so B syncs each ID once and loses or doubles nothing: into an empty zone; against A's items, which B's first sync joins by name and address and which A then reorders; and beside a held-out record. Before, the first-sync plan refused the repeated name, so the first sync never finished; with the held-out record the session's apply trapped on the copies (`BrowserSession.applyFirstSidebarSync`); and a reorder put another item in the later copy's place.
    @Test(arguments: ["spaces", "folders", "favorites"], Server.allCases)
    func aSessionThatListsAnItemTwiceLoadsAndSyncsEachIDOnce(key: String, server: Server) async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        if server == .otherMac {
            _ = try fill(a, page: "local")
            await a.controller.setEnabled(true)
            try await a.flush()
        }
        _ = try fill(b, page: "local")
        let filled = names(b.session)
        try listTwice(key, in: b.file)
        try b.launch()
        let loaded = key == "favorites" ? filled + ["Later"] : filled
        #expect(names(b.session) == loaded && hasUniqueIDs(b.session))
        if server == .heldOut {
            zone.records["default"] = SyncCloudKitRecords.ckRecord(from: SyncRecord(recordType: .persona, recordName: "default",
                                                                                   fields: ["title": .text("Newer")], modifiedAt: Date()))
        }
        await b.controller.setEnabled(true)
        try await b.flush()
        #expect(b.controller.lastError == nil && b.controller.canSendRecords && hasUniqueIDs(b.session))
        switch server {
        case .empty:
            #expect(names(b.session) == loaded)
        case .heldOut:
            #expect(names(b.session) == loaded)
            #expect(zone.records.values.contains { $0.recordType == "Space" } && zone.records["default"] != nil)
        case .otherMac:
            await a.controller.refresh()
            let favorites = a.session.favorites
            if let last = favorites.last, let first = favorites.first { a.session.moveFavorite(last.id, to: first) }
            try await a.flush()
            await b.controller.refresh()
            #expect(a.session.sidebarSyncState == b.session.sidebarSyncState && hasUniqueIDs(a.session) && hasUniqueIDs(b.session))
            #expect(b.session.favorites.map(\.title) == (key == "favorites" ? ["Later", "Favorite"] : ["Favorite"]))
            #expect(names(b.session).filter { $0 == "Later" }.count == (key == "favorites" ? 1 : 0))
        }
    }
}
