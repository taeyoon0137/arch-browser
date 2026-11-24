// Moving tabs and folders between spaces (`docs/windows-personas.md`, Moving tabs between spaces): Move to Space within a Persona and to another Persona, where the page loads again in that Persona's profile, folders with what they hold, the refusals, the menus' and the palette's naming, and a drag onto a space's symbol in the bottom bar (`SidebarBottomBar`, `SidebarDragState`). The windows' AppKit windows are never ordered in.
import Agent
import AppKit
import ARCHEngine
import Foundation
import SwiftUI
import Testing
@testable import Browsing

@MainActor @Suite struct SpaceMoveTests {
    /// A session with one main window on the default Persona's first space.
    private func withSession(_ check: (BrowserSession, BrowserWindowModel, Space) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchSpaceMoves-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
        defer { session.windowWillClose(window) }
        try await check(session, window, space)
    }

    @Test func aMoveWithinThePersonaKeepsThePageAndTheWindowKeepsItsSpace() async throws {
        try await withSession { session, window, space in
            let later = session.makeSpace(in: space.resolvedPersonaID, named: "Later")
            let resident = session.openTab(url: URL(string: "https://example.org/resident")!, in: later.id, pinned: true, select: false)
            let folder = session.makeFolder(in: space.id, pinned: true)
            let stays = session.openTab(url: URL(string: "https://example.org/stays")!, in: space.id, select: false)
            let tab = session.openTab(url: URL(string: "https://example.org/moves")!, in: space.id, pinned: true, select: false)
            session.moveTab(tab.id, toFolder: folder.id)
            window.selectTab(tab.id)
            let page = tab.webContents
            let savedPage = tab.savedPage

            session.moveTab(tab.id, toSpace: later.id, windowsFollow: false)
            // The tab leaves its folder for the end of the space's pinned list, with its pin, saved page, and page.
            #expect(tab.spaceID == later.id && tab.folderID == nil && tab.isPinned && tab.savedPage == savedPage && tab.webContents === page)
            #expect(session.tabs(in: later.id, pinned: true).map(\.id) == [resident.id, tab.id])
            // The window stays on its space and selects the next tab, as closing the tab would.
            #expect(window.currentSpaceID == space.id && window.selectedTabID == stays.id)
        }
    }

    @Test func aMoveToAnotherPersonaLoadsThePageAgainThere() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let opener = session.openTab(url: URL(string: "https://example.org/opener")!, in: space.id, select: false)
            let url = URL(string: "https://example.org/report")!
            let tab = session.openTab(url: url, in: space.id, select: false)
            tab.opener = opener.webContents
            window.renameTab(tab.id, to: "Report")
            session.togglePinned(tab)
            window.selectTab(tab.id)
            let page = tab.webContents
            let savedPage = try #require(tab.savedPage)

