// A menu item that runs a closure, for the menu items that no view's own action runs: those `ARCHEngine` builds for the page context menu, and those the app's features add to it and to their other menus.
import AppKit

/// Runs its closure when chosen. It is its own target, so it works in any menu and keeps what the closure captures for as long as the menu keeps it.
public final class EngineActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    /// `isEnabled` sets the item's state for a menu that does not enable its items itself.
    public init(_ title: String, isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("EngineActionMenuItem is created in code")
    }

    @objc private func run() {
        handler()
    }
}
