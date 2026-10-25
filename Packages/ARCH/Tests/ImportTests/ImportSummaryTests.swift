// The summary lines both imports share: one per kind that came in, with singular and plural nouns.
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
}
