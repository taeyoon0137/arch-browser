// Registers the engines, creates the browser session, which opens the browser windows, and connects the menu bar to it.
import AppKit
import ARCHEngine
import ARCHEngineChromium
import ARCHEngineWebKit
import ARCHPrivateAPI
import Browsing
import History
import Import
import Plugins
import Preferences
import Terminal

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    /// Scripting reads it through the application.
    private(set) var session: BrowserSession!
    /// Lists the selected tab's recent pages each time it opens.
    private var historyMenu: NSMenu?
    private static let recentPageTag = 9_100
    /// The Window menu, which becomes `NSApp.windowsMenu` once the shortcut settings have listed the menu bar.
    private var windowMenu: NSMenu?
    /// Keeps the Plugins menu's controller, which its items target.
    private var pluginsMenu: PluginsMenu?
    /// URLs the app receives before the session exists. They open once the session is created.
    private var pendingURLs: [URL] = []
    /// When Arch last became active. A link that arrives just after came with the activation the sending app gave Arch, so it counts as arriving in the background.
    private var becameActiveAt: Date?
    private static let askedDefaultBrowserKey = "ARCHAskedDefaultBrowser"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Data kept under the previous bundle identifier moves before the engines start and the preferences are read.
        BundleIdentifierMigration.runAtLaunch()
        let registry = EngineRegistry.shared
        registry.register(WebKitEngine())
        if let chromium = ChromiumEngine(frameworkPath: Self.cefFrameworkPath, helperPath: Self.cefHelperPath) {
            registry.register(chromium)
        }
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch")
        // The session starts the default engine, or another one when the default fails to start, and starts the rest as tabs need them. Every Persona offers the built-in plugins that ship with the app.
        guard let session = try? BrowserSession(registry: registry, userDataDirectory: supportDirectory, builtInPlugins: [PageAddressPlugin.self]) else { fatalError("No engine could start") }
        self.session = session
        session.showSettings = { PreferencesWindowController.shared.show() }
        session.pageAssistant.showAISettings = { PreferencesWindowController.shared.showAISection() }
        PreferencesWindowController.openTerminal = { TerminalWindowController.shared.show() }
        PreferencesWindowController.session = session
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.becameActiveAt = Date()
        }
        // The sidebar takes the place of window tabs, so AppKit offers no tab bar or tab menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.appearance = AppearanceSetting.current.appearance
        NSApp.mainMenu = makeMainMenu()
        installUndoCloseShortcut()
        installFullscreenEscape()
        installTabSwitcher()
        installShortcuts()
        installPluginsMenu()
        // Set after the shortcut settings list the menu bar, so that the window list AppKit adds to the Window menu stays out of Settings ▸ Shortcuts.
        NSApp.windowsMenu = windowMenu
        // The small window's button names the shortcut, which Settings ▸ Shortcuts can change.
        session.moveToMainWindowShortcut = { [weak self] in
            self?.windowMenu?.items.first { $0.action == #selector(AppDelegate.moveToMainWindow) }.flatMap(KeyShortcut.init(menuItem:))?.displayName
        }
        // Engines register their private APIs when they start; the checks run without delaying launch.
        PrivateAPIFlags.shared.checkInBackground()
        session.restoreWindows()
        if !pendingURLs.isEmpty {
            pendingURLs.forEach { session.openTab(url: $0) }
            pendingURLs.removeAll()
        } else if let startURL = ProcessInfo.processInfo.environment["ARCH_START_URL"].flatMap(URL.init(string:)) {
            session.openTab(url: startURL)
        } else if session.allTabs.isEmpty {
            session.openTab()
        }
        NSApp.activate(ignoringOtherApps: true)
        promptForDefaultBrowserIfNeeded()
    }

    /// Opens links from other apps and addresses from `open location` scripts. Links received before launch finishes wait for the session and open as tabs of the main window. Afterwards, while Settings ▸ General allows small windows, a link that arrives while Arch is in the background opens in a small window of its own, which comes forward alone; otherwise links open in new tabs of the sidebar target. A script's text may lack a scheme, so it is read as the address field reads it, and text that is not a web address is dropped.
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.compactMap { url in
            url.scheme == nil ? BrowserSession.url(forInput: url.absoluteString.removingPercentEncoding ?? url.absoluteString) : url
        }
        guard !urls.isEmpty else { return }
        guard let session else {
            pendingURLs += urls
            return
        }
        if allowsSmallWindowsForLinks, BrowserSession.opensLinkInSmallWindow(isAppActive: NSApp.isActive, becameActiveAt: becameActiveAt, now: Date()) {
            urls.forEach { session.openSmallWindow(url: $0) }
            // Without `.activateAllWindows`, only the key and main windows come forward.
            NSRunningApplication.current.activate(options: [])
            return
        }
        frontSidebarTarget()
        urls.forEach { session.openTab(url: $0) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Settings ▸ General's preference, read for each link so that a change applies to the next one.
    private var allowsSmallWindowsForLinks: Bool {
        UserDefaults.standard.object(forKey: BrowserSession.opensLinksInSmallWindowKey) as? Bool ?? BrowserSession.opensLinksInSmallWindowByDefault
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A Dock click opens a main window where the last one was while Settings, History, or another of the app's windows keeps the app running without one. Otherwise AppKit brings the windows forward as usual.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let session, session.lastMainWindow == nil else { return true }
        // With no main window open, the sidebar target is a new one.
        _ = session.sidebarTarget()
        return false
    }

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
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        let closeWindowItem = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        let closeOthersItem = fileMenu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs), keyEquivalent: "w")
        closeOthersItem.keyEquivalentModifierMask = [.command, .option]
        let reopenItem = fileMenu.addItem(withTitle: "Reopen Last Closed Tab", action: #selector(reopenClosedTab), keyEquivalent: "T")
        reopenItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Open Location", action: #selector(openLocation), keyEquivalent: "l")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Share\u{2026}", action: #selector(sharePage), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Import Bookmarks and History\u{2026}", action: #selector(importBookmarksAndHistory), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Export as PDF\u{2026}", action: #selector(exportAsPDF), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print\u{2026}", action: #selector(printPage), keyEquivalent: "p")
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
        viewMenu.addItem(withTitle: "Show Page Reader", action: #selector(togglePageReader), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetZoom), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        // A hidden twin takes ⌘=, so zooming in needs no Shift where + shares a key with =.
        let zoomInWithoutShift = viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        zoomInWithoutShift.isHidden = true
        zoomInWithoutShift.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Capture Viewport", action: #selector(captureViewport), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Capture Full Page", action: #selector(captureFullPage), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Capture Region\u{2026}", action: #selector(captureRegion), keyEquivalent: "")
        viewMenu.addItem(.separator())
        let developerMenu = NSMenu(title: "Developer")
        developerMenu.addItem(withTitle: "Show Developer Tools", action: #selector(toggleDeveloperTools), keyEquivalent: "i").keyEquivalentModifierMask = [.command, .option]
        developerMenu.addItem(.separator())
        for side in DevToolsSide.allCases {
            developerMenu.addItem(withTitle: side.title, action: #selector(chooseDevToolsSide(_:)), keyEquivalent: "").representedObject = side.rawValue
        }
        developerMenu.addItem(.separator())
        developerMenu.addItem(withTitle: "Show Tab Close Log", action: #selector(showTabCloseLog), keyEquivalent: "")
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
        let splitViewItem = tabMenu.addItem(withTitle: "Open in Split View", action: #selector(openInSplitView), keyEquivalent: "=")
        splitViewItem.keyEquivalentModifierMask = [.command, .option]
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
        spacesMenu.addItem(.separator())
        spacesMenu.addItem(withTitle: "New Persona\u{2026}", action: #selector(newPersona), keyEquivalent: "")
        spacesMenu.addItem(withTitle: "Rename Persona\u{2026}", action: #selector(renamePersona), keyEquivalent: "")
        spacesMenu.addItem(withTitle: "Delete Persona\u{2026}", action: #selector(deletePersona), keyEquivalent: "")
        mainMenu.addItem(submenu(spacesMenu, title: "Spaces"))

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        let homeItem = historyMenu.addItem(withTitle: "Home", action: #selector(goHome), keyEquivalent: "H")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Show All History", action: #selector(showHistory), keyEquivalent: "y")
        historyMenu.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        historyMenu.addItem(withTitle: "Clear Site Data\u{2026}", action: #selector(clearSiteData), keyEquivalent: "")
        historyMenu.delegate = self
        self.historyMenu = historyMenu
        mainMenu.addItem(submenu(historyMenu, title: "History"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Move to Main Window", action: #selector(moveToMainWindow), keyEquivalent: "n").keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        self.windowMenu = windowMenu
        mainMenu.addItem(submenu(windowMenu, title: "Window"))
        return mainMenu
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// The window that sidebar commands act on (`BrowserSession.sidebarTarget()`). It comes forward while a small window is the active window, so that the command shows where it acts.
    @discardableResult
    private func frontSidebarTarget() -> BrowserWindowModel {
        let target = session.sidebarTarget()
        if session.activeWindow?.kind == .small { target.nsWindow?.makeKeyAndOrderFront(nil) }
        return target
    }

    // Page commands act on the active window, and sidebar commands, such as those of the Tab and Spaces menus, on the sidebar target.
    @objc private func newTab() { frontSidebarTarget().showCommandPalette(.newTab) }
    /// A new window shows no tab, so it opens with the new tab palette (open decision 8).
    @objc private func newWindow() { session.openWindow().showCommandPalette(.newTab) }
    /// ⌘W closes the window in front when it is another of the app's windows, such as History, Settings, or the developer tools, not a tab behind it.
    @objc private func closeTab() {
        if let key = NSApp.keyWindow, session.window(for: key) == nil, key.sheetParent == nil, key.styleMask.contains(.closable) { return key.performClose(nil) }
        session.activeWindow?.closeSelectedTab()
    }
    @objc private func closeOtherTabs() { session.activeWindow?.closeOtherTabs() }
    /// The tab reopens in the sidebar target, which comes forward from behind a small window.
    @objc private func reopenClosedTab() {
        frontSidebarTarget()
        session.reopenLastClosedTab()
    }
    @objc private func nextTab() { frontSidebarTarget().selectAdjacentTab(forward: true) }
    @objc private func previousTab() { frontSidebarTarget().selectAdjacentTab(forward: false) }
    @objc private func moveTabUp() { frontSidebarTarget().moveSelectedTab(up: true) }
    @objc private func moveTabDown() { frontSidebarTarget().moveSelectedTab(up: false) }
    @objc private func selectTab(_ sender: NSMenuItem) { frontSidebarTarget().selectTab(at: sender.tag - 1) }
    @objc private func selectLastTab() { frontSidebarTarget().selectLastTab() }
    @objc private func openLocation() { session.activeWindow?.focusCommandBar() }
    // Not named `print(_:)`: windows and views answer that selector first in the responder chain.
    @objc private func printPage() { session.activeWindow?.printPage() }
    @objc private func exportAsPDF() { session.activeWindow?.exportPageAsPDF() }
    @objc private func sharePage() { session.activeWindow?.shareSelectedPage() }
    @objc private func toggleSidebar() { frontSidebarTarget().toggleSidebar() }
    @objc private func toggleDeveloperTools() { session.activeWindow?.toggleDeveloperTools() }
    /// Every window's tools follow the side.
    @objc private func chooseDevToolsSide(_ sender: NSMenuItem) {
        guard let side = (sender.representedObject as? String).flatMap(DevToolsSide.init(rawValue:)) else { return }
        DevToolsDockSettings.shared.side = side
    }
    @objc private func toggleDownloads() { frontSidebarTarget().toggleLibrary() }
    @MainActor @objc private func togglePageReader() { session.activeWindow?.togglePageReader() }
    @objc private func reload() { session.activeWindow?.reload() }
    @objc private func zoomIn() { session.activeWindow?.zoomIn() }
    @objc private func zoomOut() { session.activeWindow?.zoomOut() }
    @objc private func resetZoom() { session.activeWindow?.resetZoom() }
    @objc private func showFindBar() { session.activeWindow?.showFindBar() }
    @objc private func findNext() { session.activeWindow?.findNext() }
    @objc private func findPrevious() { session.activeWindow?.findPrevious() }
    @objc private func goBack() { session.activeWindow?.goBack() }
    @objc private func goForward() { session.activeWindow?.goForward() }
    @objc private func goHome() { session.activeWindow?.goHome() }
    @objc private func clearHistory() { HistoryStore.shared.clear() }
    @objc private func clearSiteData() { session.activeWindow?.confirmClearSiteData() }

    /// Pages chosen in the History window open as new tabs in the sidebar target, which comes to the front.
    @objc private func showHistory() {
        let history = HistoryWindowController.shared
        history.openURL = { [weak self] url in
            guard let session = self?.session else { return }
            session.openTab(url: url)
            session.sidebarTarget().nsWindow?.makeKeyAndOrderFront(nil)
        }
        history.show()
    }

    /// Lists the active window's selected tab's previous ten pages, most recent first, between Forward and Show All History.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === historyMenu else { return }
        for item in menu.items where item.tag == Self.recentPageTag { menu.removeItem(item) }
        let activeWindow = session?.activeWindow
        let pages = activeWindow?.recentBackItems(limit: 10) ?? []
        guard !pages.isEmpty, let tabID = activeWindow?.selectedTabID, let separator = menu.items.firstIndex(where: \.isSeparatorItem) else { return }
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
        session.activeWindow?.go(to: page.item, inTab: page.tabID)
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
    @objc private func togglePinned() { frontSidebarTarget().selectedTab.map(session.togglePinned) }
    @objc private func addFavorite() { session.activeWindow?.selectedTab.map(session.addFavorite) }
    @objc private func openInSplitView() { frontSidebarTarget().openSelectedTabInSplitView() }
    @objc private func newSpace() { frontSidebarTarget().addSpace() }
    @objc private func nextSpace() { frontSidebarTarget().switchToAdjacentSpace(forward: true) }
    @objc private func previousSpace() { frontSidebarTarget().switchToAdjacentSpace(forward: false) }
    // The Persona items ask with a sheet on the sidebar target and act on its Persona.
    @objc private func newPersona() { frontSidebarTarget().promptForNewPersona() }
    @objc private func renamePersona() {
        let target = frontSidebarTarget()
        target.promptToRenamePersona(target.personaID)
    }
    @objc private func deletePersona() {
        let target = frontSidebarTarget()
        target.confirmDeletePersona(target.personaID)
    }
    @objc private func moveToMainWindow() {
        guard let window = session.activeWindow, window.kind == .small else { return }
        session.moveToMainWindow(window)
    }

    // MARK: Appearance

    // Not named `setAppearance(_:)`: `NSApplication` answers that selector first in the responder chain and would take the menu item as its appearance.
    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        let setting = (sender.representedObject as? String).flatMap(AppearanceSetting.init(rawValue:)) ?? .system
        UserDefaults.standard.set(setting.rawValue, forKey: AppearanceSetting.defaultsKey)
        NSApp.appearance = setting.appearance
    }

    /// The Appearance checkmark reflects the stored value, which the Settings window can also change. Only an app bundle can become the default browser. Developer tools need an engine that offers them. Zooming needs a selected tab that no internal page or preview covers. Printing needs a page in front and no sheet on its window. Sharing needs a page. Home needs a home page for the current space and no internal page or preview over the tab. Capturing needs a selected tab that no internal page or preview covers. Open in Split View needs a selected tab that no internal page covers and that can open as a pane. Page commands check the active window and sidebar commands the last main window.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let activeWindow = session?.activeWindow
        if item.action == #selector(zoomIn) || item.action == #selector(zoomOut) || item.action == #selector(resetZoom) {
            return activeWindow?.canZoom == true
        }
        if item.action == #selector(captureViewport) || item.action == #selector(captureFullPage) || item.action == #selector(captureRegion) {
            return activeWindow?.canCapture == true
        }
        if item.action == #selector(printPage) || item.action == #selector(exportAsPDF) {
            return activeWindow?.canPrint == true
        }
        if item.action == #selector(chooseAppearance(_:)) {
            item.state = (item.representedObject as? String) == AppearanceSetting.current.rawValue ? .on : .off
        }
        if item.action == #selector(setAsDefaultBrowser) {
            return DefaultBrowser.canBecomeDefault && !DefaultBrowser.isDefault
        }
        if item.action == #selector(chooseDevToolsSide(_:)) {
            item.state = (item.representedObject as? String) == DevToolsDockSettings.shared.side.rawValue ? .on : .off
            return activeWindow?.canChooseDevToolsSide == true
        }
        if item.action == #selector(toggleDeveloperTools) {
            item.title = activeWindow?.isShowingDeveloperTools == true ? "Hide Developer Tools" : "Show Developer Tools"
            return activeWindow?.canShowDeveloperTools == true
        }
        if item.action == #selector(sharePage) {
            return activeWindow?.canShareSelectedPage == true
        }
        if item.action == #selector(goHome) {
            return activeWindow?.canGoHome == true
        }
        // These commands work on the selected tab's place in its space's list. A favorite's tab is in no list.
        if item.action == #selector(togglePinned) || item.action == #selector(moveTabUp) || item.action == #selector(moveTabDown)
            || item.action == #selector(nextTab) || item.action == #selector(previousTab) {
            return session?.lastMainWindow?.selectedTab?.spaceID != nil
        }
        // A small window has no other tabs.
        if item.action == #selector(closeOtherTabs) {
            return activeWindow?.kind == .main && activeWindow?.selectedTab?.spaceID != nil
        }
        if item.action == #selector(moveToMainWindow) {
            return activeWindow?.kind == .small
        }
        // The Persona items ask with a sheet on the sidebar target, so they wait while that window shows another sheet; without a main window, New and Rename open one. The default Persona stays.
        if item.action == #selector(newPersona) || item.action == #selector(renamePersona) {
            return session?.lastMainWindow?.canShowPersonaSheet ?? true
        }
        if item.action == #selector(deletePersona) {
            guard let session, let window = session.lastMainWindow else { return false }
            return window.canShowPersonaSheet && session.canDeletePersona(window.personaID)
        }
        if item.action == #selector(openInSplitView) {
            return session?.lastMainWindow?.canOpenSelectedTabInSplitView == true
        }
        // Clearing site data needs a web page in front and no sheet on its window.
        if item.action == #selector(clearSiteData) {
            return activeWindow?.canClearSiteData == true
        }
        // The page reader stays out of the menu until a provider can serve it, and opens only over a tab no internal page covers.
        if item.action == #selector(togglePageReader) {
            item.isHidden = !PageAssistant.isReaderAvailable
            item.title = activeWindow?.isPageReaderVisible == true ? "Hide Page Reader" : "Show Page Reader"
            return activeWindow?.canTogglePageReader == true
        }
        // Import waits while another import runs or the last main window shows a sheet, and opens a main window when none is open. It touches no tab, so an internal page does not disable it.
        if item.action == #selector(importBookmarksAndHistory) {
            guard let window = session?.lastMainWindow?.nsWindow else { return true }
            return importController.canImport(in: window)
        }
        return true
    }

    @objc private func showSettings() { PreferencesWindowController.shared.show() }

    // MARK: Capture

    @objc private func captureViewport() { session.activeWindow?.captureViewport() }
    @objc private func captureFullPage() { session.activeWindow?.captureFullPage() }
    @objc private func captureRegion() { session.activeWindow?.beginRegionCapture() }

    // MARK: Page fullscreen

    /// A page that fills its window in fullscreen leaves it on Escape in that window, as in full browsers. WebKit shows fullscreen in its own window and handles Escape itself. While the region capture overlay is up, Escape cancels the capture first.
    private func installFullscreenEscape() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  let windowModel = self?.session?.window(for: event.window), windowModel.fullscreenTabID != nil, windowModel.regionCaptureTabID == nil else { return event }
            windowModel.exitPageFullscreen()
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
                self?.reopenClosedTab()
                return nil
            }
            // Closing and reopening tabs keep the count. Any other key, whether typing or a shortcut such as ⌘V, makes ⌘Z undo where the user works.
            let closesOrReopens = (Self.isKey(event, "w", keyCode: 13) && (modifiers == .command || modifiers == [.command, .option]))
                || (Self.isKey(event, "t", keyCode: 17) && modifiers == [.command, .shift])
            if !isUndo, !closesOrReopens { session.forgetUndoableCloses() }
            return event
        }
        // A click in the page of a window's selected tab can start an edit there, such as choosing a spelling suggestion, so ⌘Z then undoes in the page.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let session = self?.session, let view = session.window(for: event.window)?.selectedTab?.webContents.view, view.window === event.window,
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

    // MARK: Tab switcher

    /// ⌃Tab in a main window opens that window's switcher on the tab selected before the current one. While Control stays down, Tab moves to the next less recent tab and ⇧Tab moves back; releasing Control selects the highlighted tab, and Escape closes the switcher without switching. Another key also closes it and goes on as usual. The monitors run before a focused page sees the keys.
    private func installTabSwitcher() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let session = self?.session else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift], let windowModel = session.window(for: event.window), windowModel.kind == .main {
                let backward = modifiers.contains(.shift)
                if windowModel.isTabSwitcherVisible {
                    windowModel.moveTabSwitcherHighlight(backward: backward)
                } else {
                    windowModel.showTabSwitcher(backward: backward)
                }
                return nil
            }
            let switching = session.windows.filter(\.isTabSwitcherVisible)
            guard !switching.isEmpty else { return event }
            switching.forEach { $0.cancelTabSwitcher() }
            return event.keyCode == 53 ? nil : event
        }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if let session = self?.session, !event.modifierFlags.contains(.control) {
                session.windows.filter(\.isTabSwitcherVisible).forEach { $0.commitTabSwitcher() }
            }
            return event
        }
        // A click also closes it. Monitors see no keys while a menu tracks, so a Control-click's context menu could otherwise hide Control's release.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.session?.windows.forEach { $0.cancelTabSwitcher() }
            return event
        }
        // The app receives no key events while inactive, so it cannot see Control's release in another app.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.session?.windows.forEach { $0.cancelTabSwitcher() }
        }
    }

    // MARK: Shortcuts

    /// Applies the shortcuts chosen in Settings ▸ Shortcuts to the menu bar and registers the global shortcut.
    @MainActor private func installShortcuts() {
        let shortcuts = ShortcutSettings.shared
        shortcuts.onGlobalShortcut = { [weak self] in self?.openNewTabFromAnyApp() }
        if let menuBar = NSApp.mainMenu { shortcuts.manage(menuBar) }
    }

    /// The Plugins menu changes with the active window's Persona and its plugins, so the shortcut settings list its items each time they change.
    @MainActor private func installPluginsMenu() {
        guard let menuBar = NSApp.mainMenu, let windowMenu else { return }
        let pluginsMenu = PluginsMenu(session: session)
        pluginsMenu.install(in: menuBar, before: windowMenu)
        self.pluginsMenu = pluginsMenu
    }

    /// The global shortcut brings the sidebar target forward, out of the Dock if it is minimized, and opens the new tab palette in it.
    private func openNewTabFromAnyApp() {
        guard let session else { return }
        NSApp.activate(ignoringOtherApps: true)
        let target = session.sidebarTarget()
        if let window = target.nsWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        target.showCommandPalette(.newTab)
    }

    // MARK: Tab close log

    private lazy var closeLogWindow = TabCloseLogWindowController(log: session.closeLog)

    @objc private func showTabCloseLog() { closeLogWindow.show() }

    // MARK: Import

    private lazy var importController = ImportController(session: session)

    @objc private func importBookmarksAndHistory() {
        guard let window = frontSidebarTarget().nsWindow else { return }
        importController.chooseFiles(in: window)
    }

    // MARK: Default browser

    @objc private func setAsDefaultBrowser() { DefaultBrowser.makeDefault() }

    /// Prompts once per user on the front main window after it opens. Skips the prompt outside an app bundle or when the app is already the default browser.
    private func promptForDefaultBrowserIfNeeded() {
        let defaults = UserDefaults.standard
        guard let window = session.lastMainWindow?.nsWindow, DefaultBrowser.canBecomeDefault,
              !defaults.bool(forKey: Self.askedDefaultBrowserKey), !DefaultBrowser.isDefault else { return }
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
