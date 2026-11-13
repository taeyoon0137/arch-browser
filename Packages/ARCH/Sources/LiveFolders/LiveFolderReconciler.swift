// How a live folder's tabs follow its items (docs/bookmarks.md, Live folders ▸ Items as tabs and Read and unread; live folder rules 4 and 5). The session describes its item tabs as values and applies the plan; nothing here touches a tab.
import Foundation

/// One of a live folder's tabs, as the session sees it.
public struct LiveItemTab: Hashable, Sendable {
    public var tabID: UUID
    public var itemID: String
    /// Whether the tab holds a page rather than a stand-in.
    public var hasPage: Bool
    /// Whether a window shows the tab.
    public var isShown: Bool
    /// The title of the tab's saved page, which is its item's title.
    public var title: String

    public init(tabID: UUID, itemID: String, hasPage: Bool, isShown: Bool, title: String) {
        self.tabID = tabID
        self.itemID = itemID
        self.hasPage = hasPage
        self.isShown = isShown
        self.title = title
    }
}

/// The changes that bring a folder's tabs in line with its items.
public struct LiveFolderPlan: Equatable, Sendable {
    public enum Entry: Hashable, Sendable {
        case tab(UUID)
        /// The new tab for the item with this ID.
        case newItem(String)
    }

    /// Items that get a new tab, in the source's order.
    public var additions: [LiveItem] = []
    /// New saved page titles for tabs whose items changed title.
    public var retitled: [UUID: String] = [:]
    /// Tabs to remove, without the closed list.
    public var removals: [UUID] = []
    /// Every tab the folder keeps, in order: the source's, then tabs kept for items it no longer lists.
    public var order: [Entry] = []
}

public enum LiveFolderReconciler {
    /// Adds a tab for each listed item that has none and is not dismissed, retitles tabs whose items changed title, and removes tabs for items the source no longer lists, or that are dismissed, unless the tab has its page or a window shows it. A kept tab that later loses its page goes at the next plan. A second tab for one item counts as one for an item no longer listed.
    public static func plan(items: [LiveItem], tabs: [LiveItemTab], dismissed: Set<String>) -> LiveFolderPlan {
        var tabForItem: [String: LiveItemTab] = [:]
        for tab in tabs where tabForItem[tab.itemID] == nil { tabForItem[tab.itemID] = tab }
        var plan = LiveFolderPlan()
        var matched = Set<UUID>()
        var listed = Set<String>()
        for item in items where !dismissed.contains(item.id) && listed.insert(item.id).inserted {
            if let tab = tabForItem[item.id] {
                matched.insert(tab.tabID)
                plan.order.append(.tab(tab.tabID))
                if tab.title != item.title { plan.retitled[tab.tabID] = item.title }
            } else {
                plan.additions.append(item)
                plan.order.append(.newItem(item.id))
            }
        }
        for tab in tabs where !matched.contains(tab.tabID) {
            if tab.hasPage || tab.isShown {
                plan.order.append(.tab(tab.tabID))
            } else {
                plan.removals.append(tab.tabID)
            }
        }
        return plan
    }
}

// MARK: - Read and unread

extension LiveFolderState {
    /// Unread: never viewed, or for GitHub, updated after it was last viewed (live folder rule 5).
    public func isUnread(_ item: LiveItem) -> Bool {
        guard let viewed = viewedAt[item.id] else { return true }
        guard item.gitHub != nil, let updated = item.date else { return false }
        return updated > viewed
    }

    /// The IDs of the unread items that are not dismissed, for the dots and the folder's count.
    public var unreadItemIDs: Set<String> {
        Set(items.filter { !dismissed.contains($0.id) && isUnread($0) }.map(\.id))
    }

    /// A window showed the items' tabs, stopped showing them, or the user chose Mark as Read.
    public mutating func markViewed(_ itemIDs: some Sequence<String>, at date: Date) {
        let listed = Set(items.map(\.id))
        for id in itemIDs where listed.contains(id) { viewedAt[id] = date }
    }

    /// Mark as Unread.
    public mutating func markUnread(_ itemID: String) {
        viewedAt[itemID] = nil
    }

    /// Mark All as Read.
    public mutating func markAllViewed(at date: Date) {
        markViewed(items.map(\.id), at: date)
    }

    /// Closing an item's tab.
    public mutating func dismiss(_ itemID: String) {
        dismissed.insert(itemID)
    }

    /// Show Dismissed Items.
    public mutating func restoreDismissed() {
        dismissed = []
    }
}
