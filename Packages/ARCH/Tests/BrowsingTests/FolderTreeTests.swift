// Nested folders (`docs/bookmarks.md`, Nested folders; bookmark rule 6): the parents that `session.json` repairs, the sidebar's rows with their depths, collapsed folders at any level, the moves that Move to Folder allows and refuses, Move Out of Folder, Delete Folder keeping what a folder held, and where a dragged folder goes (`dropTarget(for:at:)`, a drop on another space's symbol, and the dragged folder's hidden rows). Tabs run on `PageStub`, without a session or an engine, so the menus, the indented rows, the drags, and the session's calls are regression check 70.
import ARCHEngine
import Foundation
import Testing
@testable import Browsing

@MainActor
@Suite struct FolderTreeTests {
    private let spaceID = UUID()
    private let otherSpaceID = UUID()

    /// A folder at the top of the space's pinned list, of the open list without `pinned`, or of another space, or inside `parent`.
    private func folder(_ name: String, in parent: TabFolder? = nil, pinned: Bool = true, space: UUID? = nil) -> TabFolder {
        var folder = TabFolder(spaceID: parent?.spaceID ?? space ?? spaceID, name: name, isPinned: parent?.isPinned ?? pinned)
        folder.parentID = parent?.id
        return folder
    }

    /// A tab of the space in `folder`, or outside folders in the pinned or open list, named `name` so the rows can be read.
    private func tab(_ name: String, in folder: TabFolder? = nil, pinned: Bool = true) -> Tab {
        let page = PageStub(engine: .webKit, url: URL(string: "https://example.org/\(name)"))
        let tab = Tab(id: UUID(), webContents: page, spaceID: folder?.spaceID ?? spaceID, isPinned: folder?.isPinned ?? pinned, personaID: Persona.defaultID)
        tab.folderID = folder?.id
        tab.customTitle = name
        return tab
    }

    /// Each row as its name after two spaces for each folder that holds it.
    private func outline(_ rows: [FolderTree.Row]) -> [String] {
        rows.map { row in
            let name: String
            switch row {
            case .folder(let folder, _): name = folder.name
            case .tab(let tab, _): name = tab.customTitle ?? ""
            }
            return String(repeating: "  ", count: row.depth) + name
        }
    }

    private func names(_ tabs: [Tab]) -> [String] {
        tabs.map { $0.customTitle ?? "" }
    }

    // MARK: Repairs

    @Test func aTabReordersOnceWhileThePointerStaysOverTheDisplacedRow() {
        let row = CGRect(x: 6, y: 100, width: 224, height: 36)
        let point = CGPoint(x: row.midX, y: row.midY)
        let above = row.offsetBy(dx: 0, dy: -38), below = row.offsetBy(dx: 0, dy: 38)
        #expect(!SidebarReorderHover.crossedMidpoint(from: above, into: row, at: CGPoint(x: point.x, y: row.minY)))
        #expect(SidebarReorderHover.crossedMidpoint(from: above, into: row, at: point))
        #expect(!SidebarReorderHover.crossedMidpoint(from: below, into: row, at: CGPoint(x: point.x, y: row.maxY)))
        #expect(SidebarReorderHover.crossedMidpoint(from: below, into: row, at: point))
        var drag = SidebarReorderHover()
        let initial = drag.canMove(at: point)
        #expect(initial)
        drag.moved(into: row)
        for y in [row.midY, row.midY + 1, row.maxY, row.maxY + 1] {
            let canRepeat = drag.canMove(at: CGPoint(x: point.x, y: y))
            #expect(!canRepeat)
        }
        let left = drag.canMove(at: CGPoint(x: point.x, y: row.maxY + 12))
        let returned = drag.canMove(at: point)
        #expect(left && returned)
    }

