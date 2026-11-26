// Settings' sync choices share Browsing's English and Korean string catalog.
import Foundation

public enum SyncChoiceLabels {
    public static var sidebar: String { localized("Sidebar") }
    public static var sidebarDetail: String { localized("Personas, spaces, pinned tabs and folders, and favorites.") }
    public static var settings: String { localized("Settings") }
    public static var siteRules: String { localized("Site Rules") }
    public static var openTabs: String { localized("Open Tabs from Other Macs") }
    public static var plugins: String { localized("Plugins") }
    public static var explanation: String {
        localized("Turning an item off keeps its data in iCloud, except the list of open tabs shared by this Mac. History, website data, plugin storage, and secrets stay on this Mac.")
    }
}
