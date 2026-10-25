// Reads `StorableSidebar.json`, the sidebar file of a Chromium-format browser with spaces: each space with its pinned tabs and folders, and each profile's favorites, grouped by the profile folder they belong to. Only the file's `sidebar` key matches the sidebar the browser shows; the sync copies beside it list other spaces and items.
import Foundation

/// A space read from the sidebar file.
struct ImportedSpace: Equatable {
    var sourceID: String
    /// `nil` for a space the user did not name.
    var name: String?
    /// The middle tone of the space's theme, or `nil` for a space without one.
    var color: Color?
    /// The pinned tabs outside folders, in sidebar order.
    var pinnedItems: [ImportedItem]
    /// The pinned folders, named by their paths as `BookmarkTree.split()` names them.
    var folders: [ImportedFolder]

    /// A color's components in the color space the file names. They stay as they are, since only the hue picks a tint.
    struct Color: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }
}

/// The sidebar file's spaces and favorites, by profile folder.
struct SidebarFile: Equatable {
    struct Profile: Equatable {
        /// The profile's folder in the user data folder. A space synced from another Mac may name a folder that this Mac lacks.
        var folderName: String
        var spaces: [ImportedSpace] = []
        var favorites: [ImportedItem] = []
    }

    /// In the order the file first names each folder, spaces before favorites.
    var profiles: [Profile]

    /// Returns nil for data that is not JSON or has no container with `items` and `spaces`. Files of other versions are read alike.
    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (object["sidebar"] as? [String: Any])?["containers"] as? [[String: Any]],
              let container = containers.first(where: { $0["items"] is [Any] && $0["spaces"] is [Any] }) else { return nil }
        // `items` and `spaces` alternate IDs with objects, and each object holds its own ID as well.
        func objects(_ key: String) -> [[String: Any]] {
            (container[key] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        }
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
        for space in objects("spaces") {
            guard let id = space["id"] as? String, let folderName = Self.profileFolder(space["profile"]) else { continue }
            // `containerIDs` pairs a label, `pinned` or `unpinned`, with that container's ID, in no fixed order. The unpinned container holds the day's tabs, which the browser archives on its own, so only the pinned one comes in.
            let pinnedID = Self.pairs(space["containerIDs"] as? [Any] ?? []).first { $0.key as? String == "pinned" }?.value as? String
            let pinned = BookmarkTree(roots: [BookmarkTree.Folder(name: "", kind: .bar, children: pinnedID.map { items.nodes(in: $0) } ?? [])]).split()
            let title = (space["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let imported = ImportedSpace(sourceID: id, name: title.isEmpty ? nil : title, color: Self.color(of: space), pinnedItems: pinned.barItems, folders: pinned.folders)
            add(to: folderName) { $0.spaces.append(imported) }
        }
        // `topAppsContainerIDs` pairs each profile reference with the ID of that profile's favorites container.
        for pair in Self.pairs(container["topAppsContainerIDs"] as? [Any] ?? []) {
            guard let folderName = Self.profileFolder(pair.key), let containerID = pair.value as? String else { continue }
            // A favorite takes the name the user gave its tab, or else the page's title.
            let favorites = items.nodes(in: containerID).compactMap { node -> ImportedItem? in
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
                    let item = ImportedItem(sourceID: childID, address: tab["savedURL"] as? String ?? "", title: tab["savedTitle"] as? String, customTitle: child["title"] as? String)
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

    /// The middle tone of the space's theme, `customInfo.windowTheme.primaryColorPalette.midTone`.
    private static func color(of space: [String: Any]) -> ImportedSpace.Color? {
        let theme = (space["customInfo"] as? [String: Any])?["windowTheme"] as? [String: Any]
        guard let tone = (theme?["primaryColorPalette"] as? [String: Any])?["midTone"] as? [String: Any],
              let red = tone["red"] as? Double, let green = tone["green"] as? Double, let blue = tone["blue"] as? Double else { return nil }
        return ImportedSpace.Color(red: red, green: green, blue: blue)
    }

    /// The pairs of an array that alternates keys and values.
    private static func pairs(_ array: [Any]) -> [(key: Any, value: Any)] {
        stride(from: 0, to: array.count - 1, by: 2).map { (array[$0], array[$0 + 1]) }
    }
}
