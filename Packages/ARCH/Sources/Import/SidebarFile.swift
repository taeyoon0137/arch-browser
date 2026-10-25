// Reads `StorableSidebar.json`, the sidebar file of a Chromium-format browser with spaces: each space with its pinned tabs and folders, and each profile's favorites, grouped by the profile folder they belong to. Only the file's `sidebar` key matches the sidebar the browser shows; the sync copies beside it list other spaces and items.
import Browsing
import Foundation

/// The sidebar file's spaces and favorites, by profile folder.
struct SidebarFile: Equatable {
    struct Profile: Equatable {
        /// The profile's folder in the user data folder. A space synced from another Mac may name a folder that this Mac lacks.
        var folderName: String
        /// The spaces with their pinned tabs outside folders, and their pinned folders named by their paths as `BookmarkTree.split()` names them, in sidebar order.
        var spaces: [SidebarImport.SourceSpace] = []
        var favorites: [SidebarImport.Item] = []
    }

    /// In the order the file first names each folder, spaces before favorites.
    var profiles: [Profile]

    /// Returns nil for data that is not JSON, has no container with `items` and `spaces`, or has spaces of which none names a pinned container, so that a file whose spaces this reader cannot follow counts as unreadable rather than as spaces without pinned tabs. Files of other versions are read alike.
    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (object["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]],
              let container = containers.first(where: { $0["items"] is [Any] && $0["spaces"] is [Any] }) else { return nil }
        // `items` and `spaces` alternate IDs with objects, and each object holds its own ID as well.
        func objects(_ key: String) -> [[String: Any]] {
            (container[key] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        }
        let spaces = objects("spaces")
        // The unpinned container holds the day's tabs, which the browser archives on its own, so only the pinned one comes in.
        let pinnedIDs = spaces.map(Self.pinnedContainerID)
        guard spaces.isEmpty || pinnedIDs.contains(where: { $0 != nil }) else { return nil }
        var itemsByID: [String: [String: Any]] = [:]
        for item in objects("items") {
            if let id = item["id"] as? String { itemsByID[id] = item }
        }
        let items = Items(byID: itemsByID)

        var profiles: [Profile] = []
        func add(to folderName: String, _ change: (inout Profile) -> Void) {
            if let index = profiles.firstIndex(where: { $0.folderName == folderName }) {
                change(&profiles[index])
            } else {
                var profile = Profile(folderName: folderName)
                change(&profile)
                profiles.append(profile)
            }
        }
        for (space, pinnedID) in zip(spaces, pinnedIDs) {
            guard let id = space["id"] as? String, let folderName = Self.profileFolder(space["profile"]) else { continue }
            // As a bar, the pinned container gives its own tabs back outside any folder, as the space's pinned tabs, and its folders' paths start below it.
            let pinned = BookmarkTree(roots: [BookmarkTree.Folder(name: "", kind: .bar, children: pinnedID.map { items.nodes(in: $0) } ?? [])]).split()
            let title = (space["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let imported = SidebarImport.SourceSpace(origin: .space(id), name: title.isEmpty ? nil : title, tint: Self.tint(of: space), pinnedItems: pinned.barItems, folders: pinned.folders)
            add(to: folderName) { $0.spaces.append(imported) }
        }
        // `topAppsContainerIDs` pairs each profile reference with the ID of that profile's favorites container.
        for pair in Self.pairs(container["topAppsContainerIDs"] as? [Any] ?? []) {
            guard let folderName = Self.profileFolder(pair.key), let containerID = pair.value as? String else { continue }
            // A favorite takes the name the user gave its tab, or else the page's title.
            let favorites = items.nodes(in: containerID).compactMap { node -> SidebarImport.Item? in
                guard case .item(var item) = node else { return nil }
                item.title = item.customTitle ?? item.title
                item.customTitle = nil
                return item
            }
            add(to: folderName) { $0.favorites += favorites }
        }
        self.profiles = profiles
    }

    /// The file's items by ID.
    private struct Items {
        let byID: [String: [String: Any]]

        /// The tree of the items in the container or folder `id`, in sidebar order: tabs, which keep the name the user gave them as `customTitle`, and folders (`list`) with their own items. A split view's tabs count as separate tabs. Other kinds of items are skipped, and so is an item inside itself, so that a damaged file cannot loop.
        func nodes(in id: String, ancestors: Set<String> = []) -> [BookmarkTree.Node] {
            let ancestors = ancestors.union([id])
            let childIDs = (byID[id]?["childrenIds"] as? [String] ?? []).filter { !ancestors.contains($0) }
            return childIDs.flatMap { childID -> [BookmarkTree.Node] in
                guard let child = byID[childID], let data = child["data"] as? [String: Any] else { return [] }
                if let tab = data["tab"] as? [String: Any] {
                    let item = SidebarImport.Item(sourceID: childID, address: tab["savedURL"] as? String ?? "", title: tab["savedTitle"] as? String, customTitle: child["title"] as? String)
                    return item.map { [.item($0)] } ?? []
                }
                if data["list"] != nil {
                    return [.folder(BookmarkTree.Folder(sourceID: childID, name: child["title"] as? String ?? "", children: nodes(in: childID, ancestors: ancestors)))]
                }
                if data["splitView"] != nil {
                    return nodes(in: childID, ancestors: ancestors)
                }
                return []
            }
        }
    }

    /// The profile folder a profile reference names: `Default` for `{"default": true}`, or a custom reference's `directoryBasename`.
    private static func profileFolder(_ reference: Any?) -> String? {
        guard let reference = reference as? [String: Any] else { return nil }
        if reference["default"] as? Bool == true { return "Default" }
        return ((reference["custom"] as? [String: Any])?["_0"] as? [String: Any])?["directoryBasename"] as? String
    }

    /// The ID of the space's pinned container. `containerIDs` pairs a label, `pinned` or `unpinned`, with that container's ID, in no fixed order. `newContainerIDs` pairs the same IDs with labels as objects, such as `{"pinned": {}}`; it is read when `containerIDs` names no pinned container.
    private static func pinnedContainerID(of space: [String: Any]) -> String? {
        if let id = pairs(space["containerIDs"] as? [Any] ?? []).first(where: { $0.key as? String == "pinned" })?.value as? String { return id }
        return pairs(space["newContainerIDs"] as? [Any] ?? []).first { ($0.key as? [String: Any])?["pinned"] != nil }?.value as? String
    }

    /// The tint nearest to the middle tone of the space's theme, `customInfo.windowTheme.primaryColorPalette.midTone`, or nil for a space without one.
    private static func tint(of space: [String: Any]) -> SpaceTint? {
        let theme = (space["customInfo"] as? [String: Any])?["windowTheme"] as? [String: Any]
        guard let tone = (theme?["primaryColorPalette"] as? [String: Any])?["midTone"] as? [String: Any],
              let red = tone["red"] as? Double, let green = tone["green"] as? Double, let blue = tone["blue"] as? Double else { return nil }
        return SpaceTint.nearest(red: red, green: green, blue: blue)
    }

    /// The pairs of an array that alternates keys and values.
    private static func pairs(_ array: [Any]) -> [(key: Any, value: Any)] {
        stride(from: 0, to: array.count - 1, by: 2).map { (array[$0], array[$0 + 1]) }
    }
}
