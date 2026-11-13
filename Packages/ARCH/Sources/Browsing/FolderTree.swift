// How folders nest in a space's pinned and open lists (bookmark rule 6, `docs/bookmarks.md`, Nested folders): which folder holds which, the sidebar's rows with their depths, the moves that Move to Folder and Move Out of Folder make, Delete Folder, and the repairs that `session.json` gets. The session and the views ask a `FolderTree` instead of walking `TabFolder.parentID`.
import Foundation

/// The session's folders and tabs as the sidebar nests them. A folder sits at the top of its space's pinned or open list or in another folder of that list, at most `maximumLevel` levels deep, and lists its folders before its tabs, as each list does. It is built from the session's lists for each use; its mutating methods change its copies of the lists and the moved tabs' folders, and the session takes the lists back.
struct FolderTree {
    /// The deepest level a folder can sit at; a folder at the top of its list is at level 1. Four levels at 12 points each leave the 240-point sidebar room for names.
    static let maximumLevel = 4

    /// The folders, in sidebar order among the folders of each parent and list.
    private(set) var folders: [TabFolder]
    /// The tabs, in sidebar order among the tabs of each folder and list.
    private(set) var tabs: [Tab]
    private let foldersByID: [UUID: TabFolder]
    private let subfoldersByParent: [UUID: [TabFolder]]
    private let tabsByFolder: [UUID: [Tab]]

    init(folders: [TabFolder], tabs: [Tab]) {
        self.folders = folders
        self.tabs = tabs
        foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        subfoldersByParent = Dictionary(grouping: folders.filter { $0.parentID != nil }) { $0.parentID! }
        tabsByFolder = Dictionary(grouping: tabs.filter { $0.folderID != nil }) { $0.folderID! }
    }

    // MARK: Structure

    func folder(_ id: UUID?) -> TabFolder? {
        id.flatMap { foldersByID[$0] }
    }

    /// The folders at the top of a space's pinned or open list.
    func topFolders(in spaceID: UUID, pinned: Bool) -> [TabFolder] {
        folders.filter { $0.spaceID == spaceID && $0.isPinned == pinned && $0.parentID == nil }
    }

    /// The folders directly inside a folder.
    func subfolders(of id: UUID) -> [TabFolder] {
        subfoldersByParent[id] ?? []
    }

    /// The tabs directly inside a folder.
    func tabs(inFolder id: UUID) -> [Tab] {
        tabsByFolder[id] ?? []
    }

    /// Every tab inside a folder, at any depth, in sidebar order: the tabs inside each of its folders, then its own.
    func tabs(inside id: UUID) -> [Tab] {
        subfolders(of: id).flatMap { tabs(inside: $0.id) } + tabs(inFolder: id)
    }

    /// A space's pinned or open tabs outside folders. A small window's tab, which is in no folder, is left out until it moves to a main window.
    func tabsOutsideFolders(in spaceID: UUID, pinned: Bool) -> [Tab] {
        tabs.filter { $0.spaceID == spaceID && $0.isPinned == pinned && $0.folderID == nil && $0.isListedInSidebar }
    }

    /// A space's pinned or open tabs in sidebar order, whether or not their folders are collapsed: the tabs inside each folder at the top of the list, then the tabs outside folders.
    func tabs(in spaceID: UUID, pinned: Bool) -> [Tab] {
        topFolders(in: spaceID, pinned: pinned).flatMap { tabs(inside: $0.id) } + tabsOutsideFolders(in: spaceID, pinned: pinned)
    }

    /// The folders that hold a folder, nearest first.
    func ancestors(of id: UUID) -> [TabFolder] {
        var ancestors: [TabFolder] = []
        var current = folder(id)?.parentID
        // `repairingParents` leaves no cycle in a loaded file, and no change makes one; the count bounds the walk all the same.
        while let parent = folder(current), ancestors.count < folders.count {
            ancestors.append(parent)
            current = parent.parentID
        }
        return ancestors
    }

    /// Every folder inside a folder, at any depth, in sidebar order.
    func descendants(of id: UUID) -> [TabFolder] {
        subfolders(of: id).flatMap { [$0] + descendants(of: $0.id) }
    }

    /// 1 for a folder at the top of its list, and one more for each folder that holds it.
    func level(of id: UUID) -> Int {
        ancestors(of: id).count + 1
    }

    /// How many levels a folder and the folders inside it take: 1 for a folder without folders.
    private func height(of id: UUID) -> Int {
        1 + (subfolders(of: id).map { height(of: $0.id) }.max() ?? 0)
    }

    /// Whether a tab sits in a collapsed folder or in a folder that a collapsed folder holds, which shows it in the sidebar only while it is selected.
    func isInCollapsedFolder(_ tab: Tab) -> Bool {
        guard let folder = folder(tab.folderID) else { return false }
        return folder.isCollapsed || ancestors(of: folder.id).contains(where: \.isCollapsed)
    }

