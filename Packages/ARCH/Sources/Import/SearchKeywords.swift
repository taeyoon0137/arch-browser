// Reads the search engines of a Chromium-format profile: the `keywords` table in its `Web Data` database, and the default engine that its `Preferences` names. Shortcuts the user created become site search shortcuts; the default engine counts only when it is one Arch offers.
import Browsing
import Foundation
import SQLite3

struct SearchKeywords {
    var shortcuts: [SiteSearchShortcut]
    /// Shortcuts the user created that Arch cannot use: a keyword with a space, a placeholder other than the search terms and input encoding, or a template that is not a web address.
    var skippedCount: Int
    var defaultEngine: SearchEngine?

    /// One row of `keywords`.
    private struct Row {
        var name: String
        var keyword: String
        /// The search address, with `{searchTerms}` where the query goes and other placeholders in braces.
        var template: String
        var guid: String
        /// The built-in engine's ID in Chromium's `prepopulated_engines.json`, or 0.
        var prepopulateID: Int
        var isUserShortcut: Bool
    }

    /// Reads the `Web Data` database at `url` from a copy. `preferences` is the profile's `Preferences` JSON. Throws `ImportError.unreadableFile` when the database lacks the `keywords` table or its columns, or cannot be read to its last row.
    static func read(at url: URL, preferences: [String: Any]?) throws -> SearchKeywords {
        // A user's shortcut is not built in (`prepopulate_id`, `starter_pack_id`), not offered by a site and left unused (`safe_for_autoreplace`), not set by policy, and not deactivated by the user (`is_active` 2).
        let query = """
            SELECT short_name, keyword, url, sync_guid, prepopulate_id,
                safe_for_autoreplace = 0 AND prepopulate_id = 0 AND starter_pack_id = 0 AND created_by_policy = 0 AND is_active <> 2
            FROM keywords ORDER BY id
            """
        let rows = try DatabaseCopy.read(url, unreadable: .unreadableFile(url)) { database in
            var rows: [Row] = []
            try DatabaseCopy.forEachRow(in: database, query, unreadable: .unreadableFile(url)) { row in
                let text = { DatabaseCopy.text(row, $0) ?? "" }
                rows.append(Row(name: text(0), keyword: text(1), template: text(2), guid: text(3),
                                prepopulateID: Int(sqlite3_column_int(row, 4)), isUserShortcut: sqlite3_column_int(row, 5) != 0))
            }
            return rows
        }
        return SearchKeywords(rows: rows, preferences: preferences)
    }

    private init(rows: [Row], preferences: [String: Any]?) {
        let userRows = rows.filter(\.isUserShortcut)
        shortcuts = userRows.compactMap(Self.shortcut)
        skippedCount = userRows.count - shortcuts.count
        defaultEngine = Self.defaultEngine(rows: rows, preferences: preferences)
    }

    /// Placeholders in braces, such as `{searchTerms}` or `{google:baseURL}`.
    private static let placeholderPattern = "\\{[^{}]*\\}"

    /// The site search shortcut for a user's row, with the search terms as `%s` and the input encoding as UTF-8, or nil when Arch cannot use the row.
    private static func shortcut(from row: Row) -> SiteSearchShortcut? {
        let template = row.template.replacingOccurrences(of: "{searchTerms}", with: SiteSearchShortcut.placeholder).replacingOccurrences(of: "{inputEncoding}", with: "UTF-8")
        let shortcut = SiteSearchShortcut(keyword: row.keyword, name: row.name, template: template)
        guard !row.keyword.contains(where: \.isWhitespace), template.range(of: placeholderPattern, options: .regularExpression) == nil,
              shortcut.resultsURL(for: "query") != nil else { return nil }
        return shortcut
    }

    /// The engine of the row that `default_search_provider.guid` names, or else of the copy that some browsers mirror in `default_search_provider_data.mirrored_template_url_data`. An empty guid, which leaves the browser on its built-in default, names none.
    private static func defaultEngine(rows: [Row], preferences: [String: Any]?) -> SearchEngine? {
        guard let guid = (preferences?["default_search_provider"] as? [String: Any])?["guid"] as? String, !guid.isEmpty else { return nil }
        if let row = rows.first(where: { $0.guid == guid }) {
            return engine(prepopulateID: row.prepopulateID, template: row.template)
        }
        guard let mirrored = (preferences?["default_search_provider_data"] as? [String: Any])?["mirrored_template_url_data"] as? [String: Any] else { return nil }
        return engine(prepopulateID: mirrored["prepopulate_id"] as? Int ?? 0, template: mirrored["url"] as? String ?? "")
    }

    /// Arch's engine for a built-in engine's ID in `prepopulated_engines.json`, or else for the template's host.
    private static func engine(prepopulateID: Int, template: String) -> SearchEngine? {
        switch prepopulateID {
        case 1: return .google
        case 3: return .bing
        case 92: return .duckDuckGo
        default:
            let address = template.replacingOccurrences(of: placeholderPattern, with: "", options: .regularExpression)
            guard let host = URL(string: address)?.host?.lowercased() else { return nil }
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return ["google.com": .google, "bing.com": .bing, "duckduckgo.com": .duckDuckGo][site]
        }
    }
}
