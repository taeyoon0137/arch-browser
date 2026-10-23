// Registers the engines, opens the main window, and connects the menu bar to the browser session.
import AppKit
import ARCHEngine
import ARCHEngineWebKit
import Browsing
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var session: BrowserSession!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let registry = EngineRegistry.shared
        registry.register(WebKitEngine())
        guard let engine = registry.engine(for: registry.defaultKind) else { fatalError("No engine registered") }
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch")
        do {
            session = try BrowserSession(engine: engine, userDataDirectory: supportDirectory)
        } catch {
            fatalError("Browser session failed to start: \(error)")
        }
        session.openTab()
        NSApp.mainMenu = makeMainMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Arch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        let hostingController = NSHostingController(rootView: BrowserWindowView(session: session))
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 800, height: 500)
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Arch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu(appMenu, title: "Arch"))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Open Location", action: #selector(openLocation), keyEquivalent: "l")
        mainMenu.addItem(submenu(fileMenu, title: "File"))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu(editMenu, title: "Edit"))

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(reload), keyEquivalent: "r")
        mainMenu.addItem(submenu(viewMenu, title: "View"))

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        mainMenu.addItem(submenu(historyMenu, title: "History"))
        return mainMenu
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func newTab() { session.openTab() }
    @objc private func closeTab() { session.closeSelectedTab() }
    @objc private func openLocation() { session.focusCommandBar() }
    @objc private func toggleSidebar() { session.toggleSidebar() }
    @objc private func reload() { session.reload() }
    @objc private func goBack() { session.goBack() }
    @objc private func goForward() { session.goForward() }
}