    // MARK: Rows

    /// A row of a space's pinned or open list: a folder or a tab, with how many folders hold it. The sidebar indents a row 12 points for each.
    enum Row: Identifiable {
        case folder(TabFolder, depth: Int)
        case tab(Tab, depth: Int)

        var id: UUID {
            switch self {
            case .folder(let folder, _): return folder.id
            case .tab(let tab, _): return tab.id
            }
        }

        var depth: Int {
            switch self {
            case .folder(_, let depth), .tab(_, let depth): return depth
            }
        }
    }

    /// A space's pinned or open list as the sidebar shows it: each folder's row followed by the rows of its folders and its tabs, then the tabs outside folders. A collapsed folder hides everything inside it but the tabs that `shows` picks, such as the selected tab, which show one level in from the folder.
    func rows(in spaceID: UUID, pinned: Bool, showingInCollapsedFolders shows: (Tab) -> Bool = { _ in false }) -> [Row] {
        var rows: [Row] = []
        func add(_ folder: TabFolder, depth: Int) {
            rows.append(.folder(folder, depth: depth))
            if folder.isCollapsed {
                rows += tabs(inside: folder.id).filter(shows).map { .tab($0, depth: depth + 1) }
            } else {
                subfolders(of: folder.id).forEach { add($0, depth: depth + 1) }
                rows += tabs(inFolder: folder.id).map { .tab($0, depth: depth + 1) }
            }
        }
        topFolders(in: spaceID, pinned: pinned).forEach { add($0, depth: 0) }
        return rows + tabsOutsideFolders(in: spaceID, pinned: pinned).map { .tab($0, depth: 0) }
    }

    // MARK: Moves

    /// Whether a new folder can go inside `id`, as New Folder Inside and Add to New Folder put it: in a folder below the fourth level, or at the top of a list for nil. III.22 refuses live folders here, and VII.12 agent folders.
    func canAddFolder(inside id: UUID?) -> Bool {
        guard let id else { return true }
        return folder(id) != nil && level(of: id) < Self.maximumLevel
    }

    /// Whether Move to Folder can move a folder into `parentID`: another folder of its space and list that is not its parent, itself, or a folder inside it, where the folder and the folders it holds stay within the fourth level. III.22 adds live folders to the refused targets, and VII.12 agent folders.
    func canMoveFolder(_ id: UUID, into parentID: UUID) -> Bool {
        guard let moved = folder(id), let parent = folder(parentID), parentID != id, moved.parentID != parentID,
              parent.spaceID == moved.spaceID, parent.isPinned == moved.isPinned, !ancestors(of: parentID).contains(where: { $0.id == id }) else { return false }
        return level(of: parentID) + height(of: id) <= Self.maximumLevel
    }

    /// Whether Move to Folder can move a tab into a folder: one of the tab's space, in either list, other than its own. The tab takes the folder's list.
    func canMoveTab(_ tab: Tab, into folderID: UUID) -> Bool {
        guard let target = folder(folderID) else { return false }
        return target.spaceID == tab.spaceID && tab.folderID != folderID
    }

    /// A folder that Move to Folder lists: whether the item can move into it, and the folders inside it that the menu lists in turn. A folder that takes no item and holds none that does is left out.
    struct MoveTarget: Identifiable {
        let folder: TabFolder
        let takesItem: Bool
        let inside: [MoveTarget]

        var id: UUID { folder.id }
    }

    /// Move to Folder's targets for a folder: the folders of its list that it can move into, as the tree nests them.
    func moveTargets(forFolder id: UUID) -> [MoveTarget] {
        guard let moved = folder(id) else { return [] }
        return moveTargets(in: moved.spaceID, pinned: moved.isPinned) { canMoveFolder(id, into: $0.id) }
    }

    /// Move to Folder's targets for a tab among the folders of one of its space's lists.
    func moveTargets(forTab tab: Tab, pinned: Bool) -> [MoveTarget] {
        guard let spaceID = tab.spaceID else { return [] }
        return moveTargets(in: spaceID, pinned: pinned) { canMoveTab(tab, into: $0.id) }
    }

    private func moveTargets(in spaceID: UUID, pinned: Bool, taking takes: (TabFolder) -> Bool) -> [MoveTarget] {
        func target(_ folder: TabFolder) -> MoveTarget? {
            let inside = subfolders(of: folder.id).compactMap { target($0) }
            let takesItem = takes(folder)
            return takesItem || !inside.isEmpty ? MoveTarget(folder: folder, takesItem: takesItem, inside: inside) : nil
        }
        return topFolders(in: spaceID, pinned: pinned).compactMap { target($0) }
    }

    // MARK: Changes

