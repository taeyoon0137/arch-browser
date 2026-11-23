// Merge Space Into… and Merge Persona Into… (`docs/windows-personas.md`, Merge Into…): what moves, in which order and under which IDs, what is removed, which targets each offers, and the sheets' texts. Sessions run on `SessionTestEngine` in temporary folders, with a hidden window that never shows.
import ARCHEngine
@testable import Browsing
import Foundation
import Testing

@MainActor @Suite struct MergeIntoTests {
    private func temporarySession(_ body: (BrowserSession, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        try await body(try BrowserSession(testRegistry: registry, directory: directory), directory)
    }

    /// A pinned tab of the space, in `folder` when given, with a saved page and a name.
    private func pin(_ name: String, in space: Space, folder: TabFolder? = nil, session: BrowserSession) -> Tab {
        let tab = session.adopt(session.makeWebContents(url: URL(string: "about:blank#\(name)"), engine: .webKit, state: nil, in: space.resolvedPersonaID),
                                spaceID: space.id, personaID: space.resolvedPersonaID, pinned: true, select: false, folderID: folder?.id)
        tab.savedPage = SavedPage(url: URL(string: "about:blank#\(name)")!, title: name)
        tab.customTitle = name
        return tab
    }

    private func open(_ name: String, in space: Space, session: BrowserSession) -> Tab {
        let tab = session.adopt(session.makeWebContents(url: URL(string: "about:blank#\(name)"), engine: .webKit, state: nil, in: space.resolvedPersonaID),
                                spaceID: space.id, personaID: space.resolvedPersonaID, pinned: false, select: false)
        tab.customTitle = name
        return tab
    }

    private func names(_ tabs: [Tab]) -> [String] { tabs.map { $0.customTitle ?? "" } }

    @Test func aSpaceMergesIntoAnotherOfItsPersonaWithItsTabsAndFoldersAfterTheTargetsOwn() async throws {
        try await temporarySession { session, _ in
            let target = try #require(session.spaces.first)
            let source = session.makeSpace(in: target.resolvedPersonaID, named: "Source")
            _ = pin("Kept", in: target, session: session)
            let folder = session.makeFolder(in: source.id, pinned: true)
            let inner = session.makeFolder(in: source.id, pinned: true, inside: folder.id)
            let deep = pin("Deep", in: source, folder: inner, session: session)
            let loose = pin("Loose", in: source, session: session)
            let browsing = open("Browsing", in: source, session: session)
            let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: source.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(window) }
            window.selectTab(loose.id)
            #expect(session.spaceMergeTargets(for: source.id).map(\.id) == [target.id])
            session.mergeSpace(source.id, into: target.id)
            #expect(!session.spaces.contains { $0.id == source.id })
            // Within one Persona they keep their IDs and the folder tree, pinned tabs stay pinned, and they follow the target's own.
            #expect(names(session.tabs(in: target.id, pinned: true)) == ["Deep", "Kept", "Loose"])
            #expect(names(session.tabs(in: target.id, pinned: false)) == ["Browsing"] && browsing.spaceID == target.id)
            #expect(session.folders.first { $0.id == inner.id }?.parentID == folder.id && deep.folderID == inner.id && loose.isPinned)
            #expect(window.currentSpaceID == target.id && window.selectedTabID == loose.id)
        }
    }

