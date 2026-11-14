// The summary lines both imports share: one per kind that came in, with singular and plural nouns, and whether anything came in, as after a second identical import. History pages hold made-up addresses only.
import Foundation
import History
import Testing
@testable import Browsing
@testable import Import

@Suite struct ImportSummaryTests {
    @Test func eachKindThatCameInHasALine() {
        var summary = ImportSummary()
        summary.add(SidebarImport.Counts(personas: 1, spaces: 2, pinnedTabs: 24, favorites: 1, presentFavorites: 0))
        summary.add(SidebarImport.Counts(personas: 0, spaces: 0, pinnedTabs: 1, favorites: 2, presentFavorites: 3))
        summary.historyPages = 5_210
        summary.shortcuts = 1
        summary.skippedShortcuts = 2
        summary.searchEngine = .bing
        summary.failures = ["A file could not be read."]
        #expect(summary.lines == [
            "Created 1 Persona.",
            "Added 2 spaces and 25 pinned tabs.",
            "Added 3 favorites. 3 were already in favorites.",
            "Imported \(5_210.formatted()) pages into history.",
            "Added 1 search shortcut. Skipped 2 with a keyword in use or an address Arch cannot use.",
            "The search engine is now Bing.",
        ])
    }

    @Test func kindsWithNothingHaveNoLine() {
        var summary = ImportSummary()
        #expect(summary.lines.isEmpty)
        summary.presentFavorites = 1
        summary.pinnedTabs = 1
        #expect(summary.lines == ["Added 1 pinned tab.", "Added 0 favorites. 1 was already in favorites."])
    }

    @Test func aSecondIdenticalImportBringsNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let history = HistoryStore(directory: folder.url)
        func importPages(_ entries: [HistoryEntry], summary: ImportSummary = ImportSummary()) async -> ImportSummary {
            await withCheckedContinuation { continuation in
                summary.importHistory(entries, into: history) { continuation.resume(returning: $0) }
            }
        }
        let page = HistoryEntry(url: URL(string: "https://a.example/")!, title: "A", visitCount: 2, lastVisit: Date(timeIntervalSince1970: 100))
        let other = HistoryEntry(url: URL(string: "https://b.example/")!, title: "", visitCount: 1, lastVisit: Date(timeIntervalSince1970: 100))
        // Two profiles both list the first page, which counts once.
        let entries = [page, other, HistoryEntry(url: page.url, title: "A", visitCount: 3, lastVisit: page.lastVisit)]
        #expect(await importPages(entries).historyPages == 2)

        // Again, the history store changes nothing, and only favorites already present and skipped shortcuts remain.
        var summary = ImportSummary()
        summary.presentFavorites = 12
        summary.skippedShortcuts = 3
        summary = await importPages(entries, summary: summary)
        #expect(summary.historyPages == 0)
        #expect(!summary.hasAdditions)
        #expect(summary.presentFavorites == 12 && summary.skippedShortcuts == 3)
        // A page without a title takes the import's, which counts as a change.
        #expect(await importPages([HistoryEntry(url: other.url, title: "B", visitCount: 1, lastVisit: other.lastVisit)]).historyPages == 1)
        summary.searchEngine = .bing
        #expect(summary.hasAdditions)
    }
}