            session.moveTab(tab.id, toSpace: workSpace.id, windowsFollow: false)
            // A new tab of the other Persona, under a new ID, takes its place, at the same address and with what it keeps; the old tab and its page are gone, without a closed record.
            #expect(!session.tabs.contains { $0 === tab } && !session.hasClosedTabs)
            let moved = try #require(session.tabs(in: workSpace.id, pinned: true).first)
            #expect(moved.id != tab.id && moved.personaID == work.id && tab.personaID == Persona.defaultID)
            #expect(moved.webContents !== page && moved.url == url && !moved.isLoaded && moved.opener == nil)
            #expect(moved.shownTitle == "Report" && moved.isPinned && moved.savedPage == savedPage && moved.preferredEngine == tab.preferredEngine)
            // The window keeps its Persona / Space and selects the tab left there.
            #expect(window.currentSpaceID == space.id && window.selectedTabID == opener.id)
            // Once a window shows it, its page loads in the other Persona.
            let workWindow = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: workSpace.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(workWindow) }
            workWindow.selectTab(moved.id)
            #expect(moved.isLoaded && moved.url == url)
        }
    }

    @Test func aDropFollowsTheTabAcrossPersonas() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let tab = session.openTab(url: URL(string: "https://example.org/")!, in: space.id, select: false)
            window.selectTab(tab.id)
            session.moveTab(tab.id, toSpace: workSpace.id)
            // The window follows to the other Persona and selects the tab's new ID.
            let moved = try #require(session.tabs(in: workSpace.id, pinned: false).first)
            #expect(moved.id != tab.id && moved.personaID == work.id && window.currentSpaceID == workSpace.id && window.personaID == work.id && window.selectedTabID == moved.id)
            #expect(!session.tabs.contains { $0.id == tab.id })
        }
    }

    /// The user's November 24 report: Move to Space left the tab unselected and the window in its original space. Moving to another Persona left the new tab unloaded until shown.
    @Test func aMenuMoveToAnotherPersonaShowsTheTabSelectedAndLoadedInTheMovingWindow() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let stays = session.openTab(url: URL(string: "https://example.org/stays")!, in: space.id, select: false)
            let url = URL(string: "https://example.org/report")!
            let tab = session.openTab(url: url, in: space.id, select: false)
            window.selectTab(tab.id)
            // Another window in the space with the tab selected keeps its space and selects another tab, as before.
            let other = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: space.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(other) }
            other.selectTab(tab.id)

            session.moveTab(tab.id, toSpace: workSpace.id, windowsFollow: false, activating: other)
            let moved = try #require(session.tabs(in: workSpace.id, pinned: false).first)
            #expect(moved.id != tab.id && moved.personaID == work.id && !session.tabs.contains { $0 === tab })
            #expect(other.currentSpaceID == workSpace.id && other.personaID == work.id && other.selectedTabID == moved.id)
            #expect(moved.isLoaded && moved.url == url)
            #expect(window.currentSpaceID == space.id && window.selectedTabID == stays.id)
        }
    }

    @Test func aMenuMoveWithinThePersonaSelectsAndLoadsAnUnselectedUnloadedTab() async throws {
        try await withSession { session, window, space in
            let later = session.makeSpace(in: space.resolvedPersonaID, named: "Later")
            let current = session.openTab(url: URL(string: "https://example.org/current")!, in: space.id, select: false)
            let tab = session.openTab(url: URL(string: "https://example.org/pinned")!, in: space.id, pinned: true, select: false)
            window.selectTab(tab.id)
            window.selectTab(current.id)
            // Closing a pinned tab unloads it to its saved page.
            #expect(session.closeTab(tab))
            #expect(!tab.isLoaded && window.selectedTabID == current.id)

            session.moveTab(tab.id, toSpace: later.id, windowsFollow: false, activating: window)
            #expect(tab.spaceID == later.id && tab.isPinned)
            #expect(window.currentSpaceID == later.id && window.selectedTabID == tab.id && tab.isLoaded)
        }
    }

    @Test func aDropOfAnUnselectedTabShowsItSelectedInTheDroppingWindow() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let current = session.openTab(url: URL(string: "https://example.org/current")!, in: space.id, select: false)
            let tab = session.openTab(url: URL(string: "https://example.org/dragged")!, in: space.id, select: false)
            window.selectTab(current.id)

            session.moveTab(tab.id, toSpace: workSpace.id, activating: window)
            let moved = try #require(session.tabs(in: workSpace.id, pinned: false).first)
            #expect(window.currentSpaceID == workSpace.id && window.selectedTabID == moved.id && moved.isLoaded)
            #expect(session.tabs.contains { $0 === current })
        }
    }

    @Test func newSpaceShowsTheMovedTabSelectedAndMovesTheUserDidNotStartSelectNothing() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let current = session.openTab(url: URL(string: "https://example.org/current")!, in: space.id, select: false)
            let tab = session.openTab(url: URL(string: "https://example.org/new-space")!, in: space.id, select: false)
            window.selectTab(current.id)
            session.moveTabToNewSpace(tab.id, in: work.id, activating: window)
            let made = try #require(session.spaces(in: work.id).last)
            let moved = try #require(session.tabs(in: made.id, pinned: false).first)
            #expect(window.currentSpaceID == made.id && window.selectedTabID == moved.id && moved.isLoaded)

            // A move without a moving window, such as a plugin's, leaves an unselected tab unselected and unloaded.
            let quiet = session.openTab(url: URL(string: "https://example.org/quiet")!, in: made.id, select: false)
            session.moveTab(quiet.id, toSpace: space.id)
            let arrived = try #require(session.tabs(in: space.id, pinned: false).last)
            #expect(arrived.personaID == Persona.defaultID && !arrived.isLoaded && window.selectedTabID == moved.id && window.currentSpaceID == made.id)
        }
    }

    @Test func aFolderMovesWithWhatItHoldsAndItsTabsLoadInTheOtherPersona() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let outer = session.makeFolder(in: space.id, pinned: true)
            let inner = session.makeFolder(in: space.id, pinned: true, inside: outer.id)
            let a = session.openTab(url: URL(string: "https://example.org/a")!, in: space.id, pinned: true, select: false)
            let b = session.openTab(url: URL(string: "https://example.org/b")!, in: space.id, pinned: true, select: false)
            session.moveTab(a.id, toFolder: outer.id)
            session.moveTab(b.id, toFolder: inner.id)
            let pages = [a.webContents, b.webContents]

            #expect(session.canMoveFolder(outer.id, toSpace: workSpace.id))
            session.moveFolder(outer.id, toSpace: workSpace.id, windowsFollow: false)
            // Into another Persona the folders take new IDs with their tree, and new tabs of that Persona replace the tabs inside.
            let moved = session.folders(in: workSpace.id)
            #expect(moved.count == 2 && !moved.contains { $0.id == outer.id || $0.id == inner.id } && moved[1].parentID == moved[0].id)
            #expect(!session.tabs.contains { $0 === a || $0 === b } && session.folders(in: space.id).isEmpty)
            let newA = try #require(session.tabs.first { $0.url == a.url && $0 !== a })
            let newB = try #require(session.tabs.first { $0.url == b.url && $0 !== b })
            #expect(newA.folderID == moved[0].id && newB.folderID == moved[1].id && [newA, newB].allSatisfy { $0.spaceID == workSpace.id && $0.personaID == work.id && $0.isPinned })
            #expect(newA.webContents !== pages[0] && newB.webContents !== pages[1])
            #expect(window.currentSpaceID == space.id)

            // Within a Persona a folder keeps its IDs; New Space makes a space in the chosen Persona and moves the folder into it.
            let later = session.makeSpace(in: work.id, named: "Later")
            session.moveFolder(moved[0].id, toSpace: later.id, windowsFollow: false)
            #expect(session.folders(in: later.id).map(\.id) == moved.map(\.id) && newA.spaceID == later.id && session.tabs.contains { $0 === newA })
            session.moveFolderToNewSpace(moved[0].id, in: Persona.defaultID)
            let made = try #require(session.spaces(in: Persona.defaultID).last)
            #expect(made.id != space.id && session.folders(in: made.id).count == 2 && session.tabs.contains { $0.spaceID == made.id && $0.personaID == Persona.defaultID })
        }
    }

    @Test func movesRefuseWhatStaysInItsPersonaOrHasNoRow() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let later = session.makeSpace(in: space.resolvedPersonaID, named: "Later")

            // An agent's tab moves within its Persona only.
            let host = BrowserAgentHost(session: session)
            let info = try #require(host.openAgentTab(at: URL(string: "https://example.org/task")!, engine: .webKit, for: AgentTabOwner(id: UUID(), spaceID: space.id, folderName: "Task")))
            let agentTab = try #require(session.tabs.first { $0.id == info.id })
            #expect(session.spaceMoveRefusal(ofTab: agentTab, toPersona: work.id) == .agentTab)
            #expect(!session.canCarryTab(agentTab.id, toSpace: workSpace.id) && session.canCarryTab(agentTab.id, toSpace: later.id))
            let sections = session.spaceMoveSections(forTab: agentTab)
            #expect(sections.map(\.refusalHelp) == [nil, BrowserSession.SpaceMoveRefusal.agentTab.help])
            session.moveTabToNewSpace(agentTab.id, in: work.id)
            #expect(session.spaces(in: work.id).count == 1 && agentTab.personaID == Persona.defaultID)
            // An agent folder stays where its agent works.
            let agentFolder = try #require(agentTab.folderID)
            #expect(!session.canMoveFolder(agentFolder, toSpace: later.id))

            // A small window's tab and a favorite's tab have no row to move.
            let small = session.openTab(url: URL(string: "https://example.org/small")!, in: space.id, select: false)
            small.isInSmallWindow = true
            #expect(!session.canCarryTab(small.id, toSpace: later.id) && session.spaceMoveSections(forTab: small).isEmpty)
            #expect(session.spaceMoveCommands(matching: "move", forTab: small).isEmpty)
        }
    }

    @Test func theMenusNameSpacesByPersonaOnlyWithSeveralPersonas() async throws {
        try await withSession { session, window, space in
            let later = session.makeSpace(in: space.resolvedPersonaID, named: "Later")
            let tab = session.openTab(url: URL(string: "https://example.org/")!, in: space.id, select: false)
            // With one Persona the spaces' names alone name them.
            #expect(session.spaceMoveSections(forTab: tab).map(\.title) == [nil])
            #expect(session.spaceMoveSections(forTab: tab).first?.spaces.map(\.id) == [space.id, later.id])
            #expect(session.spaceMoveCommands(matching: "move tab", forTab: tab).map(\.title) == [localized("Move Tab to \(later.name)")])

            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let personal = try #require(session.persona(withID: Persona.defaultID))
            let sections = session.spaceMoveSections(forTab: tab)
            #expect(sections.map(\.title) == [personal.name, "Work"] && sections.last?.spaces.map(\.id) == [workSpace.id])
            // A palette row names both on one line, "Persona / Space", and the tab's own space is left out.
            let commands = session.spaceMoveCommands(matching: "Move Tab to", forTab: tab)
            #expect(commands.map(\.space.id) == [later.id, workSpace.id])
            #expect(commands.map(\.title) == [localized("Move Tab to \("\(personal.name) / Later")"), localized("Move Tab to \("Work / \(workSpace.name)")")])
            #expect(session.spaceMoveCommands(matching: "move tab to work", forTab: tab).map(\.space.id) == [workSpace.id])
            #expect(session.spaceMoveCommands(matching: "reload", forTab: tab).isEmpty)
        }
    }

    /// A drag onto a space's symbol: the bottom bar's symbols report their frames in the window, and a dragged tab over another Persona's symbol finds that space as its drop target, which then takes it as `SpaceTabsView` does on release.
    @Test func aTabDraggedOntoAnotherPersonasSymbolMovesThere() async throws {
        try await withSession { session, window, space in
            let work = session.addPersona(named: "Work")
            let workSpace = try #require(session.spaces(in: work.id).first)
            let tab = session.openTab(url: URL(string: "https://example.org/")!, in: space.id, select: false)
            let drag = SidebarDragState()
            let host = NSHostingView(rootView: SidebarBottomBar(session: session)
                .frame(width: 260, height: 28)
                .coordinateSpace(name: BrowserWindowView.coordinateSpace)
                .environmentObject(drag)
                .environmentObject(window)
                .environment(\.sidebarWidth, 260))
            host.frame = CGRect(x: 0, y: 0, width: 260, height: 28)
            host.layoutSubtreeIfNeeded()
            #expect(await waitUntil { drag.spaceSymbolFrames.count == 2 && drag.spaceStripFrame != .zero })
            let own = try #require(drag.spaceSymbolFrames[space.id])
            let target = try #require(drag.spaceSymbolFrames[workSpace.id])
            #expect(drag.spaceStripFrame.contains(CGPoint(x: target.midX, y: target.midY)))

            drag.begin(.tab(tab.id), frame: CGRect(x: 10, y: -200, width: 220, height: 36), grabbedAt: CGPoint(x: 20, y: -190), owner: UUID())
            #expect(drag.spaceDestination(forTab: tab, at: CGPoint(x: own.midX, y: own.midY), session: session) == nil)
            let destination = try #require(drag.spaceDestination(forTab: tab, at: CGPoint(x: target.midX, y: target.midY), session: session))
            #expect(destination == workSpace.id)
            #expect(drag.spaceDestination(forTab: tab, at: CGPoint(x: target.midX, y: target.maxY + 20), session: session) == nil)
            session.moveTab(tab.id, toSpace: destination)
            #expect(session.tabs.contains { $0.spaceID == workSpace.id && $0.personaID == work.id && $0.url == tab.url } && !session.tabs.contains { $0 === tab })
        }
    }
}

/// Waits up to `limit` for `condition`, checking every 10 milliseconds.
@MainActor private func waitUntil(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