    @Test func aSpaceMergesIntoAnotherPersonasSpaceUnderNewIDsThatReloadThere() async throws {
        try await temporarySession { session, _ in
            let home = try #require(session.spaces.first)
            let source = session.makeSpace(in: home.resolvedPersonaID, named: "Source")
            let work = session.addPersona(named: "Work")
            let target = try #require(session.spaces(in: work.id).first)
            let folder = session.makeFolder(in: source.id, pinned: true)
            let inner = session.makeFolder(in: source.id, pinned: true, inside: folder.id)
            let deep = pin("Deep", in: source, folder: inner, session: session)
            let browsing = open("Browsing", in: source, session: session)
            let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: source.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(window) }
            window.selectTab(browsing.id)
            #expect(session.spaceMergeTargets(for: source.id).map(\.id) == [home.id, target.id])
            session.mergeSpace(source.id, into: target.id)
            #expect(!session.spaces.contains { $0.id == source.id })
            let moved = session.tabs(in: target.id, pinned: true) + session.tabs(in: target.id, pinned: false)
            #expect(names(moved) == ["Deep", "Browsing"] && moved.allSatisfy { $0.personaID == work.id } && moved.first?.isLoaded == false)
            #expect(!session.allTabs.contains { $0.id == deep.id || $0.id == browsing.id })
            let movedPin = try #require(moved.first)
            #expect(movedPin.isPinned && movedPin.savedPage == deep.savedPage)
            let movedInner = try #require(session.folders.first { $0.id == movedPin.folderID })
            let movedFolder = try #require(session.folders.first { $0.id == movedInner.parentID })
            #expect(movedInner.id != inner.id && movedFolder.id != folder.id && movedFolder.spaceID == target.id && movedFolder.parentID == nil)
            #expect(window.currentSpaceID == target.id && window.selectedTabID == moved.last?.id)
        }
    }

    @Test func onlySpacesAndPersonasThatCanGoOfferTargets() async throws {
        try await temporarySession { session, _ in
            let home = try #require(session.spaces.first)
            let work = session.addPersona(named: "Work")
            let agents = session.addPersona(named: "Agents")
            session.agentOnlyPersonaID = agents.id
            let workSpace = try #require(session.spaces(in: work.id).first)
            // A Persona's only space is the Persona's to merge; the Agents Persona's spaces are neither sources nor targets.
            #expect(session.spaceMergeTargets(for: home.id).isEmpty && session.spaceMergeTargets(for: workSpace.id).isEmpty)
            let extra = session.makeSpace(in: work.id, named: "Extra")
            #expect(session.spaceMergeTargets(for: extra.id).map(\.id) == [home.id, workSpace.id])
            #expect(session.personaMergeTargets(for: Persona.defaultID).isEmpty && session.personaMergeTargets(for: agents.id).isEmpty)
            #expect(session.personaMergeTargets(for: work.id).map(\.id) == [Persona.defaultID])
            session.mergeSpace(home.id, into: workSpace.id)
            #expect(session.spaces.contains { $0.id == home.id })
            try await session.mergePersona(work.id, into: agents.id)
            #expect(session.personas.contains { $0.id == work.id })
        }
    }

    @Test func aPersonaMergesItsSpacesAndFavoritesIntoAnotherAndIsRemovedWithItsData() async throws {
        try await temporarySession { session, directory in
            let home = try #require(session.spaces.first)
            let work = session.addPersona(named: "Work")
            let research = try #require(session.spaces(in: work.id).first)
            session.updateSpace(research.id) { $0.name = home.name }
            let second = session.makeSpace(in: work.id, named: "Reading")
            let shared = URL(string: "https://example.com/shared")!
            _ = session.addFavorites([Favorite(url: shared, title: "Home's", personaID: Persona.defaultID)], in: Persona.defaultID)
            _ = session.addFavorites([Favorite(url: shared, title: "Work's", personaID: work.id),
                                      Favorite(url: URL(string: "https://example.com/work")!, title: "Work only", personaID: work.id)], in: work.id)
            let workPin = pin("Work pin", in: research, session: session)
            let window = session.makeWindow(from: .init(id: UUID(), frame: nil, currentSpaceID: second.id, selectedTabID: nil, isSidebarVisible: true), kind: .main)
            defer { session.windowWillClose(window) }
            try await session.mergePersona(work.id, into: Persona.defaultID)
            #expect(!session.personas.contains { $0.id == work.id })
            // Its spaces join the end of the target's with their names, also one of a name the target uses, under new IDs.
            let spaces = session.spaces(in: Persona.defaultID)
            #expect(spaces.map(\.name) == [home.name, home.name, "Reading"] && !spaces.contains { $0.id == research.id || $0.id == second.id })
            #expect(session.favorites(in: Persona.defaultID).map(\.title) == ["Home's", "Work only"])
            let moved = try #require(session.tabs.first { $0.customTitle == "Work pin" })
            #expect(moved.id != workPin.id && moved.personaID == Persona.defaultID && moved.isPinned && moved.spaceID == spaces[1].id)
            #expect(window.currentSpaceID == spaces[2].id)
            try session.saveNow().get()
            #expect(SessionStore(directory: directory, seal: .fixture).load()?.removedPersonaIDs == [work.id])
        }
    }

    @Test func theSheetsSayWhatMovesWhatIsRemovedAndThatSyncedMacsFollow() {
        let space = BrowserWindowModel.mergeSpaceTexts(space: "Work / Reading", isSyncing: true)
        #expect(space.message == "Merge \u{201C}Work / Reading\u{201D} into another space?")
        #expect(space.information.contains("\u{201C}Work / Reading\u{201D} is removed") && space.information.contains("another Persona") && space.information.contains("iCloud"))
        let persona = BrowserWindowModel.mergePersonaTexts(persona: "the Persona \u{201C}Work\u{201D}")
        #expect(persona.message == "Merge the Persona \u{201C}Work\u{201D} into another Persona?")
        #expect(persona.information.contains("cookies and sign-ins are not carried over") && !persona.information.contains("iCloud"))
    }
}
