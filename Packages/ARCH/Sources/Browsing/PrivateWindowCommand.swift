// The File and Dock menus share the private window command and its localized title.
import AppKit

@MainActor
public enum PrivateWindowCommand {
    public static func menuItem(target: AnyObject, action: Selector, withShortcut: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: localized("New Private Window"), action: action, keyEquivalent: withShortcut ? "N" : "")
        item.keyEquivalentModifierMask = withShortcut ? [.command, .shift] : []
        item.target = target
        return item
    }
}
