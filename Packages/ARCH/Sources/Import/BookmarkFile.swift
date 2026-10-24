// Parses exported bookmarks into favorites. Favorites have no folders, so each format's folders are flattened in the order the file lists them.
import Browsing
import Foundation

enum BookmarkFile {
    /// HTML bookmark files, the common export format: each bookmark is an `A` element whose `HREF` holds the address and whose text is the name.
    static func netscapeFavorites(from data: Data) -> [Favorite] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        return anchorPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let attributesRange = Range(match.range(at: 1), in: text), let nameRange = Range(match.range(at: 2), in: text) else { return nil }
            let attributes = String(text[attributesRange])
            guard let reference = hrefPattern.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                  let valueRange = (1...3).lazy.compactMap({ Range(reference.range(at: $0), in: attributes) }).first else { return nil }
            let name = String(text[nameRange])
            let plainName = tagPattern.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
            return ImportedFile.favorite(address: decodingEntities(String(attributes[valueRange])), title: decodingEntities(plainName))
        }
    }

    /// Chromium-format Bookmarks JSON: a `roots` object whose folders hold `url` and `folder` nodes. The bookmarks bar comes first, then the other and mobile folders, then any other root. Returns nil for JSON without `roots`.
    static func chromiumFavorites(from data: Data) -> [Favorite]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let roots = object["roots"] as? [String: Any] else { return nil }
        let knownRoots = ["bookmark_bar", "other", "synced"]
        let rootNames = knownRoots.filter { roots[$0] != nil } + roots.keys.filter { !knownRoots.contains($0) }.sorted()
        var favorites: [Favorite] = []
        func collect(_ node: Any?) {
            guard let node = node as? [String: Any] else { return }
            if node["type"] as? String == "url", let address = node["url"] as? String,
               let favorite = ImportedFile.favorite(address: address, title: node["name"] as? String) {
                favorites.append(favorite)
            }
            (node["children"] as? [Any])?.forEach(collect)
        }
        rootNames.forEach { collect(roots[$0]) }
        return favorites
    }

    /// WebKit-format Bookmarks.plist: `WebBookmarkTypeList` dictionaries whose `Children` hold more lists and `WebBookmarkTypeLeaf` entries, each with `URLString` and its name under `URIDictionary`. The reading list holds pages saved to read once, not bookmarks, so it stays out. Returns nil for a property list without `Children`.
    static func webKitFavorites(from data: Data) -> [Favorite]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let children = root["Children"] as? [[String: Any]] else { return nil }
        var favorites: [Favorite] = []
        func collect(_ node: [String: Any]) {
            switch node["WebBookmarkType"] as? String ?? "" {
            case "WebBookmarkTypeLeaf":
                if let address = node["URLString"] as? String,
                   let favorite = ImportedFile.favorite(address: address, title: (node["URIDictionary"] as? [String: Any])?["title"] as? String) {
                    favorites.append(favorite)
                }
            case "WebBookmarkTypeList" where node["Title"] as? String != "com.apple.ReadingList":
                (node["Children"] as? [[String: Any]])?.forEach(collect)
            default:
                break
            }
        }
        children.forEach(collect)
        return favorites
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
