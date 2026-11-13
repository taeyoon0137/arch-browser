// Nested folders (`docs/bookmarks.md`, Nested folders; bookmark rule 6): the parents that `session.json` repairs, the sidebar's rows with their depths, collapsed folders at any level, the moves that Move to Folder allows and refuses, Move Out of Folder, and Delete Folder keeping what a folder held. Tabs run on `PageStub`, without a session or an engine, so the menus, the indented rows, and the session's calls are regression check 70.
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
}
