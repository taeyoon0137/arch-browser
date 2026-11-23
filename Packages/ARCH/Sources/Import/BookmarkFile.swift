// Parses bookmarks. HTML bookmark files become favorites directly. Chromium-format JSON and WebKit-format property lists become bookmark trees: the file import flattens a tree into favorites in file order, and the browser import splits it so that a bar's bookmarks become favorites and other folders become pinned folders named by their paths.
import Browsing
import Foundation

extension SidebarImport.Item {
    /// A bookmark, favorite, or pinned tab read from another browser. Only web pages come in (`ImportedFile.webURL`), so this returns nil for any other address. An empty name falls back to the host, and an empty name the user gave a tab to none.
    init?(sourceID: String? = nil, address: String, title: String?, customTitle: String? = nil) {
        guard let url = ImportedFile.webURL(address) else { return nil }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customName = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(sourceID: sourceID, url: url, title: name.isEmpty ? url.host ?? url.absoluteString : name, customTitle: customName.isEmpty ? nil : customName)
    }

    /// The item as the file import adds it to the favorites.
    var favorite: Favorite {
        Favorite(url: url, title: title)
    }
}

/// Bookmarks or a sidebar's pinned items as the source nests them.
struct BookmarkTree: Equatable {
    /// A bookmark or a folder in the tree.
    enum Node: Equatable {
        case item(SidebarImport.Item)
        case folder(Folder)
    }

    /// A folder of the tree, with its name, kind, and children.
    struct Folder: Equatable {
        /// Where the paths of the folders below a folder start.
        enum Kind {
            /// A bookmarks bar, or a container read like one: `split()` returns its own items as `barItems`, outside any folder, and the paths of its folders start below it.
            case bar
            /// Any other top-level folder: its own items go into a folder named after it, and the paths of its folders start with its name.
            case root
            case folder
        }

        var sourceID: String?
        var name: String
        var kind: Kind = .folder
        var children: [Node] = []

        /// Every item in the folder and the folders below it, in order.
        var allItems: [SidebarImport.Item] {
            children.flatMap { node -> [SidebarImport.Item] in
                switch node {
                case .item(let item): return [item]
                case .folder(let folder): return folder.allItems
                }
            }
        }

        /// The folder without the items `isExcluded` matches, here or in the folders below it.
        func removingItems(where isExcluded: (SidebarImport.Item) -> Bool) -> Folder {
            var folder = self
            folder.children = children.compactMap { node in
                switch node {
                case .item(let item): return isExcluded(item) ? nil : node
                case .folder(let child): return .folder(child.removingItems(where: isExcluded))
                }
            }
            return folder
        }
    }

    var roots: [Folder]

    /// Every item in file order, as the file import makes favorites of them.
    var allItems: [SidebarImport.Item] {
        roots.flatMap(\.allItems)
    }

    /// The bars' own items in bar order, and every other folder that directly holds items, in tree order with each folder before the ones below it. A folder's name is its path joined with " \u{25B8} ", as Arch writes a path, such as "Work \u{25B8} Docs" below a bar and "Other Bookmarks \u{25B8} Recipes" below another root, so that folders of different roots stay apart; " / " would read as a Persona and a space. Empty folders are left out.
    func split() -> (barItems: [SidebarImport.Item], folders: [SidebarImport.Folder]) {
        var barItems: [SidebarImport.Item] = []
        var folders: [SidebarImport.Folder] = []
        func visit(_ folder: Folder, below parentPath: [String]) {
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let path: [String]
            switch folder.kind {
            case .bar: path = []
            case .root: path = [name]
            case .folder: path = parentPath + [name.isEmpty ? localized("Untitled Folder") : name]
            }
            let items = folder.children.compactMap { node -> SidebarImport.Item? in
                if case .item(let item) = node { return item }
                return nil
            }
            if folder.kind == .bar {
                barItems += items
            } else if !items.isEmpty {
                folders.append(SidebarImport.Folder(sourceID: folder.sourceID, name: path.joined(separator: " \u{25B8} "), items: items))
            }
            for case .folder(let child) in folder.children {
                visit(child, below: path)
            }
        }
        roots.forEach { visit($0, below: []) }
        return (barItems, folders)
    }

    /// Combines the trees of one profile's bookmark files in order. Each root follows the earlier trees' root of the same name, and an item whose address an earlier tree has is left out, so it comes once.
    static func merging(_ trees: [BookmarkTree]) -> BookmarkTree {
        var roots: [Folder] = []
        var earlierAddresses: Set<URL> = []
        for tree in trees {
            for root in tree.roots {
                let kept = root.removingItems { earlierAddresses.contains($0.url) }
                if let index = roots.lastIndex(where: { $0.name == kept.name }) {
                    roots.insert(kept, at: index + 1)
                } else {
                    roots.append(kept)
                }
            }
            earlierAddresses.formUnion(tree.allItems.map(\.url))
        }
        return BookmarkTree(roots: roots)
    }
}

