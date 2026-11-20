// A menu item that runs a closure. `ARCHEngine` uses it for page context menus.
// App features also add it to those and other menus.
import AppKit

/// Runs its closure when chosen. As its own target, it works in any menu. It keeps captured values while the menu keeps it.
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
        handler = {}
        super.init(coder: coder)
        isEnabled = false
    }

    @objc private func run() {
        handler()
    }
}
