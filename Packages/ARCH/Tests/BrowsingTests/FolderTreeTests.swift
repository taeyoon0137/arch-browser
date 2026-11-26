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

    /// Folders whose parents lead back to themselves, which no loaded file or change holds, leave the walks down the tree finite: the rows, the tabs inside, the descendants, the moves, and a drop on another space build without the cycle, which the rows leave out, instead of recursing until the app stops.
    @Test func aCycleOfParentsLeavesEveryWalkDownTheTreeFinite() {
        let work = folder("Work")
        var first = folder("First"), second = folder("Second", in: first), itself = folder("Itself")
        first.parentID = second.id
        itself.parentID = itself.id
        var below = folder("Below")
        below.parentID = second.id
        let inside = tab("Inside", in: second), loose = tab("Loose")
        var tree = FolderTree(folders: [work, first, second, itself, below], tabs: [inside, loose])
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["Work", "Loose"])
        #expect(tree.descendants(of: first.id).isEmpty && tree.tabs(inside: second.id).map(\.id) == [inside.id])
        #expect(names(tree.tabs(in: spaceID, pinned: true)) == ["Loose"] && tree.moveTargets(forFolder: work.id).isEmpty)
        #expect(tree.ancestors(of: below.id).count <= 5 && !tree.canMoveFolder(work.id, into: first.id))
        tree.moveFolder(first.id, toSpace: otherSpaceID)
        #expect(tree.folders.first { $0.id == first.id }?.spaceID == otherSpaceID)
        tree.deleteFolder(second.id)
        #expect(tree.folders.count == 4)
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

    @Test(arguments: [false, true])
    func collapsingAnAncestorKeepsTheSelectedRowsIdentityWhileItsDepthChanges(pinned: Bool) {
        var work = folder("Work", pinned: pinned)
        let docs = folder("Docs", in: work)
        let first = tab("first", in: docs)
        let selected = tab("selected", in: docs)
        let last = tab("last", in: work)
        let outside = tab("outside", pinned: pinned)
        let tabs = [first, selected, last, outside]
        let expanded = FolderTree(folders: [work, docs], tabs: tabs).rows(in: spaceID, pinned: pinned) { $0.id == selected.id }

        work.isCollapsed = true
        let collapsed = FolderTree(folders: [work, docs], tabs: tabs).rows(in: spaceID, pinned: pinned) { $0.id == selected.id }
        #expect(expanded.map(\.id) == [work.id, docs.id, first.id, selected.id, last.id, outside.id])
        #expect(collapsed.map(\.id) == [work.id, selected.id, outside.id])
        #expect(expanded.first { $0.id == selected.id }?.depth == 2)
        #expect(collapsed.first { $0.id == selected.id }?.depth == 1)
        #expect(collapsed.filter { $0.id == selected.id }.count == 1)
        if case .tab(let retained, _) = collapsed[1] { #expect(retained === selected) }
        else { Issue.record("The selected child must remain a tab row") }
        #expect(outside.folderID == nil && selected.folderID == docs.id)
    }

    @Test(arguments: [false, true])
    func changingSelectionRemovesOrReplacesOnlyTheRetainedChild(pinned: Bool) {
        var work = folder("Work", pinned: pinned)
        work.isCollapsed = true
        let docs = folder("Docs", in: work)
        let first = tab("first", in: docs)
        let second = tab("second", in: work)
        let unrelated = folder("Unrelated", pinned: pinned)
        let sibling = tab("sibling", in: unrelated)
        let outside = tab("outside", pinned: pinned)
        let tree = FolderTree(folders: [work, docs, unrelated], tabs: [first, second, sibling, outside])
        func rows(selecting id: UUID?) -> [UUID] {
            tree.rows(in: spaceID, pinned: pinned) { $0.id == id }.map(\.id)
        }
        #expect(rows(selecting: first.id) == [work.id, first.id, unrelated.id, sibling.id, outside.id])
        #expect(rows(selecting: second.id) == [work.id, second.id, unrelated.id, sibling.id, outside.id])
        // A favorite's tab lives outside the tree, and an empty page has no selected ID.
        for selection in [outside.id, UUID(), nil] {
            #expect(rows(selecting: selection) == [work.id, unrelated.id, sibling.id, outside.id])
        }
        #expect(tree.folder(work.id)?.isCollapsed == true)
        #expect(first.folderID == docs.id && second.folderID == work.id)
    }

    @Test func theLastTabsPreviewRevealsItsEmptyFolderBeforeCommitAndRestoresItOnReturn() {
        let work = folder("Work")
        let notes = tab("notes", in: work)
        let tree = FolderTree(folders: [work], tabs: [notes])
        var pinned = tree.rows(in: spaceID, pinned: true)
        var open = tree.rows(in: spaceID, pinned: false)
        #expect(FolderTree.emptyFolderIDs(in: pinned).isEmpty)

        SidebarTabSlot.end(pinned: false).project(notes, pinnedRows: &pinned, openRows: &open)
        #expect(FolderTree.emptyFolderIDs(in: pinned) == Set([work.id]))
        #expect(outline(open) == ["notes"])
        #expect(notes.folderID == work.id && notes.isPinned)

        // Returning to the source clears the preview and restores the committed rows.
        pinned = tree.rows(in: spaceID, pinned: true)
        #expect(outline(pinned) == ["Work", "  notes"])
        #expect(FolderTree.emptyFolderIDs(in: pinned).isEmpty)
    }

    @Test(arguments: [false, true])
    func aTabPreviewUsesItsDestinationDepthBeforeItsFolderChanges(after: Bool) {
        let work = folder("Work")
        let read = folder("Read")
        let notes = tab("notes", in: work)
        let article = tab("article", in: read)
        let tree = FolderTree(folders: [work, read], tabs: [notes, article])
        var pinned = tree.rows(in: spaceID, pinned: true)
        var open = tree.rows(in: spaceID, pinned: false)

        SidebarTabSlot.beside(article.id, folder: read.id, pinned: true, after: after)
            .project(notes, pinnedRows: &pinned, openRows: &open)
        #expect(FolderTree.emptyFolderIDs(in: pinned) == Set([work.id]))
        #expect(outline(pinned) == ["Work", "Read"] + (after ? ["  article", "  notes"] : ["  notes", "  article"]))
        #expect(notes.folderID == work.id)
    }

    @Test func theLastChildFoldersCrossListPreviewRevealsItsParentWithoutChangingTheTree() {
        let work = folder("Work")
        let docs = folder("Docs", in: work)
        let later = folder("Later", pinned: false)
        let spec = tab("spec", in: docs)
        let tree = FolderTree(folders: [work, docs, later], tabs: [spec])
        let target = FolderTree.DropTarget.between(parentID: later.id, beforeID: nil, pinned: false)
        let preview = tree.previewingMove(of: docs.id, to: target)
        let pinned = preview.rows(in: spaceID, pinned: true, hidingContentsOf: docs.id)
        let open = preview.rows(in: spaceID, pinned: false, hidingContentsOf: docs.id)

        #expect(outline(pinned) == ["Work"])
        #expect(outline(open) == ["Later", "  Docs"])
        #expect(FolderTree.emptyFolderIDs(in: pinned, hidingContentsOf: docs.id) == Set([work.id]))
        #expect(FolderTree.emptyFolderIDs(in: open, hidingContentsOf: docs.id).isEmpty)
        #expect(tree.folder(docs.id)?.parentID == work.id && spec.isPinned)
        #expect(FolderTree.emptyFolderIDs(in: tree.rows(in: spaceID, pinned: true)).isEmpty)
        #expect(FolderTree.emptyFolderIDs(in: tree.rows(in: spaceID, pinned: false)) == Set([later.id]))
    }

    @Test func collapsedAndDraggedFoldersDoNotShowEmptyRowsForHiddenContents() {
        var collapsed = folder("Collapsed")
        collapsed.isCollapsed = true
        let dragged = folder("Dragged")
        let empty = folder("Empty")
        let selected = tab("selected", in: collapsed)
        let hidden = tab("hidden", in: dragged)
        let tree = FolderTree(folders: [collapsed, dragged, empty], tabs: [selected, hidden])
        let rows = tree.rows(in: spaceID, pinned: true, hidingContentsOf: dragged.id)
        let showingSelected = tree.rows(in: spaceID, pinned: true, hidingContentsOf: dragged.id) { $0.id == selected.id }

        #expect(outline(rows) == ["Collapsed", "Dragged", "Empty"])
        #expect(FolderTree.emptyFolderIDs(in: rows, hidingContentsOf: dragged.id) == Set([empty.id]))
        #expect(FolderTree.emptyFolderIDs(in: showingSelected, hidingContentsOf: dragged.id) == Set([empty.id]))
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
        // The open list accepts it across the divider at the same positions; another space's list refuses it.
        #expect(tree.dropTarget(for: x.id, at: .aboveFolder(open.id)) == .between(parentID: nil, beforeID: open.id, pinned: false))
        #expect(tree.dropTarget(for: x.id, at: .onFolder(open.id)) == .into(open.id))
        #expect(tree.dropTarget(for: x.id, at: .onTab(news.id)) == .between(parentID: nil, beforeID: nil, pinned: false))
        #expect(tree.dropTarget(for: x.id, at: .listEnd(spaceID: spaceID, pinned: false)) == .between(parentID: nil, beforeID: nil, pinned: false))
        #expect(tree.dropTarget(for: x.id, at: .listEnd(spaceID: otherSpaceID, pinned: true)) == nil)
        #expect(!tree.crossesList(x.id, to: .between(parentID: a.id, beforeID: nil)))
        #expect(tree.crossesList(x.id, to: .into(open.id)))

        tree.moveFolder(y.id, to: .between(parentID: a.id, beforeID: b.id))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  Y", "  B", "    C", "      c", "    b", "  a", "X", "mail"])
        tree.moveFolder(y.id, to: .between(parentID: c.id, beforeID: nil))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["A", "  B", "    C", "      Y", "      c", "    b", "  a", "X", "mail"])
        #expect(tree.level(of: y.id) == 4)
        tree.moveFolder(y.id, to: .between(parentID: nil, beforeID: a.id))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["Y", "A", "  B", "    C", "      c", "    b", "  a", "X", "mail"])
    }

    /// A folder dragged across the divider moves with all its contents: its folders join the destination list, its tabs pin or unpin without changing folders or order, and the drop preserves its position among the destination folders. Before release, the preview places only folders, so hidden tabs keep their state.
    @Test func aFolderDraggedAcrossTheDividerPinsOrUnpinsWhatItHolds() {
        let a = folder("A")
        let b = folder("B", in: a)
        var later = folder("Later", pinned: false), read = folder("Read", pinned: false)
        later.isCollapsed = true
        read.isCollapsed = true
        let inA = tab("a", in: a)
        let inB = tab("b", in: b)
        let mail = tab("mail")
        let news = tab("news", pinned: false)
        var tree = FolderTree(folders: [a, b, later, read], tabs: [inA, inB, mail, news])
        let unpin = FolderTree.DropTarget.between(parentID: nil, beforeID: read.id, pinned: false)
        #expect(tree.dropTarget(for: a.id, at: .aboveFolder(read.id)) == unpin)
        let preview = tree.previewingMove(of: a.id, to: unpin)
        #expect(outline(preview.rows(in: spaceID, pinned: false, hidingContentsOf: a.id)) == ["Later", "A", "Read", "news"])
        #expect(outline(preview.rows(in: spaceID, pinned: true)) == ["mail"])
        #expect(inA.isPinned && inB.isPinned && tree.folder(a.id)?.isPinned == true)

        tree.moveFolder(a.id, to: unpin)
        #expect(outline(tree.rows(in: spaceID, pinned: false)) == ["Later", "A", "  B", "    b", "  a", "Read", "news"])
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["mail"])
        #expect([a, b].allSatisfy { tree.folder($0.id)?.isPinned == false } && !inA.isPinned && !inB.isPinned)
        #expect(inA.folderID == a.id && inB.folderID == b.id)

        // Dropping onto a pinned folder's row or the divider pins it and its contents again.
        let x = folder("X")
        tree = FolderTree(folders: tree.folders + [x], tabs: tree.tabs)
        #expect(tree.dropTarget(for: a.id, at: .onFolder(x.id)) == .into(x.id))
        #expect(tree.dropTarget(for: a.id, at: .listEnd(spaceID: spaceID, pinned: true)) == .between(parentID: nil, beforeID: nil, pinned: true))
        tree.moveFolder(a.id, to: .into(x.id))
        #expect(outline(tree.rows(in: spaceID, pinned: true)) == ["X", "  A", "    B", "      b", "    a", "mail"])
        #expect(inA.isPinned && inB.isPinned)
    }

    @Test func aFolderHoldingAnAgentsTabStaysInItsList() {
        let open = folder("Open", pinned: false)
        let owned = tab("owned", in: open)
        let ownerID = UUID()
        owned.agentOwnerOfFolder = { _ in ownerID }
        let tree = FolderTree(folders: [open], tabs: [owned])
        #expect(tree.dropTarget(for: open.id, at: .listEnd(spaceID: spaceID, pinned: true)) == nil)
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
