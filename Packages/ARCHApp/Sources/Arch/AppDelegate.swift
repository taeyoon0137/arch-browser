// Registers the engines, opens the main window, and connects the menu bar to the browser session.
import AppKit
import ARCHEngine
import ARCHEngineChromium
import ARCHEngineWebKit
import ARCHPrivateAPI
import Browsing
import History
import Preferences
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var session: BrowserSession!
    /// Lists the selected tab's recent pages each time it opens.
    private var historyMenu: NSMenu?
    private static let recentPageTag = 9_100
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
        // The session starts the default engine, or another one when the default fails to start, and starts the rest as tabs need them.
        guard let session = try? BrowserSession(registry: registry, userDataDirectory: supportDirectory) else { fatalError("No engine could start") }
        self.session = session
        session.showSettings = { PreferencesWindowController.shared.show() }
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
        installUndoCloseShortcut()
        installFullscreenEscape()
        // Engines register their private APIs when they start; the checks run without delaying launch.
        PrivateAPIFlags.shared.checkInBackground()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Arch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the title bar the standard height of the system's own apps and centers the traffic light buttons in it, on the sidebar's top row.
        window.toolbar = NSToolbar(identifier: "Main")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        // Full screen hides the traffic lights, so the toolbar would only cover the sidebar's top row there.
        NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.window.toolbar?.isVisible = false
        }
        // AppKit restores the toolbar's full screen state while it exits, so the toolbar returns once the window is back.
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.window.toolbar?.isVisible = true
        }
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

    func setQuitting(_ quitting: Bool) {
        session?.isQuitting = quitting
    }

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
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetZoom), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        // A hidden twin takes ⌘=, so zooming in needs no Shift where + shares a key with =.
        let zoomInWithoutShift = viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        zoomInWithoutShift.isHidden = true
        zoomInWithoutShift.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        let developerMenu = NSMenu(title: "Developer")
        developerMenu.addItem(withTitle: "Show Developer Tools", action: #selector(showDeveloperTools), keyEquivalent: "i").keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(submenu(developerMenu, title: "Developer"))
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
        historyMenu.delegate = self
        self.historyMenu = historyMenu
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
    @objc private func showDeveloperTools() { session.showDeveloperTools() }
    @objc private func toggleDownloads() { session.toggleLibrary() }
    @objc private func reload() { session.reload() }
    @objc private func zoomIn() { session.zoomIn() }
    @objc private func zoomOut() { session.zoomOut() }
    @objc private func resetZoom() { session.resetZoom() }
    @objc private func showFindBar() { session.showFindBar() }
    @objc private func findNext() { session.findNext() }
    @objc private func findPrevious() { session.findPrevious() }
    @objc private func goBack() { session.goBack() }
    @objc private func goForward() { session.goForward() }
    @objc private func clearHistory() { HistoryStore.shared.clear() }

    /// Lists the selected tab's previous ten pages, most recent first, between Forward and Clear History.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === historyMenu else { return }
        for item in menu.items where item.tag == Self.recentPageTag { menu.removeItem(item) }
        let pages = session?.recentBackItems(limit: 10) ?? []
        guard !pages.isEmpty, let tabID = session.selectedTabID, let separator = menu.items.firstIndex(where: \.isSeparatorItem) else { return }
        var index = separator + 1
        for page in pages {
            let item = NSMenuItem(title: page.title.isEmpty ? page.url.host ?? page.url.absoluteString : page.title, action: #selector(goToRecentPage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RecentPage(tabID: tabID, item: page)
            item.toolTip = page.url.absoluteString
            item.tag = Self.recentPageTag
            menu.insertItem(item, at: index)
            index += 1
        }
        let end = NSMenuItem.separator()
        end.tag = Self.recentPageTag
        menu.insertItem(end, at: index)
    }

    @objc private func goToRecentPage(_ sender: NSMenuItem) {
        guard let page = sender.representedObject as? RecentPage else { return }
        session.go(to: page.item, inTab: page.tabID)
    }

    /// A History menu page and its original tab.
    private final class RecentPage {
        let tabID: UUID
        let item: any EngineBackForwardListItem

        init(tabID: UUID, item: any EngineBackForwardListItem) {
            self.tabID = tabID
            self.item = item
        }
    }
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

    /// The Appearance checkmark reflects the stored value, which the Settings window can also change. Only an app bundle can become the default browser. Developer tools need an engine that offers them. Zooming needs a selected tab that no internal page covers.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(zoomIn) || item.action == #selector(zoomOut) || item.action == #selector(resetZoom) {
            return session?.canZoom == true
        }
        if item.action == #selector(chooseAppearance(_:)) {
            item.state = (item.representedObject as? String) == AppearanceSetting.current.rawValue ? .on : .off
        }
        if item.action == #selector(setAsDefaultBrowser) {
            return Self.isRunningFromBundle && !Self.isDefaultBrowser
        }
        if item.action == #selector(showDeveloperTools) {
            return session?.canShowDeveloperTools == true
        }
        return true
    }

    @objc private func showSettings() { PreferencesWindowController.shared.show() }

    // MARK: Page fullscreen

    /// A page that fills the window in fullscreen leaves it on Escape, as in full browsers. WebKit shows fullscreen in its own window and handles Escape itself.
    private func installFullscreenEscape() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  let self, let session = self.session, session.fullscreenTabID != nil, event.window === self.window else { return event }
            session.exitPageFullscreen()
            return nil
        }
    }

    // MARK: Undo close

    /// ⌘Z reopens the tabs the user just closed, newest first, until the user presses a different key or clicks in the page. It runs before the focused page can handle ⌘Z as its own undo.
    private func installUndoCloseShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let session = self?.session else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let isUndo = modifiers == .command && Self.isKey(event, "z", keyCode: 6)
            if isUndo, session.undoableCloseCount > 0 {
                session.reopenLastClosedTab()
                return nil
            }
            // Closing and reopening tabs keep the count. Any other key, whether typing or a shortcut such as ⌘V, makes ⌘Z undo where the user works.
            let closesOrReopens = (Self.isKey(event, "w", keyCode: 13) && (modifiers == .command || modifiers == [.command, .option]))
                || (Self.isKey(event, "t", keyCode: 17) && modifiers == [.command, .shift])
            if !isUndo, !closesOrReopens { session.forgetUndoableCloses() }
            return event
        }
        // A click in the page can start an edit there, such as choosing a spelling suggestion, so ⌘Z then undoes in the page.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let session = self?.session, let view = session.selectedTab?.webContents.view, view.window === event.window,
               view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                session.forgetUndoableCloses()
            }
            return event
        }
    }

    /// Input sources without Latin letters report other characters, so use the key's position on an ANSI keyboard.
    private static func isKey(_ event: NSEvent, _ letter: String, keyCode: UInt16) -> Bool {
        guard let key = event.charactersIgnoringModifiers, key.unicodeScalars.allSatisfy(\.isASCII) else { return event.keyCode == keyCode }
        return key.lowercased() == letter
    }

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