    @Test func eachFavoriteRowUsesItsOwnCapacityAndLaterRowsUseTheDefault() {
        let sizes = FavoriteTileLayout.rowSizes(from: FavoriteTileLayout.encode(rowSizes: [3, 2]))
        #expect(sizes == [3, 2])
        #expect(FavoriteTileLayout.counts(for: 0, rowSizes: sizes, defaultColumns: 4) == [])
        #expect(FavoriteTileLayout.counts(for: 5, rowSizes: sizes, defaultColumns: 4) == [3, 2])
        #expect(FavoriteTileLayout.counts(for: 11, rowSizes: sizes, defaultColumns: 4) == [3, 2, 4, 2])
        #expect(FavoriteTileLayout.counts(for: 4, rowSizes: [1, 4], defaultColumns: 4) == [1, 3])
        #expect(FavoriteTileLayout.rowSizes(from: Data("[0,9]".utf8)) == [1, 4])
        #expect(FavoriteTileLayout.rowSizes(from: Data("invalid".utf8)).isEmpty)
    }

    @Test func anEmptyFavoritesBarAcceptsOnlyTheDraggedTabsOwnSpace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let other = session.addPersona(named: "Other")
        let otherSpace = try #require(session.spaces(in: other.id).first)
        let tab = session.openTab(url: URL(string: "about:blank#drop")!, in: space.id, select: false)
        let drag = SidebarDragState()
        let frame = CGRect(x: 5, y: 10, width: 230, height: 44)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        drag.favoriteBarFrames = [space.id: frame, otherSpace.id: frame]
        let owner = UUID()
        drag.begin(.tab(tab.id), frame: frame, grabbedAt: point, owner: owner)
        #expect(drag.favoriteDestination(for: tab, in: space, at: point, session: session) == space.id)
        #expect(drag.favoriteDestination(for: tab, in: otherSpace, at: point, session: session) == nil)
        #expect(drag.favoriteDestination(for: tab, in: space, at: .zero, session: session) == nil)
        let original = tab.webContents
        session.addFavorite(tab)
        #expect(session.favorites(in: space.resolvedPersonaID).map(\.url) == [tab.url])
        #expect(tab.webContents === original && session.tabs.contains(where: { $0 === tab }))
        #expect(drag.favoriteDestination(for: tab, in: space, at: point, session: session) == nil)
        drag.end(ownedBy: owner)
        #expect(drag.targetFavoriteSpaceID == nil)
    }

    @Test(arguments: [false, true]) func favoritingAcrossThePinDividerKeepsTheSourceInItsFolder(pinned: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let folder = session.makeFolder(in: space.id, pinned: pinned)
        let tabs = ["before", "page", "after"].map {
            session.openTab(url: URL(string: "about:blank#\($0)")!, in: space.id, select: false)
        }
        for tab in tabs { session.moveTab(tab.id, toFolder: folder.id) }
        let tab = tabs[1], contents = tab.webContents
        let saved = pinned ? SavedPage(url: URL(string: "about:blank#original")!, title: "Original title") : nil
        tab.savedPage = saved

        let slot = SidebarTabSlot.end(pinned: !pinned)
        var pins = session.folderTree.rows(in: space.id, pinned: true)
        var open = session.folderTree.rows(in: space.id, pinned: false)
        slot.project(tab, pinnedRows: &pins, openRows: &open)
        #expect((pinned ? open : pins).last?.id == tab.id)
        #expect(!(pinned ? pins : open).contains { $0.id == tab.id })

        session.moveTab(tabs[2], up: true)
        let another = session.openTab(url: URL(string: "about:blank#later")!, in: space.id, select: false)
        session.moveTab(another.id, toFolder: folder.id)
        session.addFavorite(tab)
        #expect(session.favorites(in: space.resolvedPersonaID).map(\.url) == [tab.url])
        #expect(session.folderTree.tabs(inFolder: folder.id).map(\.id) == [tabs[0].id, tabs[2].id, tab.id, another.id])
        #expect(tab.isPinned == pinned && tab.savedPage == saved && tab.folderID == folder.id && tab.webContents === contents)
    }

    @Test func releasingTheRowCommitsItsDisplayedSideOnlyWhileItsTargetStillExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let tab = session.openTab(url: URL(string: "about:blank#source")!, in: space.id, select: false)
        let target = session.openTab(url: URL(string: "about:blank#target")!, in: space.id, select: false)
        let neighbor = session.openTab(url: URL(string: "about:blank#neighbor")!, in: space.id, select: false)
        let slot = SidebarTabSlot.beside(target.id, folder: nil, pinned: false, after: true)
        // An independent move before release must not reverse the displayed side.
        session.moveTabToListEnd(tab.id, pinned: false)
        slot.commit(tab, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: false).map(\.id) == [target.id, tab.id, neighbor.id])

        SidebarTabSlot.end(pinned: true).commit(tab, in: space, session: session)
        let saved = try #require(tab.savedPage)
        #expect(tab.isPinned && saved.url == tab.url)
        session.togglePinned(target)
        slot.commit(tab, in: space, session: session)
        #expect(session.tabsOutsideFolders(in: space.id, pinned: true).contains { $0 === tab })
        _ = session.closeTab(target)
        slot.commit(tab, in: space, session: session)
        #expect(tab.isPinned && tab.savedPage == saved)
    }

    @Test func movingToAnEmptyPinnedListReportsOnlyAnActualChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = EngineRegistry()
        registry.register(SessionTestEngine())
        let session = try BrowserSession(testRegistry: registry, directory: directory)
        let space = try #require(session.spaces.first)
        let other = session.addPersona(named: "Other")
        let otherSpace = try #require(session.spaces(in: other.id).first)
        let tab = session.openTab(url: URL(string: "about:blank#pin"), in: space.id, select: false, engine: .webKit)
        let foreign = session.openTab(url: URL(string: "about:blank#other"), in: otherSpace.id, select: false, engine: .webKit)
        let contents = tab.webContents
        #expect(session.folderTree.rows(in: space.id, pinned: true).isEmpty)
        #expect(session.moveTabToListEnd(tab.id, pinned: true))
        #expect(!session.moveTabToListEnd(tab.id, pinned: true))
        #expect(tab.isPinned && tab.savedPage?.url == tab.url && tab.webContents === contents)
        #expect(!session.moveTab(tab.id, to: foreign))
        #expect(tab.spaceID == space.id && tab.personaID == space.resolvedPersonaID && !foreign.isPinned)
        #expect(session.moveTabToListEnd(tab.id, pinned: false))
        #expect(!session.moveTabToListEnd(tab.id, pinned: false) && !tab.isPinned && tab.savedPage == nil)
    }

    @Test func repairsClearParentsTheFileCannotKeep() {
        let work = folder("Work")
        let docs = folder("Docs", in: work)
        var missing = folder("Missing")
        missing.parentID = UUID()
        var elsewhere = folder("Elsewhere", space: otherSpaceID)
        elsewhere.parentID = work.id
        var open = folder("Open", pinned: false)
        open.parentID = work.id
        var itself = folder("Itself")
        itself.parentID = itself.id
        // A cycle of two: its first folder in the file leaves it, and the second stays inside the first.
        var first = folder("First")
        var second = folder("Second")
        first.parentID = second.id
        second.parentID = first.id
        let repaired = FolderTree.repairingParents(of: [work, docs, missing, elsewhere, open, itself, first, second])
        #expect(repaired.map(\.id) == [work, docs, missing, elsewhere, open, itself, first, second].map(\.id))
        #expect(repaired.map(\.parentID) == [nil, work.id, nil, nil, nil, nil, nil, first.id])
    }

    @Test(arguments: [false, true])
    func repairsLiftAFolderPastTheFourthLevelWithWhatItHolds(reversed: Bool) {
        var chain = [folder("1")]
        for level in 2...6 { chain.append(folder("\(level)", in: chain.last)) }
        let repaired = FolderTree.repairingParents(of: reversed ? chain.reversed() : chain)
        let parents = Dictionary(uniqueKeysWithValues: repaired.map { ($0.id, $0.parentID) })
        // The fifth folder goes to the top of the list and takes the sixth with it.
        #expect(chain.map { parents[$0.id] ?? nil } == [nil, chain[0].id, chain[1].id, chain[2].id, nil, chain[4].id])
        let tree = FolderTree(folders: repaired, tabs: [])
        #expect(chain.map { tree.level(of: $0.id) } == [1, 2, 3, 4, 1, 2])
    }

    // MARK: Rows

    @Test func rowsListFoldersBeforeTabsAtEveryLevelWithTheirDepths() {
        let work = folder("Work")
        let docs = folder("Docs", in: work)
        let archive = folder("Archive", in: work)
        let read = folder("Read")
        let later = folder("Later", pinned: false)
        let tabs = [tab("mail"), tab("notes", in: work), tab("spec", in: docs), tab("article", in: read), tab("draft", in: later), tab("news", pinned: false)]
        let tree = FolderTree(folders: [work, docs, read, archive, later], tabs: tabs)
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["Work", "  Docs", "    spec", "  Archive", "  notes", "Read", "  article", "mail"])
        #expect(outline(tree.rows(in: spaceID, pinned: false)) == ["Later", "  draft", "news"])
        #expect(names(tree.tabs(in: spaceID, pinned: true)) == ["spec", "notes", "article", "mail"])
        #expect(tree.rows(in: otherSpaceID, pinned: true).isEmpty)
        #expect(tree.ancestors(of: docs.id).map(\.id) == [work.id])
        #expect(tree.descendants(of: work.id).map(\.id) == [docs.id, archive.id])
        #expect([work, docs, read].map { tree.level(of: $0.id) } == [1, 2, 1])
    }

    @Test func aCollapsedFolderShowsOnlyThePickedTabsOneLevelIn() {
        var work = folder("Work")
        work.isCollapsed = true
        let docs = folder("Docs", in: work)
        let spec = tab("spec", in: docs)
        let notes = tab("notes", in: work)
        let outside = tab("mail")
        let collapsed = FolderTree(folders: [work, docs], tabs: [spec, notes, outside])
        #expect(outline(collapsed.rows(in: spaceID, pinned: true) { $0.id == spec.id }) == ["Work", "  spec", "mail"])
        #expect(outline(collapsed.rows(in: spaceID, pinned: true)) == ["Work", "mail"])
        // A collapsed ancestor hides a tab two levels down.
        #expect([spec, notes, outside].map(collapsed.isInCollapsedFolder) == [true, true, false])

        work.isCollapsed = false
        var collapsedDocs = docs
        collapsedDocs.isCollapsed = true
        let inner = FolderTree(folders: [work, collapsedDocs], tabs: [spec, notes, outside])
        #expect(outline(inner.rows(in: spaceID, pinned: true) { $0.id == spec.id }) == ["Work", "  Docs", "    spec", "  notes", "mail"])
        #expect([spec, notes, outside].map(inner.isInCollapsedFolder) == [true, false, false])
    }

    // MARK: Moves

    /// A(1) > B(2) > C(3) and X(1) > Y(2) at the top of the pinned list, with one folder of the open list and one of another space.
    private func movableFolders() -> (a: TabFolder, b: TabFolder, c: TabFolder, x: TabFolder, y: TabFolder, open: TabFolder, other: TabFolder) {
        let a = folder("A")
        let b = folder("B", in: a)
        let c = folder("C", in: b)
        let x = folder("X")
        let y = folder("Y", in: x)
        return (a, b, c, x, y, folder("Open", pinned: false), folder("Other", space: otherSpaceID))
    }

    @Test func foldersMoveOnlyWithinTheirListAndTheFourthLevel() {
        let f = movableFolders()
        let tree = FolderTree(folders: [f.a, f.b, f.c, f.x, f.y, f.open, f.other], tabs: [])
        // X holds Y, so it fits only where it and Y stay within four levels.
        #expect(tree.canMoveFolder(f.x.id, into: f.a.id))
        #expect(tree.canMoveFolder(f.x.id, into: f.b.id))
        #expect(!tree.canMoveFolder(f.x.id, into: f.c.id))
        #expect(tree.canMoveFolder(f.y.id, into: f.c.id))
        // Not into itself, a folder inside it, its own parent, another list, or another space.
        #expect(!tree.canMoveFolder(f.x.id, into: f.x.id))
        #expect(!tree.canMoveFolder(f.x.id, into: f.y.id))
        #expect(!tree.canMoveFolder(f.y.id, into: f.x.id))
        #expect(!tree.canMoveFolder(f.x.id, into: f.open.id))
        #expect(!tree.canMoveFolder(f.x.id, into: f.other.id))
        #expect(tree.canAddFolder(inside: f.c.id))
        #expect(tree.canAddFolder(inside: nil))
        let deepest = folder("D", in: f.c)
        #expect(!FolderTree(folders: [f.a, f.b, f.c, deepest], tabs: []).canAddFolder(inside: deepest.id))
    }

    @Test func agentFoldersStayAtTheRootUntilKeptAndTakeNoUserTabsOrFolders() {
        var agent = folder("Agent", pinned: false)
        agent.agentSessionID = UUID()
        let ordinary = folder("Ordinary", pinned: false)
        let userTab = tab("user", pinned: false)
        let agentTab = tab("owned", in: agent)
        var tree = FolderTree(folders: [agent, ordinary], tabs: [userTab, agentTab])
        #expect(!tree.canAddFolder(inside: agent.id))
        #expect(!tree.canMoveFolder(ordinary.id, into: agent.id))
        #expect(!tree.canMoveFolder(agent.id, into: ordinary.id))
        #expect(!tree.canMoveTab(userTab, into: agent.id))
        #expect(tree.moveTargets(forFolder: agent.id).isEmpty)
        #expect(tree.moveTargets(forFolder: ordinary.id).isEmpty)
        #expect(tree.moveTargets(forTab: userTab, pinned: false).map(\.id) == [ordinary.id])
        #expect(tree.dropTarget(for: ordinary.id, at: .onFolder(agent.id)) == nil)
        #expect(tree.dropTarget(for: ordinary.id, at: .onTab(agentTab.id)) == nil)
        #expect(tree.dropTarget(for: agent.id, at: .onFolder(ordinary.id)) == nil)
        #expect(tree.dropTarget(for: agent.id, at: .listEnd(spaceID: spaceID, pinned: false)) == nil)
        tree.moveFolder(agent.id, toSpace: otherSpaceID)
        #expect(tree.folder(agent.id)?.spaceID == spaceID)

        agent.agentSessionID = nil
        tree = FolderTree(folders: [agent, ordinary], tabs: [userTab, agentTab])
        #expect(tree.canAddFolder(inside: agent.id))
        #expect(tree.canMoveFolder(agent.id, into: ordinary.id))
        #expect(tree.canMoveTab(userTab, into: agent.id))
    }

    /// Each target as its name, with a mark for one that takes no item, after two spaces for each target that holds it.
    private func outline(_ targets: [FolderTree.MoveTarget], depth: Int = 0) -> [String] {
        targets.flatMap { target in
            [String(repeating: "  ", count: depth) + target.folder.name + (target.takesItem ? "" : " (holds)")] + outline(target.inside, depth: depth + 1)
        }
    }

    @Test func moveToFolderListsTheAllowedTargetsAsTheTreeNestsThem() {
        let f = movableFolders()
        let inB = tab("page", in: f.b)
        let tree = FolderTree(folders: [f.a, f.b, f.c, f.x, f.y, f.open, f.other], tabs: [inB])
        // X's own tree is left out, and C is too deep for X and Y.
        #expect(outline(tree.moveTargets(forFolder: f.x.id)) == ["A", "  B"])
        #expect(outline(tree.moveTargets(forFolder: f.y.id)) == ["A", "  B", "    C"])
        #expect(outline(tree.moveTargets(forFolder: f.open.id)).isEmpty)
        // A tab's own folder stays in the menu for the folders inside it, and the other list's folders are listed apart.
        #expect(outline(tree.moveTargets(forTab: inB, pinned: true)) == ["A", "  B (holds)", "    C", "X", "  Y"])
        #expect(outline(tree.moveTargets(forTab: inB, pinned: false)) == ["Open"])
        #expect(tree.canMoveTab(inB, into: f.open.id))
        #expect(!tree.canMoveTab(inB, into: f.b.id))
        #expect(!tree.canMoveTab(inB, into: f.other.id))
    }

    @Test func movingAFolderTakesWhatItHoldsAndMovingOutGoesUpOneLevel() {
        let f = movableFolders()
        let inY = tab("page", in: f.y)
        let inX = tab("first", in: f.x)
        var tree = FolderTree(folders: [f.a, f.b, f.c, f.x, f.y], tabs: [inX, inY])
        tree.moveFolder(f.x.id, into: f.c.id)
        #expect(tree.folder(f.x.id)?.parentID == nil)
        tree.moveFolder(f.x.id, into: f.b.id)
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  B", "    C", "    X", "      Y", "        page", "      first"])
        #expect([f.x, f.y].map { tree.level(of: $0.id) } == [3, 4])
        // Out of B, X goes into A right after B.
        tree.moveFolderOut(f.x.id)
        #expect(tree.subfolders(of: f.a.id).map(\.id) == [f.b.id, f.x.id])
        // A tab out of Y goes first among X's tabs, then out of X first among A's tabs.
        tree.moveTabOut(inY)
        #expect(inY.folderID == f.x.id)
        #expect(names(tree.tabs(inFolder: f.x.id)) == ["page", "first"])
        tree.moveFolderOut(f.x.id)
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  B", "    C", "X", "  Y", "  page", "  first"])
    }

    // MARK: Delete Folder

    @Test func deleteFolderMovesItsFoldersAndTabsUpALevel() {
        let parent = folder("Parent")
        let deleted = folder("Deleted", in: parent)
        let kept = folder("Kept", in: deleted)
        let sibling = folder("Sibling", in: parent)
        let tabs = [tab("mail"), tab("parent tab", in: parent), tab("one", in: deleted), tab("kept tab", in: kept), tab("two", in: deleted)]
        var tree = FolderTree(folders: [parent, deleted, kept, sibling], tabs: tabs)
        tree.deleteFolder(deleted.id)
        // Its folder takes its place before Sibling, and its tabs go first among Parent's tabs.
        #expect(tree.folders.map(\.name) == ["Parent", "Kept", "Sibling"])
        #expect(tree.folder(kept.id)?.parentID == parent.id)
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["Parent", "  Kept", "    kept tab", "  Sibling", "  one", "  two", "  parent tab", "mail"])
        // At the top level, the folders go to the top of the list and the tabs first among the tabs outside folders.
        tree.deleteFolder(parent.id)
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["Kept", "  kept tab", "Sibling", "one", "two", "parent tab", "mail"])
        #expect(tree.folders.allSatisfy { $0.parentID == nil })
    }

    // MARK: Dragging

    @Test func dropTargetPlacesAFolderBetweenRowsAtEachLevel() {
        let a = folder("A")
        let b = folder("B", in: a)
        let c = folder("C", in: b)
        let x = folder("X")
        let y = folder("Y")
        let open = folder("Open", pinned: false)
        let inA = tab("a", in: a)
        let inB = tab("b", in: b)
        let inC = tab("c", in: c)
        let mail = tab("mail")
        let news = tab("news", pinned: false)
        var tree = FolderTree(folders: [a, b, c, x, y, open], tabs: [inA, inB, inC, mail, news])
        // Above a folder's row, Y goes before that folder at its level.
        #expect(tree.dropTarget(for: y.id, at: .aboveFolder(a.id)) == .between(parentID: nil, beforeID: a.id))
        #expect(tree.dropTarget(for: y.id, at: .aboveFolder(b.id)) == .between(parentID: a.id, beforeID: b.id))
        #expect(tree.dropTarget(for: y.id, at: .aboveFolder(c.id)) == .between(parentID: b.id, beforeID: c.id))
        // On a tab's row, it goes last among the folders of the tab's folder, which in C is the fourth level.
        #expect(tree.dropTarget(for: y.id, at: .onTab(inC.id)) == .between(parentID: c.id, beforeID: nil))
        #expect(tree.dropTarget(for: y.id, at: .onTab(inB.id)) == .between(parentID: b.id, beforeID: nil))
        #expect(tree.dropTarget(for: y.id, at: .onTab(inA.id)) == .between(parentID: a.id, beforeID: nil))
        // Outside folders and on the list's closing row, it goes last at the top of the list, which changes nothing for Y, already there, nor for X above Y.
        #expect(tree.dropTarget(for: x.id, at: .onTab(mail.id)) == .between(parentID: nil, beforeID: nil))
        #expect(tree.dropTarget(for: x.id, at: .listEnd(spaceID: spaceID, pinned: true)) == .between(parentID: nil, beforeID: nil))
        #expect(tree.dropTarget(for: y.id, at: .onTab(mail.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .aboveFolder(y.id)) == nil)
        // The open list and another space's list refuse it.
        #expect(tree.dropTarget(for: x.id, at: .aboveFolder(open.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .onFolder(open.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .onTab(news.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .listEnd(spaceID: spaceID, pinned: false)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .listEnd(spaceID: otherSpaceID, pinned: true)) == nil)

        tree.moveFolder(y.id, to: .between(parentID: a.id, beforeID: b.id))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  Y", "  B", "    C", "      c", "    b", "  a", "X", "mail"])
        tree.moveFolder(y.id, to: .between(parentID: c.id, beforeID: nil))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  B", "    C", "      Y", "      c", "    b", "  a", "X", "mail"])
        #expect(tree.level(of: y.id) == 4)
        tree.moveFolder(y.id, to: .between(parentID: nil, beforeID: a.id))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["Y", "A", "  B", "    C", "      c", "    b", "  a", "X", "mail"])
    }

    @Test func dropTargetOnAFolderRowPutsTheFolderLastInsideIt() {
        let a = folder("A")
        let b = folder("B", in: a)
        let c = folder("C", in: a)
        let x = folder("X")
        var tree = FolderTree(folders: [a, b, c, x], tabs: [])
        #expect(tree.dropTarget(for: x.id, at: .onFolder(b.id)) == .into(b.id))
        #expect(tree.dropTarget(for: x.id, at: .onFolder(a.id)) == .into(a.id))
        // Its own parent's row takes it while another folder follows it there, which puts it last.
        #expect(tree.dropTarget(for: b.id, at: .onFolder(a.id)) == .into(a.id))
        #expect(tree.dropTarget(for: c.id, at: .onFolder(a.id)) == nil)
        tree.moveFolder(x.id, to: .into(a.id))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  B", "  C", "  X"])
        tree.moveFolder(b.id, to: .into(a.id))
        #expect(tree.subfolders(of: a.id).map(\.name) == ["C", "X", "B"])
        // A refused target changes nothing.
        tree.moveFolder(a.id, to: .into(b.id))
        #expect(tree.folder(a.id)?.parentID == nil)
    }

    @Test func dropTargetRefusesTheDraggedFoldersOwnTree() {
        let a = folder("A")
        let b = folder("B", in: a)
        let c = folder("C", in: b)
        let inC = tab("c", in: c)
        let tree = FolderTree(folders: [a, b, c], tabs: [inC])
        let positions: [FolderTree.DropPosition] = [.aboveFolder(a.id), .onFolder(a.id), .aboveFolder(b.id), .onFolder(b.id), .aboveFolder(c.id), .onFolder(c.id), .onTab(inC.id)]
        for position in positions {
            #expect(tree.dropTarget(for: a.id, at: position) == nil)
        }
        // B can still leave A for the top of the list, taking C along.
        #expect(tree.dropTarget(for: b.id, at: .aboveFolder(a.id)) == .between(parentID: nil, beforeID: a.id))
        #expect(tree.dropTarget(for: b.id, at: .onFolder(c.id)) == nil)
    }

    @Test func dropTargetKeepsAFolderAndTheFoldersItHoldsWithinTheFourthLevel() {
        let a = folder("A")
        let b = folder("B", in: a)
        let c = folder("C", in: b)
        let d = folder("D", in: c)
        let x = folder("X")
        let y = folder("Y", in: x)
        let z = folder("Z")
        let inC = tab("c", in: c)
        let inD = tab("d", in: d)
        let tree = FolderTree(folders: [a, b, c, d, x, y, z], tabs: [inC, inD])
        // Z fits at the fourth level, beside D, but not inside D.
        #expect(tree.dropTarget(for: z.id, at: .aboveFolder(d.id)) == .between(parentID: c.id, beforeID: d.id))
        #expect(tree.dropTarget(for: z.id, at: .onTab(inC.id)) == .between(parentID: c.id, beforeID: nil))
        #expect(tree.dropTarget(for: z.id, at: .onFolder(c.id)) == .into(c.id))
        #expect(tree.dropTarget(for: z.id, at: .onFolder(d.id)) == nil)
        #expect(tree.dropTarget(for: z.id, at: .onTab(inD.id)) == nil)
        // X takes Y along, so it fits only where Y stays within the fourth level.
        #expect(tree.dropTarget(for: x.id, at: .aboveFolder(c.id)) == .between(parentID: b.id, beforeID: c.id))
        #expect(tree.dropTarget(for: x.id, at: .onFolder(b.id)) == .into(b.id))
        #expect(tree.dropTarget(for: x.id, at: .aboveFolder(d.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .onFolder(c.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .onTab(inC.id)) == nil)
    }

    @Test func dropTargetKeepsTheDraggedRowOutOfCollapsedFolders() {
        var a = folder("A")
        a.isCollapsed = true
        let b = folder("B", in: a)
        let inA = tab("a", in: a)
        let inB = tab("b", in: b)
        let x = folder("X")
        let tree = FolderTree(folders: [a, b, x], tabs: [inA, inB])
        // A collapsed folder's row takes the folder, but the tabs it still shows, as the selected tab, and the folders it hides place nothing.
        #expect(tree.dropTarget(for: x.id, at: .onFolder(a.id)) == .into(a.id))
        #expect(tree.dropTarget(for: x.id, at: .onTab(inA.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .onTab(inB.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .aboveFolder(b.id)) == nil)
        #expect(tree.dropTarget(for: x.id, at: .onFolder(b.id)) == nil)
    }

    @Test func aDraggedFolderShowsItsRowAlone() {
        let a = folder("A")
        let b = folder("B", in: a)
        let selected = tab("selected", in: b)
        let other = tab("other", in: a)
        let mail = tab("mail")
        let tree = FolderTree(folders: [a, b], tabs: [selected, other, mail])
        // Its folders and tabs hide, the selected tab among them.
        #expect(outline(tree.rows(in: spaceID, pinned: true, hidingContentsOf: a.id) { $0.id == selected.id }) == ["A", "mail"])
        #expect(outline(tree.rows(in: spaceID, pinned: true, hidingContentsOf: b.id)) == ["A", "  B", "  other", "mail"])
    }

    @Test func aFolderDroppedOnAnotherSpaceCarriesWhatItHolds() {
        let a = folder("A")
        let b = folder("B", in: a)
        let c = folder("C", in: b)
        let later = folder("Later", pinned: false)
        let there = folder("There", space: otherSpaceID)
        let inA = tab("a", in: a)
        let inB = tab("b", in: b)
        let inC = tab("c", in: c)
        let inLater = tab("later", in: later)
        var tree = FolderTree(folders: [a, b, c, later, there], tabs: [inA, inB, inC, inLater])
        tree.moveFolder(b.id, toSpace: otherSpaceID)
        // B leaves A for the top of the other space's pinned list, after its folders, with C and the tabs inside them.
        #expect(outline(tree.rows(in: otherSpaceID, pinned: true)) == ["There", "B", "  C", "    c", "  b"])
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  a"])
        #expect(tree.folder(c.id)?.parentID == b.id)
        #expect([inB, inC].allSatisfy { $0.spaceID == otherSpaceID && $0.isPinned })
        #expect(inA.spaceID == spaceID)
        // An open folder stays among the open tabs.
        tree.moveFolder(later.id, toSpace: otherSpaceID)
        #expect(outline(tree.rows(in: otherSpaceID, pinned: false)) == ["Later", "  later"])
        #expect(inLater.spaceID == otherSpaceID && !inLater.isPinned)
    }
}
