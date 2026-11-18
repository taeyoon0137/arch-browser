// How folders nest in a space's pinned and open lists (bookmark rule 6, `docs/bookmarks.md`, Nested folders): which folder holds which, the sidebar's rows with their depths, the moves that Move to Folder, Move Out of Folder, and a folder row's drag make, Delete Folder, and the repairs that `session.json` gets. The session and the views ask a `FolderTree` instead of walking `TabFolder.parentID`.
import Foundation

/// The session's folders and tabs as the sidebar nests them. A folder sits at the top of its space's pinned or open list or in another folder of that list, at most `maximumLevel` levels deep, and lists its folders before its tabs, as each list does. It is built from the session's lists for each use; its mutating methods change its copies of the lists and the moved tabs' folders, and the session takes the lists back.
@MainActor struct FolderTree {
    /// The deepest level a folder can sit at; a folder at the top of its list is at level 1. Four levels at 12 points each leave the 240-point sidebar room for names.
    nonisolated static let maximumLevel = 4

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

    /// Whether `id` names a live folder, which holds only its items' tabs, in its source's order (live folder rule 4): nothing else enters it, and nothing inside it moves.
    func isLive(_ id: UUID?) -> Bool {
        folder(id)?.live != nil
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

    /// A space's pinned or open list as the sidebar shows it: each folder's row followed by the rows of its folders and its tabs, then the tabs outside folders. A collapsed folder hides everything inside it but the tabs that `shows` picks, such as the selected tab, which show one level in from the folder. The folder `hiddenID`, a dragged folder, shows its row alone.
    func rows(in spaceID: UUID, pinned: Bool, hidingContentsOf hiddenID: UUID? = nil, showingInCollapsedFolders shows: (Tab) -> Bool = { _ in false }) -> [Row] {
        var rows: [Row] = []
        func add(_ folder: TabFolder, depth: Int) {
            rows.append(.folder(folder, depth: depth))
            if folder.id == hiddenID { return }
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

    /// Whether a new folder can go inside `id`, as New Folder Inside and Add to New Folder put it: in an ordinary folder below the fourth level, or at the top of a list for nil. Live folders and agent folders hold no folders (bookmark rule 6).
    func canAddFolder(inside id: UUID?) -> Bool {
        guard let id else { return true }
        guard let parent = folder(id) else { return false }
        return !parent.isAgentFolder && parent.live == nil && level(of: id) < Self.maximumLevel
    }

    /// Whether Move to Folder can move a folder into `parentID`: another ordinary folder of its space and list that is not its parent, itself, or a folder inside it, where the folder and the folders it holds stay within the fourth level. An agent folder always stays at the top of its open list.
    func canMoveFolder(_ id: UUID, into parentID: UUID) -> Bool {
        guard let moved = folder(id), moved.parentID != parentID else { return false }
        return canHold(id, in: parentID)
    }

    /// Whether a folder can sit in `parentID`, or at the top of its list for nil: in an ordinary folder of its space and list that is not the folder itself or a folder inside it, where the folder and the folders it holds stay within the fourth level. Move to Folder and a folder's drag both ask it.
    private func canHold(_ id: UUID, in parentID: UUID?) -> Bool {
        guard let moved = folder(id), !moved.isAgentFolder else { return false }
        guard let parentID else { return true }
        guard let parent = folder(parentID), !parent.isAgentFolder, parent.live == nil, parentID != id, parent.spaceID == moved.spaceID, parent.isPinned == moved.isPinned,
              !ancestors(of: parentID).contains(where: { $0.id == id }) else { return false }
        return level(of: parentID) + height(of: id) <= Self.maximumLevel
    }

    /// Whether Move to Folder or a drop on a folder's row can move a tab into a folder: an ordinary folder of the tab's space, in either list, other than its own. The tab takes the folder's list. Only the source of a live folder or the owner of an agent folder adds tabs to it.
    func canMoveTab(_ tab: Tab, into folderID: UUID) -> Bool {
        guard let target = folder(folderID), !target.isAgentFolder, target.live == nil else { return false }
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

    // MARK: Dragging

    /// Where a dragged folder's pointer is among the rows of a space's list, which `SpaceTabsView` finds from the rows' frames.
    enum DropPosition: Equatable {
        /// The upper part of a folder's row.
        case aboveFolder(UUID)
        /// The rest of a folder's row.
        case onFolder(UUID)
        /// A tab's row.
        case onTab(UUID)
        /// The row that ends a space's pinned or open list: the divider or the new tab row.
        case listEnd(spaceID: UUID, pinned: Bool)
    }

    /// Where a dragged folder goes.
    enum DropTarget: Equatable {
        /// Last among a folder's folders. The folder's row lights up, and the dragged folder goes there on release.
        case into(UUID)
        /// Among the folders of `parentID`, or at the top of the dragged folder's list for nil: right before `beforeID`, or last for nil. The rows make room for the dragged folder there while it is dragged.
        case between(parentID: UUID?, beforeID: UUID?)
    }

    /// Where a folder dragged to `position` goes, or nil where the drop is refused or would leave the folder where it is, so that nothing moves and its row returns to its slot on release. Above a folder's row, it goes before that folder, at that folder's level; on a folder's row, into that folder; on a tab's row, last among the folders of the tab's folder, or at the top of the list for a tab outside folders, since a folder lists its folders before its tabs; on the row that ends its list, last at the top of the list. A folder stays in its space's list (another space takes it through its symbol, which the session decides), never goes into itself or a folder inside it, never takes the folders it holds past the fourth level, never goes into a live folder, and never goes where a collapsed folder would hide its row. An agent folder takes no drops and stays in its own space.
    func dropTarget(for id: UUID, at position: DropPosition) -> DropTarget? {
        guard let moved = folder(id) else { return nil }
        let target: DropTarget
        switch position {
        case .aboveFolder(let nextID):
            guard let next = folder(nextID) else { return nil }
            target = .between(parentID: next.parentID, beforeID: nextID)
        case .onFolder(let parentID):
            target = .into(parentID)
        case .onTab(let tabID):
            guard let tab = tabs.first(where: { $0.id == tabID }), tab.spaceID == moved.spaceID, tab.isPinned == moved.isPinned else { return nil }
            target = .between(parentID: tab.folderID, beforeID: nil)
        case .listEnd(let spaceID, let pinned):
            guard spaceID == moved.spaceID, pinned == moved.isPinned else { return nil }
            target = .between(parentID: nil, beforeID: nil)
        }
        return canMoveFolder(id, to: target) ? target : nil
    }

    /// Whether a dragged folder can go to `target` and would change its place there. Into a folder includes its own parent while another folder follows it there, which puts it last.
    func canMoveFolder(_ id: UUID, to target: DropTarget) -> Bool {
        guard let moved = folder(id) else { return false }
        switch target {
        case .into(let parentID):
            return canHold(id, in: parentID) && !isHidden(parentID) && subfolders(of: parentID).last?.id != id
        case .between(let parentID, let beforeID):
            guard canHold(id, in: parentID), beforeID != id else { return false }
            // A place inside a collapsed folder would hide the dragged row.
            if let parentID, folder(parentID)?.isCollapsed == true || isHidden(parentID) { return false }
            let siblings = parentID.map(subfolders(of:)) ?? topFolders(in: moved.spaceID, pinned: moved.isPinned)
            if let beforeID, !siblings.contains(where: { $0.id == beforeID }) { return false }
            guard let index = siblings.firstIndex(where: { $0.id == id }) else { return true }
            let next = siblings.index(after: index) < siblings.endIndex ? siblings[siblings.index(after: index)].id : nil
            return next != beforeID
        }
    }

    /// Whether a collapsed folder holds the folder, which hides its row.
    private func isHidden(_ id: UUID) -> Bool {
        ancestors(of: id).contains(where: \.isCollapsed)
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

    /// A folder's drag: moves it, with everything it holds, to `target` when `canMoveFolder(_:to:)` allows it.
    mutating func moveFolder(_ id: UUID, to target: DropTarget) {
        guard canMoveFolder(id, to: target) else { return }
        switch target {
        case .into(let parentID): reparent(id, to: parentID)
        case .between(let parentID, let beforeID): reparent(id, to: parentID, before: beforeID)
        }
    }

    /// A folder dropped on another space's symbol: moves it, with the folders and tabs inside it, last among the folders at the top of that space's list of its kind, so its tabs keep their pinned state. The folders inside it keep their parents, and everything moved goes after the space's own folders and tabs. The session checks that the space belongs to the folder's Persona.
    mutating func moveFolder(_ id: UUID, toSpace spaceID: UUID) {
        guard let moved = folder(id), !moved.isAgentFolder, moved.spaceID != spaceID else { return }
        let carriedIDs = Set([id] + descendants(of: id).map(\.id))
        let carriedTabIDs = Set(tabs(inside: id).map(\.id))
        let carried = folders.filter { carriedIDs.contains($0.id) }.map { folder in
            var folder = folder
            folder.spaceID = spaceID
            if folder.id == id { folder.parentID = nil }
            return folder
        }
        let carriedTabs = tabs.filter { carriedTabIDs.contains($0.id) }
        carriedTabs.forEach { $0.spaceID = spaceID }
        self = FolderTree(folders: folders.filter { !carriedIDs.contains($0.id) } + carried, tabs: tabs.filter { !carriedTabIDs.contains($0.id) } + carriedTabs)
    }

    /// Gives a folder its new parent and places it right after `afterID` or right before `beforeID`, or last for nil. The folders inside it keep their places, since they follow it by `parentID`.
    private mutating func reparent(_ id: UUID, to parentID: UUID?, after afterID: UUID? = nil, before beforeID: UUID? = nil) {
        guard var moved = folder(id) else { return }
        moved.parentID = parentID
        var reordered = folders.filter { $0.id != id }
        let index = afterID.flatMap { sibling in reordered.firstIndex { $0.id == sibling }.map { $0 + 1 } }
            ?? beforeID.flatMap { sibling in reordered.firstIndex { $0.id == sibling } }
            ?? reordered.endIndex
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
    nonisolated static func repairingParents(of folders: [TabFolder]) -> [TabFolder] {
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
                for _ in 0..<(level(of: folder.id) - maximumLevel - 1) {
                    guard let parent = parents[ancestor] else { break }
                    ancestor = parent
                }
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
