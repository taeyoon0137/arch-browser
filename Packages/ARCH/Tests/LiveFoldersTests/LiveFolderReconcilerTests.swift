// Plans for a folder's tabs and its read state (live folder rules 4 and 5; docs/bookmarks.md, Tests ▸ LiveFoldersTests).
import Foundation
import Testing
@testable import LiveFolders

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func tab(_ itemID: String, title: String? = nil, hasPage: Bool = false, isShown: Bool = false) -> LiveItemTab {
    LiveItemTab(tabID: UUID(), itemID: itemID, hasPage: hasPage, isShown: isShown, title: title ?? "Item \(itemID)")
}

@Suite struct LiveFolderReconcilerTests {
    @Test func addsNewItemsInTheSourcesOrder() {
        let b = tab("b")
        let plan = LiveFolderReconciler.plan(items: [item("a"), item("b"), item("c")], tabs: [b], dismissed: [])
        #expect(plan.additions.map(\.id) == ["a", "c"])
        #expect(plan.order == [.newItem("a"), .tab(b.tabID), .newItem("c")])
        #expect(plan.removals.isEmpty)
        #expect(plan.retitled.isEmpty)
    }

    @Test func retitlesTabsWhoseItemsChangedTitle() {
        let a = tab("a", title: "Old"), b = tab("b")
        let plan = LiveFolderReconciler.plan(items: [item("a", title: "New"), item("b")], tabs: [a, b], dismissed: [])
        #expect(plan.retitled == [a.tabID: "New"])
        #expect(plan.additions.isEmpty)
    }

    @Test func removesTabsOfGoneItemsUnlessTheyHavePagesOrAreShown() {
        let gone = tab("gone"), loaded = tab("loaded", hasPage: true), shown = tab("shown", isShown: true), kept = tab("kept")
        let plan = LiveFolderReconciler.plan(items: [item("kept"), item("new")], tabs: [gone, loaded, shown, kept], dismissed: [])
        #expect(plan.removals == [gone.tabID])
        // Tabs kept for gone items go last, in their order.
        #expect(plan.order == [.tab(kept.tabID), .newItem("new"), .tab(loaded.tabID), .tab(shown.tabID)])
        // Once it loses its page, the kept tab goes at the next plan.
        let unloaded = LiveItemTab(tabID: loaded.tabID, itemID: "loaded", hasPage: false, isShown: false, title: loaded.title)
        #expect(LiveFolderReconciler.plan(items: [item("kept")], tabs: [unloaded, kept], dismissed: []).removals == [loaded.tabID])
    }

    @Test func leavesDismissedItemsOutAndSecondTabsGo() {
        let first = tab("a"), second = tab("a")
        let plan = LiveFolderReconciler.plan(items: [item("a"), item("b"), item("c")], tabs: [first, second], dismissed: ["b"])
        #expect(plan.additions.map(\.id) == ["c"])
        #expect(plan.removals == [second.tabID])
        #expect(plan.order == [.tab(first.tabID), .newItem("c")])
    }

    @Test func theFirstFetchIsReadAndLaterItemsAreUnread() {
        var state = LiveFolderState()
        state.recordSuccess(items: [item("a"), item("b")], at: start)
        #expect(state.unreadItemIDs.isEmpty)
        state.recordSuccess(items: [item("c"), item("a"), item("b")], at: start + 60)
        #expect(state.unreadItemIDs == ["c"])
        state.markViewed(["c"], at: start + 120)
        #expect(state.unreadItemIDs.isEmpty)
        state.markUnread("a")
        #expect(state.unreadItemIDs == ["a"])
        state.dismiss("a")
        #expect(state.unreadItemIDs.isEmpty)
        state.restoreDismissed()
        state.markAllViewed(at: start + 180)
        #expect(state.unreadItemIDs.isEmpty)
        // Items the source does not list are not marked.
        state.markViewed(["unknown"], at: start)
        #expect(state.viewedAt["unknown"] == nil)
    }

    @Test func gitHubItemsUpdatedAfterTheyWereViewedAreUnread() {
        var state = LiveFolderState()
        state.recordSuccess(items: [item("pr", date: start - 3_600, gitHub: pullRequest)], at: start)
        #expect(state.unreadItemIDs.isEmpty)
        state.recordSuccess(items: [item("pr", date: start + 600, gitHub: pullRequest)], at: start + 900)
        #expect(state.unreadItemIDs == ["pr"])
        // A feed item's date does not make it unread.
        var feed = LiveFolderState()
        feed.recordSuccess(items: [item("post", date: start)], at: start)
        feed.recordSuccess(items: [item("post", date: start + 600)], at: start + 900)
        #expect(feed.unreadItemIDs.isEmpty)
    }

    /// A change the user made while looking, such as an approval, comes before the `viewedAt` set as the tab stopped showing, so the item stays read.
    @Test func anUpdateBeforeTheTabStoppedShowingStaysRead() {
        var state = LiveFolderState()
        state.recordSuccess(items: [item("pr", date: start, gitHub: pullRequest)], at: start)
        state.markViewed(["pr"], at: start + 60)
        let approvedAt = start + 120
        state.markViewed(["pr"], at: start + 180)
        state.recordSuccess(items: [item("pr", date: approvedAt, gitHub: pullRequest)], at: start + 300)
        #expect(state.unreadItemIDs.isEmpty)
    }
}
