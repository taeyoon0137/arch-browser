// Registers the engines, opens the main window, and connects the menu bar to the browser session.
import AppKit
import ARCHEngine
import ARCHEngineChromium
import ARCHEngineWebKit
import Browsing
import History
import Preferences
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var session: BrowserSession!
    private var window: NSWindow!
    /// URLs the app receives before the session exists. They open once the session is created.
    private var pendingURLs: [URL] = []
    private static let askedDefaultBrowserKey = "ARCHAskedDefaultBrowser"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let registry = EngineRegistry.shared
        registry.register(WebKitEngine())
        if let chromium = ChromiumEngine(frameworkPath: Self.cefFrameworkPath, helperPath: Self.cefHelperPath) {
            registry.register(chromium)
        }
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch")
        // Try the default engine first and fall back to the others when it fails to start.
        for kind in [registry.defaultKind] + registry.registeredKinds.filter({ $0 != registry.defaultKind }) where session == nil {
            guard let engine = registry.engine(for: kind) else { continue }
            session = try? BrowserSession(engine: engine, userDataDirectory: supportDirectory)
        }
        guard session != nil else { fatalError("No engine could start") }
        if !pendingURLs.isEmpty {
            pendingURLs.forEach { session.openTab(url: $0) }
            pendingURLs.removeAll()
        } else if let startURL = ProcessInfo.processInfo.environment["ARCH_START_URL"].flatMap(URL.init(string:)) {
            session.openTab(url: startURL)
        } else if session.tabs.isEmpty {
            session.openTab()
        }
        NSApp.appearance = AppearanceSetting.current.appearance
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
        promptForDefaultBrowserIfNeeded()
    }

    /// Opens links from other apps in new tabs. Links received before launch finishes wait for the session.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let session else {
            pendingURLs += urls
            return
        }
        urls.forEach { session.openTab(url: $0) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session?.saveNow()
    }

    // Inside an app bundle the CEF framework and helpers sit in Contents/Frameworks; a bare build reads the paths from the environment.
    private static var cefFrameworkPath: String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ARCH_CEF_FRAMEWORK_PATH"] { return path }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework").path
    }

    private static var cefHelperPath: String? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ARCH_CEF_HELPER_PATH"] { return path }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Arch Helper.app/Contents/MacOS/Arch Helper").path
        return FileManager.default.fileExists(atPath: bundled) ? bundled : nil
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Set as Default Browser\u{2026}", action: #selector(setAsDefaultBrowser), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Arch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu(appMenu, title: "Arch"))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        let closeOthersItem = fileMenu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs), keyEquivalent: "w")
        closeOthersItem.keyEquivalentModifierMask = [.command, .option]
        let reopenItem = fileMenu.addItem(withTitle: "Reopen Last Closed Tab", action: #selector(reopenClosedTab), keyEquivalent: "T")
        reopenItem.keyEquivalentModifierMask = [.command, .shift]
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
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find\u{2026}", action: #selector(showFindBar), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        let findPreviousItem = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "G")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        mainMenu.addItem(submenu(editMenu, title: "Edit"))

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(reload), keyEquivalent: "r")
        let downloadsItem = viewMenu.addItem(withTitle: "Downloads", action: #selector(toggleDownloads), keyEquivalent: "J")
        downloadsItem.keyEquivalentModifierMask = [.command, .shift]
        let appearanceMenu = NSMenu(title: "Appearance")
        for (title, setting) in [("System", AppearanceSetting.system), ("Light", .light), ("Dark", .dark)] {
            appearanceMenu.addItem(withTitle: title, action: #selector(chooseAppearance(_:)), keyEquivalent: "").representedObject = setting.rawValue
        }
        viewMenu.addItem(submenu(appearanceMenu, title: "Appearance"))
        mainMenu.addItem(submenu(viewMenu, title: "View"))

        let tabMenu = NSMenu(title: "Tab")
        tabMenu.addItem(withTitle: "Pin or Unpin Tab", action: #selector(togglePinned), keyEquivalent: "d")
        let favoriteItem = tabMenu.addItem(withTitle: "Add to Favorites", action: #selector(addFavorite), keyEquivalent: "D")
        favoriteItem.keyEquivalentModifierMask = [.command, .shift]
        tabMenu.addItem(.separator())
        let nextTabItem = tabMenu.addItem(withTitle: "Next Tab", action: #selector(nextTab), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        let previousTabItem = tabMenu.addItem(withTitle: "Previous Tab", action: #selector(previousTab), keyEquivalent: "[")
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        let moveUpItem = tabMenu.addItem(withTitle: "Move Tab Up", action: #selector(moveTabUp), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        moveUpItem.keyEquivalentModifierMask = [.command, .option]
        let moveDownItem = tabMenu.addItem(withTitle: "Move Tab Down", action: #selector(moveTabDown), keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        moveDownItem.keyEquivalentModifierMask = [.command, .option]
        tabMenu.addItem(.separator())
        for number in 1...8 {
            tabMenu.addItem(withTitle: "Select Tab \(number)", action: #selector(selectTab(_:)), keyEquivalent: String(number)).tag = number
        }
        tabMenu.addItem(withTitle: "Select Last Tab", action: #selector(selectLastTab), keyEquivalent: "9")
        mainMenu.addItem(submenu(tabMenu, title: "Tab"))

        let spacesMenu = NSMenu(title: "Spaces")
        let newSpaceItem = spacesMenu.addItem(withTitle: "New Space", action: #selector(newSpace), keyEquivalent: "n")
        newSpaceItem.keyEquivalentModifierMask = [.command, .control]
        let nextSpaceItem = spacesMenu.addItem(withTitle: "Next Space", action: #selector(nextSpace), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        nextSpaceItem.keyEquivalentModifierMask = [.command, .control]
        let previousSpaceItem = spacesMenu.addItem(withTitle: "Previous Space", action: #selector(previousSpace), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        previousSpaceItem.keyEquivalentModifierMask = [.command, .control]
        mainMenu.addItem(submenu(spacesMenu, title: "Spaces"))

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        mainMenu.addItem(submenu(historyMenu, title: "History"))
        return mainMenu
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func newTab() { session.showCommandPalette(.newTab) }
    @objc private func closeTab() { session.closeSelectedTab() }
    @objc private func closeOtherTabs() { session.closeOtherTabs() }
    @objc private func reopenClosedTab() { session.reopenLastClosedTab() }
    @objc private func nextTab() { session.selectAdjacentTab(forward: true) }
    @objc private func previousTab() { session.selectAdjacentTab(forward: false) }
    @objc private func moveTabUp() { session.moveSelectedTab(up: true) }
    @objc private func moveTabDown() { session.moveSelectedTab(up: false) }
    @objc private func selectTab(_ sender: NSMenuItem) { session.selectTab(at: sender.tag - 1) }
    @objc private func selectLastTab() { session.selectLastTab() }
    @objc private func openLocation() { session.focusCommandBar() }
    @objc private func toggleSidebar() { session.toggleSidebar() }
    @objc private func toggleDownloads() { session.toggleDownloadsPopover() }
    @objc private func reload() { session.reload() }
    @objc private func showFindBar() { session.showFindBar() }
    @objc private func findNext() { session.findNext() }
    @objc private func findPrevious() { session.findPrevious() }
    @objc private func goBack() { session.goBack() }
    @objc private func goForward() { session.goForward() }
    @objc private func clearHistory() { HistoryStore.shared.clear() }
    @objc private func togglePinned() { session.selectedTab.map(session.togglePinned) }
    @objc private func addFavorite() { session.selectedTab.map(session.addFavorite) }
    @objc private func newSpace() { session.addSpace() }
    @objc private func nextSpace() { session.switchToAdjacentSpace(forward: true) }
    @objc private func previousSpace() { session.switchToAdjacentSpace(forward: false) }

    // MARK: Appearance

    // Not named `setAppearance(_:)`: `NSApplication` answers that selector first in the responder chain and would take the menu item as its appearance.
    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        let setting = (sender.representedObject as? String).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
        UserDefaults.standard.set(setting.rawValue, forKey: AppearanceSetting.defaultsKey)
        NSApp.appearance = setting.appearance
    }

    /// The Appearance checkmark reflects the stored value, which the Settings window can also change. Only an app bundle can become the default browser.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseAppearance(_:)) {
            item.state = (item.representedObject as? String) == AppearanceSetting.current.rawValue ? .on : .off
        }
        if item.action == #selector(setAsDefaultBrowser) {
            return Self.isRunningFromBundle && !Self.isDefaultBrowser
        }
        return true
    }

    @objc private func showSettings() { PreferencesWindowController.shared.show() }

    // MARK: Default browser

    /// A bare build product has no app bundle, so the system cannot register it to handle URLs.
    private static var isRunningFromBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private static var isDefaultBrowser: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// The system shows its own confirmation. Registering http covers https as well.
    @objc private func setAsDefaultBrowser() {
        guard Self.isRunningFromBundle else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { _ in }
    }

    /// Prompts once per user after the window opens. Skips the prompt outside an app bundle or when the app is already the default browser.
    private func promptForDefaultBrowserIfNeeded() {
        let defaults = UserDefaults.standard
        guard Self.isRunningFromBundle, !defaults.bool(forKey: Self.askedDefaultBrowserKey), !Self.isDefaultBrowser else { return }
        defaults.set(true, forKey: Self.askedDefaultBrowserKey)
        let alert = NSAlert()
        alert.messageText = "Set Arch as your default browser?"
        alert.informativeText = "Links from other apps will open in Arch."
        alert.addButton(withTitle: "Set as Default")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.setAsDefaultBrowser() }
        }
    }
}
