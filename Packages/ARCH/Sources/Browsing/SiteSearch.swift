// Site search: keyword shortcuts, such as `yt` for a video site's search, kept in `site-search.json` in the app's Application Support folder. Text in the command palette that starts with a keyword and a space searches that site for the rest of the text.
import Foundation

/// One keyword shortcut. The template is a web address with `%s` where the search text goes.
public struct SiteSearchShortcut: Codable, Hashable, Identifiable {
    /// Identifies the shortcut while the app runs; the file does not store it.
    public var id = UUID()
    public var keyword: String
    public var name: String
    public var template: String

    public static let placeholder = "%s"

    private enum CodingKeys: String, CodingKey {
        case keyword, name, template = "url"
    }

    public init(keyword: String, name: String, template: String) {
        self.keyword = keyword
        self.name = name
        self.template = template
    }

    /// The results page for `query`, or `nil` when the template does not make an http or https address. An empty query gives the site's search page without a query.
    public func resultsURL(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
        guard let url = URL(string: template.replacingOccurrences(of: Self.placeholder, with: encoded)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Characters a query keeps unencoded, so it fits a query item or a path segment alike.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// Loads the shortcuts once and saves the file after each change. Until a file exists, the store writes a few defaults to it.
public final class SiteSearchStore: ObservableObject {
    @Published public private(set) var shortcuts: [SiteSearchShortcut]
    private let fileURL: URL
    /// Set while the store keeps its defaults in place of a file that did not decode. The first write moves that file aside.
    private var hasUnreadableFile = false

    private struct File: Codable {
        var shortcuts: [SiteSearchShortcut]
    }

    static let defaultShortcuts = [
        SiteSearchShortcut(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
        SiteSearchShortcut(keyword: "w", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search=%s"),
        SiteSearchShortcut(keyword: "gh", name: "GitHub", template: "https://github.com/search?q=%s"),
        SiteSearchShortcut(keyword: "m", name: "Google Maps", template: "https://www.google.com/maps/search/?api=1&query=%s"),
    ]

    /// A file that does not decode leaves the defaults in memory. It stays as it is until the first write moves it to `site-search.unreadable.json`, as an unreadable `session.json` is moved, so that neither Settings nor an import overwrites it.
    init(directory: URL) {
        fileURL = directory.appendingPathComponent("site-search.json")
        if let data = try? Data(contentsOf: fileURL) {
            let file = try? JSONDecoder().decode(File.self, from: data)
            shortcuts = file?.shortcuts ?? Self.defaultShortcuts
            hasUnreadableFile = file == nil
        } else {
            shortcuts = Self.defaultShortcuts
            write()
        }
    }

    /// The shortcut whose keyword, ignoring case, starts `input` and is followed by a space, with the rest of the text as the query. The query may be empty.
    public func match(_ input: String) -> (shortcut: SiteSearchShortcut, query: String)? {
        let text = input.drop(while: \.isWhitespace)
        guard let space = text.firstIndex(where: \.isWhitespace) else { return nil }
        let keyword = String(text[..<space])
        guard let shortcut = shortcuts.first(where: { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }) else { return nil }
        return (shortcut, text[space...].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a shortcut other than the one with `id` has `keyword`, ignoring case and surrounding spaces.
    public func isKeywordInUse(_ keyword: String, except id: UUID) -> Bool {
        let keyword = keyword.trimmingCharacters(in: .whitespaces)
        return shortcuts.contains { $0.id != id && $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }
    }

    /// Whether `shortcut` has a name, a one-word keyword that no other shortcut uses, and a template with `%s` that makes a web address.
    public func canSave(_ shortcut: SiteSearchShortcut) -> Bool {
        let shortcut = Self.trimmed(shortcut)
        return !shortcut.name.isEmpty && !shortcut.keyword.isEmpty && !shortcut.keyword.contains(where: \.isWhitespace)
            && !isKeywordInUse(shortcut.keyword, except: shortcut.id)
            && shortcut.template.contains(SiteSearchShortcut.placeholder) && shortcut.resultsURL(for: "query") != nil
    }

    /// Replaces the shortcut with the same identifier, or adds `shortcut` at the end.
    public func save(_ shortcut: SiteSearchShortcut) {
        let shortcut = Self.trimmed(shortcut)
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[index] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        write()
    }

    /// Appends, in order, the shortcuts that `canSave` accepts, writes the file once, and returns how many it added. A keyword that an earlier shortcut uses, among them one added just before, is skipped, so the first one wins. Import uses it for the shortcuts of other browsers.
    @discardableResult
    public func add(_ candidates: [SiteSearchShortcut]) -> Int {
        var count = 0
        for candidate in candidates where canSave(candidate) {
            shortcuts.append(Self.trimmed(candidate))
            count += 1
        }
        if count > 0 { write() }
        return count
    }

    public func remove(_ shortcut: SiteSearchShortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        write()
    }

    private static func trimmed(_ shortcut: SiteSearchShortcut) -> SiteSearchShortcut {
        var shortcut = shortcut
        shortcut.keyword = shortcut.keyword.trimmingCharacters(in: .whitespaces)
        shortcut.name = shortcut.name.trimmingCharacters(in: .whitespaces)
        shortcut.template = shortcut.template.trimmingCharacters(in: .whitespaces)
        return shortcut
    }

    /// Writes readable JSON, so the file can also be edited by hand while the app is not running.
    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(File(shortcuts: shortcuts)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if hasUnreadableFile {
            _ = try? FileManager.default.replaceItemAt(fileURL.deletingLastPathComponent().appendingPathComponent("site-search.unreadable.json"), withItemAt: fileURL)
            hasUnreadableFile = false
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
