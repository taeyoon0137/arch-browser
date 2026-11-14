// A menu item that runs a closure, for the context menu items `ARCHEngine` builds that no view's own action runs.
import AppKit

/// Runs its closure when chosen. It is its own target, so it works in any menu and keeps what the closure captures for as long as the menu keeps it.
final class EngineActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("EngineActionMenuItem is created in code")
    }

    @objc private func run() {
        handler()
    }
}
