import ARCHEngine
@testable import Browsing
import Foundation
import Testing
@testable import Sync

/// Move to Space syncs as ordinary record changes (`docs/windows-personas.md`, Moving tabs between spaces): a pinned tab or folder moved into another Persona's space takes a new ID, so its old record is deleted and a new one in the target Persona uploads, and the other Mac ends with it in that Persona.
@MainActor @Suite struct SpaceMoveSyncTests {
    typealias Mac = TwoMacRecoveryTests.Mac
    typealias Zone = TwoMacRecoveryTests.Zone

    @Test func aPinnedTabAndAFolderMovedToAnotherPersonaReachTheOtherMacThere() async throws {
        let zone = Zone()
        let a = try Mac(zone: zone), b = try Mac(zone: zone)
        defer { a.clean(); b.clean() }
        let work = a.session.addPersona(named: "Work")
        let workSpace = try #require(a.session.spaces(in: work.id).first)
        let home = try #require(a.session.spaces(in: Persona.defaultID).first)
        let folder = a.session.makeFolder(in: home.id, pinned: true)
        let state = a.session.sidebarSyncState
        let pins = ["Report", "Notes"].map { title in
            SidebarSyncState.PinnedTab(id: UUID(), personaID: Persona.defaultID, spaceID: home.id, folderID: title == "Notes" ? folder.id : nil,
                                       savedPage: SavedPage(url: URL(string: "about:blank#\(title)")!, title: title), customTitle: title == "Report" ? "Quarterly" : nil, engine: .webKit)
        }
        a.session.applySidebarSync(.init(personas: state.personas, spaces: state.spaces, folders: state.folders, favorites: state.favorites,
                                         pinnedTabs: state.pinnedTabs + pins), deletions: .init())
        await a.controller.setEnabled(true)
        try await a.flush()
        await b.controller.setEnabled(true)
        try await b.flush()
        #expect(b.session.tabs.contains { $0.id == pins[0].id } && b.session.folders.contains { $0.id == folder.id })

        a.session.moveTab(pins[0].id, toSpace: workSpace.id, windowsFollow: false)
        a.session.moveFolder(folder.id, toSpace: workSpace.id, windowsFollow: false)
        let moved = try #require(a.session.tabs.first { $0.savedPage?.title == "Report" })
        let movedFolder = try #require(a.session.folders(in: workSpace.id).first)
        #expect(moved.id != pins[0].id && moved.personaID == work.id && moved.isPinned && moved.shownTitle == "Quarterly" && movedFolder.id != folder.id)
        try await a.flush()
        await b.controller.refresh()
        try await b.flush()

        #expect(b.controller.lastError == nil)
        #expect(!b.session.tabs.contains { $0.id == pins[0].id || $0.id == pins[1].id } && !b.session.folders.contains { $0.id == folder.id })
        let arrived = try #require(b.session.tabs.first { $0.id == moved.id })
        #expect(arrived.personaID == work.id && arrived.spaceID == workSpace.id && arrived.isPinned && arrived.savedPage?.title == "Report" && arrived.shownTitle == "Quarterly")
        let notes = try #require(b.session.tabs.first { $0.savedPage?.title == "Notes" })
        #expect(notes.personaID == work.id && notes.folderID == movedFolder.id && b.session.folders(in: workSpace.id).map(\.id) == [movedFolder.id])
    }
}