    /// Delete Folder: removes a folder and keeps what it holds. Its folders take its place among its parent's folders, or at the top of its list, and its tabs go first among the tabs there.
    mutating func deleteFolder(_ id: UUID) {
        guard let deleted = folder(id) else { return }
        let lifted = subfolders(of: id).map { folder in
            var folder = folder
            folder.parentID = deleted.parentID
            return folder
        }
        let liftedIDs = Set(lifted.map(\.id))
        let remaining = folders.flatMap { folder in
            folder.id == id ? lifted : liftedIDs.contains(folder.id) ? [] : [folder]
        }
        self = FolderTree(folders: remaining, tabs: Self.placingFirst(tabs(inFolder: id), in: deleted.parentID, among: tabs))
    }

    /// Move to Folder for a folder: moves it, with everything it holds, last among `parentID`'s folders, when `canMoveFolder` allows it.
    mutating func moveFolder(_ id: UUID, into parentID: UUID) {
        guard canMoveFolder(id, into: parentID) else { return }
        reparent(id, to: parentID, after: nil)
    }

    /// Move Out of Folder for a folder: moves it, with everything it holds, into its parent's parent, or to the top of its list, right after the folder it leaves.
    mutating func moveFolderOut(_ id: UUID) {
        guard let parent = folder(folder(id)?.parentID) else { return }
        reparent(id, to: parent.parentID, after: parent.id)
    }

    /// Move Out of Folder for a tab: moves it into its folder's parent, or out of folders, first among the tabs there.
    mutating func moveTabOut(_ tab: Tab) {
        guard let folder = folder(tab.folderID) else { return }
        self = FolderTree(folders: folders, tabs: Self.placingFirst([tab], in: folder.parentID, among: tabs))
    }

    /// Gives a folder its new parent and places it after `siblingID`, or last for nil. The folders inside it keep their places, since they follow it by `parentID`.
    private mutating func reparent(_ id: UUID, to parentID: UUID?, after siblingID: UUID?) {
        guard var moved = folder(id) else { return }
        moved.parentID = parentID
        var reordered = folders.filter { $0.id != id }
        let index = siblingID.flatMap { sibling in reordered.firstIndex { $0.id == sibling }.map { $0 + 1 } } ?? reordered.endIndex
        reordered.insert(moved, at: index)
        self = FolderTree(folders: reordered, tabs: tabs)
    }

    /// `tabs` with `moved`, tabs of one list of one space, put in `folderID`, or out of folders for nil, first among the tabs there.
    private static func placingFirst(_ moved: [Tab], in folderID: UUID?, among tabs: [Tab]) -> [Tab] {
        guard let first = moved.first else { return tabs }
        let movedIDs = Set(moved.map(\.id))
        var reordered = tabs.filter { !movedIDs.contains($0.id) }
        moved.forEach { $0.folderID = folderID }
        let index = reordered.firstIndex { $0.spaceID == first.spaceID && $0.isPinned == first.isPinned && $0.folderID == folderID } ?? reordered.endIndex
        reordered.insert(contentsOf: moved, at: index)
        return reordered
    }

    // MARK: Repairs

    /// `folders` with each parent that `session.json` cannot keep cleared, which puts the folder at the top of its list (`SessionSnapshot.normalized()`): a parent that is missing, in another space or list, or the folder itself; in each cycle, the parent of the cycle's first folder in the file; and the parent of a folder at the fifth level, which rises to the top of its list with everything it holds, until every folder is within the fourth level. Every other folder keeps its parent and its place.
    static func repairingParents(of folders: [TabFolder]) -> [TabFolder] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [UUID: UUID] = [:]
        for folder in folders {
            guard let parentID = folder.parentID, parentID != folder.id, let parent = byID[parentID],
                  parent.spaceID == folder.spaceID, parent.isPinned == folder.isPinned else { continue }
            parents[folder.id] = parentID
        }
        // A walk up from a folder that comes back to it breaks the cycle there. One that meets another folder twice leads into a cycle that the cycle's own first folder breaks.
        for folder in folders {
            var seen: Set<UUID> = [folder.id]
            var current = parents[folder.id]
            while let id = current {
                if id == folder.id {
                    parents[folder.id] = nil
                    break
                }
                guard seen.insert(id).inserted else { break }
                current = parents[id]
            }
        }
        func level(of id: UUID) -> Int {
            var level = 1
            var current = parents[id]
            while let parent = current {
                level += 1
                current = parents[parent]
            }
            return level
        }
        for folder in folders {
            while level(of: folder.id) > maximumLevel {
                var ancestor = folder.id
                for _ in 0..<(level(of: folder.id) - maximumLevel - 1) { ancestor = parents[ancestor]! }
                parents[ancestor] = nil
            }
        }
        return folders.map { folder in
            var folder = folder
            folder.parentID = parents[folder.id]
            return folder
        }
    }
}
