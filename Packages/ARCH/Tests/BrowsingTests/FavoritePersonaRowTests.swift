// Favorite layouts belong to Personas, migrate once, and survive a save without an order change.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor @Suite struct FavoritePersonaRowTests {
    private func registry() -> EngineRegistry {
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        return registry
    }

    private func favorites(_ count: Int, in personaID: UUID) -> [Favorite] {
        (0..<count).map {
            Favorite(url: URL(string: "about:blank#\(personaID)-\($0)")!, title: "Favorite \($0)", personaID: personaID)
        }
    }

    @Test func legacyRowsMigrateToEveryExistingPersonaOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaRows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults.standard
        let oldRows = defaults.object(forKey: FavoriteTileLayout.rowSizesKey)
        let oldColumns = defaults.object(forKey: FavoriteTileLayout.columnsKey)
        defer {
            defaults.set(oldRows, forKey: FavoriteTileLayout.rowSizesKey)
            defaults.set(oldColumns, forKey: FavoriteTileLayout.columnsKey)
        }
        defaults.set(FavoriteTileLayout.encode(rowSizes: [1, 2, 1]), forKey: FavoriteTileLayout.rowSizesKey)
        defaults.set(4, forKey: FavoriteTileLayout.columnsKey)
        let personal = Persona(id: Persona.defaultID, name: "Personal", favoriteRows: nil)
        let work = Persona(name: "Work", favoriteRows: nil)
        let configured = Persona(name: "Configured", favoriteRows: [2, 2])
        let spaces = [personal, work, configured].map { Space(name: "Space", personaID: $0.id) }
        let snapshot = SessionSnapshot(personas: [personal, work, configured], spaces: spaces, currentSpaceID: spaces[0].id,
                                       favorites: favorites(4, in: personal.id) + favorites(6, in: work.id) + favorites(4, in: configured.id), tabs: [])
        try SessionStore(directory: directory, seal: .fixture).saveNow(snapshot).get()
        let engineRegistry = registry()
        let session = try BrowserSession(testRegistry: engineRegistry, directory: directory)
        #expect(session.favoriteRows(in: personal.id) == [1, 2, 1])
        #expect(session.favoriteRows(in: work.id) == [1, 2, 3])
        #expect(session.favoriteRows(in: configured.id) == [2, 2])
        let newPersona = session.addPersona(named: "New")
        session.addFavorites(favorites(4, in: newPersona.id), in: newPersona.id)
        #expect(session.favoriteRows(in: newPersona.id) == [4])
        session.setFavoriteRows([2, 2], in: personal.id)
        try session.saveNow().get()
        defaults.set(FavoriteTileLayout.encode(rowSizes: [4]), forKey: FavoriteTileLayout.rowSizesKey)
        let restored = try BrowserSession(testRegistry: engineRegistry, directory: directory)
        #expect(restored.favoriteRows(in: personal.id) == [2, 2])
        #expect(restored.favoriteRows(in: work.id) == [1, 2, 3])
        #expect(restored.favoriteRows(in: configured.id) == [2, 2])
        #expect(restored.favoriteRows(in: newPersona.id) == [4])
    }

    @Test func aSessionFromBeforePersonasMigratesTheLegacyRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaRows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults.standard
        let oldRows = defaults.object(forKey: FavoriteTileLayout.rowSizesKey)
        defer { defaults.set(oldRows, forKey: FavoriteTileLayout.rowSizesKey) }
        defaults.set(FavoriteTileLayout.encode(rowSizes: [1, 2, 1]), forKey: FavoriteTileLayout.rowSizesKey)
        let space = Space(name: "Personal")
        let snapshot = SessionSnapshot(version: 8, spaces: [space], currentSpaceID: space.id,
                                       favorites: favorites(4, in: Persona.defaultID), tabs: [])
        try SessionStore(directory: directory, seal: .fixture).saveNow(snapshot).get()
        let session = try BrowserSession(testRegistry: registry(), directory: directory)
        #expect(session.favoriteRows(in: Persona.defaultID) == [1, 2, 1])
    }

    @Test func editsInOnePersonaLeaveTheOtherLayoutAndFavoritesAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaRows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try BrowserSession(testRegistry: registry(), directory: directory)
        let work = session.addPersona(named: "Work")
        let personal = Persona.defaultID
        session.addFavorites(favorites(4, in: personal), in: personal)
        session.addFavorites(favorites(4, in: work.id), in: work.id)
        session.setFavoriteRows([3, 1], in: personal)
        session.setFavoriteRows([1, 3], in: work.id)
        let workFavorites = session.favorites(in: work.id)
        let first = try #require(session.favorites(in: personal).first)
        session.moveFavorite(first.id, toIndex: 0, rowSizes: [2, 2])
        #expect(session.favoriteRows(in: personal) == [2, 2])
        #expect(session.favoriteRows(in: work.id) == [1, 3])
        session.removeFavorite(first)
        #expect(session.favoriteRows(in: personal) == [1, 2])
        #expect(session.favoriteRows(in: work.id) == [1, 3])
        #expect(session.favorites(in: work.id) == workFavorites)
        try session.saveNow().get()
        let restored = try BrowserSession(testRegistry: registry(), directory: directory)
        #expect(restored.favoriteRows(in: personal) == [1, 2])
        #expect(restored.favoriteRows(in: work.id) == [1, 3])
    }

    @Test func changingOnlyRowsPublishesThemInTheSavedSyncState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaRows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try BrowserSession(testRegistry: registry(), directory: directory)
        session.addFavorites(favorites(4, in: Persona.defaultID), in: Persona.defaultID)
        session.setFavoriteRows([3, 1], in: Persona.defaultID)
        try session.saveNow().get()
        let order = session.favorites
        var saved: [SidebarSyncState] = []
        session.onSidebarSyncSave = { saved.append($0) }
        let first = try #require(order.first)
        session.moveFavorite(first.id, toIndex: 0, rowSizes: [2, 2])
        try session.saveNow().get()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(session.favorites == order)
        #expect(saved.last?.personas.first { $0.id == Persona.defaultID }?.favoriteRows == [2, 2])
        let restored = try BrowserSession(testRegistry: registry(), directory: directory)
        #expect(restored.favoriteRows(in: Persona.defaultID) == [2, 2])
    }

    @Test func incomingRowsNormalizeAfterTheFavoriteSetAndLegacyRowsStayLocal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaRows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try BrowserSession(testRegistry: registry(), directory: directory)
        let work = session.addPersona(named: "Work")
        session.addFavorites(favorites(4, in: Persona.defaultID), in: Persona.defaultID)
        session.addFavorites(favorites(4, in: work.id), in: work.id)
        session.setFavoriteRows([3, 1], in: Persona.defaultID)
        session.setFavoriteRows([1, 3], in: work.id)
        let initial = session.sidebarSyncState
        var incomingPersonas = initial.personas
        for index in incomingPersonas.indices {
            incomingPersonas[index].favoriteRows = incomingPersonas[index].id == work.id ? nil : [1, 2]
        }
        let added = Favorite(url: URL(string: "about:blank#remote")!, title: "Remote", personaID: Persona.defaultID)
        let incoming = SidebarSyncState(personas: incomingPersonas, spaces: initial.spaces, folders: initial.folders,
                                        favorites: initial.favorites + [added], pinnedTabs: initial.pinnedTabs)
        session.applySidebarSync(incoming, deletions: SidebarSyncDeletions())
        #expect(session.favoriteRows(in: Persona.defaultID) == [1, 4])
        #expect(session.favoriteRows(in: work.id) == [1, 3])
        #expect(session.favorites(in: Persona.defaultID).count == 5)
        session.applySidebarSync(incoming, deletions: SidebarSyncDeletions())
        #expect(session.favoriteRows(in: Persona.defaultID) == [1, 4])
        #expect(session.favoriteRows(in: work.id) == [1, 3])
    }

    @Test func firstSyncWithLegacyPersonasPreservesRowsAfterReplacingFavoriteIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchPersonaRows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try BrowserSession(testRegistry: registry(), directory: directory)
        session.addFavorites(favorites(4, in: Persona.defaultID), in: Persona.defaultID)
        session.setFavoriteRows([2, 2], in: Persona.defaultID)
        let initial = session.sidebarSyncState
        var replacements = SidebarSyncReplacements()
        let remoteFavorites = initial.favorites.map { favorite in
            var remote = favorite
            remote.id = UUID()
            replacements.favorites[favorite.id] = remote.id
            return remote
        }
        let remotePersonas = initial.personas.map { persona in
            var legacy = persona
            legacy.favoriteRows = nil
            return legacy
        }
        let incoming = SidebarSyncState(personas: remotePersonas, spaces: initial.spaces, folders: initial.folders,
                                        favorites: remoteFavorites, pinnedTabs: initial.pinnedTabs)
        session.applyFirstSidebarSync(incoming, replacements: replacements)
        #expect(session.favorites == remoteFavorites)
        #expect(session.favoriteRows(in: Persona.defaultID) == [2, 2])
        session.applyFirstSidebarSync(incoming, replacements: replacements)
        #expect(session.favorites == remoteFavorites)
        #expect(session.favoriteRows(in: Persona.defaultID) == [2, 2])
    }

    @Test(arguments: [
        (0, [1, 2, 3], 4, []),
        (3, [1, 4, 3], 4, [1, 2]),
        (8, [1, 2], 4, [1, 4, 3]),
        (8, [1, 2], 2, [1, 4, 2, 1]),
        (7, [0, -1, 99, 2, 0], 4, [4, 3]),
        (9, [], 3, [3, 3, 3])
    ])
    func staleRowsPreserveOccupiedRowsAndFillTheLastRow(count: Int, rows: [Int], columns: Int, expected: [Int]) {
        let normalized = FavoriteTileLayout.normalizedRows(for: count, rowSizes: rows, defaultColumns: columns)
        #expect(normalized == expected)
        #expect(normalized.reduce(0, +) == count)
        #expect(normalized.allSatisfy { FavoriteTileLayout.choices.contains($0) })
        #expect(FavoriteTileLayout.normalizedRows(for: count, rowSizes: normalized, defaultColumns: columns) == normalized)
    }
}
