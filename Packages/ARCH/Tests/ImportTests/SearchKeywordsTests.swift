// Search engines from a synthetic Chromium-format `Web Data` database: which `keywords` rows become site search shortcuts, and which default engine `Preferences` names.
import Browsing
import Foundation
import Testing
@testable import Import

@Suite struct SearchKeywordsTests {
    private static let schema = """
        CREATE TABLE keywords (id INTEGER PRIMARY KEY, short_name VARCHAR NOT NULL, keyword VARCHAR NOT NULL, url VARCHAR NOT NULL,
            safe_for_autoreplace INTEGER, prepopulate_id INTEGER DEFAULT 0, created_by_policy INTEGER DEFAULT 0, sync_guid VARCHAR,
            is_active INTEGER DEFAULT 0, starter_pack_id INTEGER DEFAULT 0)
        """

    /// Inserts a row; the defaults describe an active shortcut the user created.
    private static func row(_ name: String, _ keyword: String, _ template: String, guid: String = "", safe: Int = 0, prepopulateID: Int = 0,
                            starterPackID: Int = 0, policy: Int = 0, active: Int = 1) -> String {
        "INSERT INTO keywords (short_name, keyword, url, sync_guid, safe_for_autoreplace, prepopulate_id, starter_pack_id, created_by_policy, is_active) "
            + "VALUES ('\(name)', '\(keyword)', '\(template)', '\(guid)', \(safe), \(prepopulateID), \(starterPackID), \(policy), \(active))"
    }

    @Test func onlyActiveShortcutsTheUserCreatedWithWebTemplatesComeIn() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.database("Web Data", [
            Self.schema,
            Self.row("Built In", "builtin.example", "{google:baseURL}search?q={searchTerms}", safe: 1, prepopulateID: 1),
            Self.row("Starter", "@starter", "about:starter?q={searchTerms}", starterPackID: 1),
            Self.row("Offered", "offered.example", "https://offered.example/?q={searchTerms}", safe: 1, active: 0),
            Self.row("Videos", "v", "https://videos.example/results?q={searchTerms}&ie={inputEncoding}"),
            Self.row("Localized", "loc", "https://loc.example/{language}/?q={searchTerms}"),
            Self.row("Spaced", "two words", "https://spaced.example/?q={searchTerms}"),
            Self.row("Not Web", "nw", "ftp://files.example/{searchTerms}"),
            Self.row("Deactivated", "off", "https://off.example/?q={searchTerms}", active: 2),
            Self.row("Policy", "pol", "https://policy.example/?q={searchTerms}", policy: 1),
            Self.row("Unspecified", "un", "https://unspecified.example/?s={searchTerms}", active: 0),
        ])
        let keywords = try SearchKeywords.read(at: file, preferences: nil)
        #expect(keywords.shortcuts.map(\.keyword) == ["v", "un"])
        #expect(keywords.shortcuts.map(\.name) == ["Videos", "Unspecified"])
        #expect(keywords.shortcuts.map(\.template) == ["https://videos.example/results?q=%s&ie=UTF-8", "https://unspecified.example/?s=%s"])
        #expect(keywords.skippedCount == 3)
        #expect(keywords.defaultEngine == nil)
    }

    @Test func theDefaultEngineIsRecognizedByItsBuiltInIDOrHost() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.database("Web Data", [
            Self.schema,
            Self.row("Built In", "builtin.example", "https://builtin.example/search?q={searchTerms}", guid: "built-in", safe: 1, prepopulateID: 3),
            Self.row("Own", "own", "https://www.duckduckgo.com/?q={searchTerms}", guid: "own"),
            Self.row("Elsewhere", "else", "https://elsewhere.example/?q={searchTerms}", guid: "elsewhere"),
        ])
        func engine(guid: String, mirrored: [String: Any]? = nil) throws -> SearchEngine? {
            var preferences: [String: Any] = ["default_search_provider": ["guid": guid]]
            preferences["default_search_provider_data"] = mirrored.map { ["mirrored_template_url_data": $0] }
            return try SearchKeywords.read(at: file, preferences: preferences).defaultEngine
        }
        #expect(try engine(guid: "built-in") == .bing)
        #expect(try engine(guid: "own") == .duckDuckGo)
        #expect(try engine(guid: "elsewhere") == nil)
        #expect(try engine(guid: "") == nil)
        #expect(try engine(guid: "", mirrored: ["prepopulate_id": 1, "url": "{google:baseURL}search?q={searchTerms}"]) == nil)
        #expect(try engine(guid: "missing", mirrored: ["prepopulate_id": 1, "url": "{google:baseURL}search?q={searchTerms}"]) == .google)
    }

    @Test func aDatabaseWithoutTheKeywordsTableCannotBeRead() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.database("Web Data", ["CREATE TABLE autofill (name VARCHAR)"])
        #expect(throws: ImportError.unreadableFile(file)) { try SearchKeywords.read(at: file, preferences: nil) }
    }
}
