// A context menu submenu whose items send AppKit's standard actions to one view, the engine's page view. AppKit validates the items against the view each time the submenu opens, as it validates any menu: the view's `validateUserInterfaceItem:` enables each item and sets a switch's check mark, so the submenu shows the view's own state.
import AppKit

/// Builds a submenu of standard actions aimed at one view.
enum EngineStandardActionSubmenu {
    /// One entry of the submenu.
    enum Entry {
        /// AppKit's standard action, sent to the view. Left out when the view does not take it.
        case action(String, Selector)
        /// An action sent to another object than the view, for what the view's actions do not do alike on both engines.
        case send(String, Selector, to: AnyObject)
        case separator
    }

    /// An item titled `title` with a submenu of `entries`, leaving out the actions `view` does not take (`respondsToSelector:`). A separator shows only between items. Nil when `view` takes none of the actions.
    static func item(_ title: String, _ identifier: NSUserInterfaceItemIdentifier, sendingTo view: NSView, _ entries: [Entry]) -> NSMenuItem? {
        let menu = NSMenu(title: title)
        for entry in entries {
            switch entry {
            case let .action(title, action):
                guard view.responds(to: action) else { continue }
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = view
                menu.addItem(item)
            case let .send(title, action, target):
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = target
                menu.addItem(item)
            case .separator:
                if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            }
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        guard menu.items.contains(where: { $0.target === view }) else { return nil }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = identifier
        item.submenu = menu
        item.isEnabled = true
        return item
    }
}
