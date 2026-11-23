import ARCHEngine
@testable import Browsing
import Foundation
import Testing
@testable import Sync

/// Merge Into… syncs as ordinary record changes (`docs/sync.md`, First sync on a Mac): moves within a Persona change the records' places, moves into another Persona are new records, and the removed space or Persona is a deletion, so the other Mac ends with the same sidebar.
@MainActor @Suite struct MergeIntoSyncTests {
    typealias Mac = TwoMacRecoveryTests.Mac
    typealias Zone = TwoMacRecoveryTests.Zone

    /// Whether two sidebars hold the same items in the same order within each list. The session's one list of tabs orders tabs of different spaces as each Mac added them, which no record keeps.
    private func sameSidebar(_ first: SidebarSyncState, _ second: SidebarSyncState) -> Bool {
        let lists = { (state: SidebarSyncState) in Dictionary(grouping: state.pinnedTabs) { "\($0.spaceID) \(String(describing: $0.folderID))" } }
        return first.personas == second.personas && first.spaces == second.spaces && first.folders == second.folders
            && first.favorites == second.favorites && lists(first) == lists(second)
    }

    @Test(arguments: [false, true])
    func aMergeOnOneMacReachesTheOther(mergesPersona: Bool) async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let work = a.session.addPersona(named: "Work")
        let workSpace = try #require(a.session.spaces(in: work.id).first)
        let reading = a.session.makeSpace(in: Persona.defaultID, named: "Reading")
        for space in [workSpace, reading] {
            let state = a.session.sidebarSyncState
            let pin = SidebarSyncState.PinnedTab(id: UUID(), personaID: space.resolvedPersonaID, spaceID: space.id, folderID: nil,
                                                 savedPage: SavedPage(url: URL(string: "about:blank#\(space.name)")!, title: space.name), customTitle: nil, engine: .webKit)
            a.session.applySidebarSync(.init(personas: state.personas, spaces: state.spaces, folders: state.folders, favorites: state.favorites,
                                             pinnedTabs: state.pinnedTabs + [pin]), deletions: .init())
        }
        _ = a.session.addFavorites([Favorite(url: URL(string: "https://example.com/work")!, title: "Work", personaID: work.id)], in: work.id)
        await a.controller.setEnabled(true)
        try await a.flush()
        await b.controller.setEnabled(true)
        try await b.flush()
        #expect(b.session.personas.contains { $0.id == work.id })
        let home = try #require(a.session.spaces.first { $0.resolvedPersonaID == Persona.defaultID && $0.id != reading.id })
        if mergesPersona {
            try await a.session.mergePersona(work.id, into: Persona.defaultID)
        } else {
            a.session.mergeSpace(reading.id, into: home.id)
        }
        try await a.flush()
        await b.controller.refresh()
        try await b.flush()
        #expect(b.controller.lastError == nil && sameSidebar(a.session.sidebarSyncState, b.session.sidebarSyncState))
        if mergesPersona {
            #expect(!b.session.personas.contains { $0.id == work.id } && zone.records[work.id.uuidString] == nil && zone.records[workSpace.id.uuidString] == nil)
            #expect(b.session.favorites.contains { $0.title == "Work" && $0.resolvedPersonaID == Persona.defaultID })
        } else {
            #expect(!b.session.spaces.contains { $0.id == reading.id } && zone.records[reading.id.uuidString] == nil)
            #expect(b.session.tabs.contains { $0.savedPage?.title == "Reading" && $0.spaceID == home.id })
        }
    }
}