/// Parses bookmark files into favorites or bookmark trees.
enum BookmarkFile {
    /// HTML bookmark files, the common export format: each bookmark is an `A` element whose `HREF` holds the address and whose text is the name. Favorites have no folders, so the file's folders are flattened.
    static func netscapeFavorites(from data: Data) -> [Favorite] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        return anchorPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let attributesRange = Range(match.range(at: 1), in: text), let nameRange = Range(match.range(at: 2), in: text) else { return nil }
            let attributes = String(text[attributesRange])
            guard let reference = hrefPattern.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                  let valueRange = (1...3).lazy.compactMap({ Range(reference.range(at: $0), in: attributes) }).first else { return nil }
            let name = String(text[nameRange])
            let plainName = tagPattern.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
            return SidebarImport.Item(address: decodingEntities(String(attributes[valueRange])), title: decodingEntities(plainName))?.favorite
        }
    }

    /// Chromium-format Bookmarks JSON: a `roots` object whose folders hold `url` and `folder` nodes, each with its `guid`. The bookmarks bar comes first, then the other and mobile bookmarks, then any other root by key. Returns nil for JSON without `roots`.
    static func chromiumTree(from data: Data) -> BookmarkTree? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let roots = object["roots"] as? [String: Any] else { return nil }
        let knownRoots: [(key: String, name: String, kind: BookmarkTree.Folder.Kind)] = [
            ("bookmark_bar", localized("Bookmarks Bar"), .bar), ("other", localized("Other Bookmarks"), .root), ("synced", localized("Mobile Bookmarks"), .root),
        ]
        let otherKeys = roots.keys.filter { key in !knownRoots.contains { $0.key == key } }.sorted()
        func folder(_ node: [String: Any], name: String, kind: BookmarkTree.Folder.Kind) -> BookmarkTree.Folder {
            let children = (node["children"] as? [Any] ?? []).compactMap { child -> BookmarkTree.Node? in
                guard let child = child as? [String: Any] else { return nil }
                switch child["type"] as? String {
                case "url":
                    return (child["url"] as? String).flatMap { SidebarImport.Item(sourceID: child["guid"] as? String, address: $0, title: child["name"] as? String) }.map(BookmarkTree.Node.item)
                case "folder":
                    return .folder(folder(child, name: child["name"] as? String ?? "", kind: .folder))
                default:
                    return nil
                }
            }
            return BookmarkTree.Folder(sourceID: node["guid"] as? String, name: name, kind: kind, children: children)
        }
        let rootFolders = knownRoots.compactMap { root in
            (roots[root.key] as? [String: Any]).map { folder($0, name: root.name, kind: root.kind) }
        } + otherKeys.compactMap { key in
            (roots[key] as? [String: Any]).map { folder($0, name: $0["name"] as? String ?? key, kind: .root) }
        }
        return BookmarkTree(roots: rootFolders)
    }

    /// WebKit-format Bookmarks.plist: `WebBookmarkTypeList` dictionaries whose `Children` hold more lists and `WebBookmarkTypeLeaf` entries, each with `URLString`, its name under `URIDictionary`, and its `WebBookmarkUUID`. The file's top level is a root named Bookmarks; the Favorites bar (`BookmarksBar`) is the bar, and the bookmarks menu (`BookmarksMenu`) another root. The reading list holds pages saved to read once, not bookmarks, so it stays out. Returns nil for a property list without `Children`.
    static func webKitTree(from data: Data) -> BookmarkTree? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let children = root["Children"] as? [[String: Any]] else { return nil }
        func node(_ entry: [String: Any]) -> BookmarkTree.Node? {
            let sourceID = entry["WebBookmarkUUID"] as? String
            switch entry["WebBookmarkType"] as? String ?? "" {
            case "WebBookmarkTypeLeaf":
                let title = (entry["URIDictionary"] as? [String: Any])?["title"] as? String
                return (entry["URLString"] as? String).flatMap { SidebarImport.Item(sourceID: sourceID, address: $0, title: title) }.map(BookmarkTree.Node.item)
            case "WebBookmarkTypeList":
                let title = entry["Title"] as? String ?? ""
                let list: (name: String, kind: BookmarkTree.Folder.Kind)
                switch title {
                case "com.apple.ReadingList": return nil
                case "BookmarksBar": list = (localized("Favorites"), .bar)
                case "BookmarksMenu": list = (localized("Bookmarks Menu"), .root)
                default: list = (title, .folder)
                }
                let children = (entry["Children"] as? [[String: Any]] ?? []).compactMap(node)
                return .folder(BookmarkTree.Folder(sourceID: sourceID, name: list.name, kind: list.kind, children: children))
            default:
                return nil
            }
        }
        return BookmarkTree(roots: [BookmarkTree.Folder(sourceID: root["WebBookmarkUUID"] as? String, name: localized("Bookmarks"), kind: .root, children: children.compactMap(node))])
    }

    // MARK: HTML

    private static let anchorPattern = try! NSRegularExpression(pattern: "<a\\s([^>]*)>(.*?)</a>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    /// The attribute's value in double quotes, single quotes, or none.
    private static let hrefPattern = try! NSRegularExpression(pattern: "\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))", options: .caseInsensitive)
    private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let entityPattern = try! NSRegularExpression(pattern: "&(#[0-9]+|#x[0-9a-f]+|[a-z]+);", options: .caseInsensitive)

    /// Decodes the character references exporters write: the XML entities, `&nbsp;`, and numeric references. Other references stay as they are.
    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = text.startIndex
        for match in entityPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
            result += text[rest..<whole.lowerBound]
            result += character(forEntity: text[name].lowercased()) ?? String(text[whole])
            rest = whole.upperBound
        }
        return result + text[rest...]
    }

    private static func character(forEntity name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}
