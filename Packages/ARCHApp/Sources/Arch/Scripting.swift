// AppleScript support for the terms in `Arch.sdef`. Cocoa Scripting finds these classes by their Objective-C names and reads their properties through key-value coding.
import AppKit
import Browsing

/// The application's scripting keys.
extension ArchApplication {
    private var browserSession: BrowserSession? { (delegate as? AppDelegate)?.session }

    /// Every tab in sidebar order (`BrowserSession.tabsInSidebarOrder`): the favorites' open tabs, then each space's pinned tabs and its open tabs, then the small windows' tabs.
    @objc var scriptTabs: [ScriptTab] {
        browserSession?.tabsInSidebarOrder.map { ScriptTab($0) } ?? []
    }

    /// The active window's selected tab.
    @objc var scriptActiveTab: ScriptTab? { browserSession?.focusedTab.map { ScriptTab($0) } }

    /// Resolves `tab id "…"`. The identifier comes from the script, so it may not be text.
    @objc(valueInScriptTabsWithUniqueID:) func scriptTab(withUniqueID uniqueID: Any) -> ScriptTab? {
        guard let text = uniqueID as? String, let id = UUID(uuidString: text) else { return nil }
        return browserSession?.allTabs.first { $0.id == id }.map { ScriptTab($0) }
    }
}

/// A tab as scripts see it. Each request makes new ones, and scripts refer to a tab by its identifier.
@objc(ArchScriptTab) final class ScriptTab: NSObject {
    private let tab: Tab

    init(_ tab: Tab) {
        self.tab = tab
        super.init()
    }

    @objc var uniqueID: String { tab.id.uuidString }
    /// The tab's name as the sidebar shows it: the user's, a hook's, or the page's title.
    @objc var name: String { tab.displayTitle }
    @objc var url: String { tab.url?.absoluteString ?? "" }

    /// `NSApp.classDescription` is nil for an `NSApplication` subclass, so the description comes from the scripting class.
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: application, containerSpecifier: nil, key: "scriptTabs", uniqueID: uniqueID)
    }
}
