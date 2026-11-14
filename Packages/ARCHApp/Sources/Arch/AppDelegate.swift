// Registers the engines, creates the browser session, which opens the browser windows, and connects the menu bar to it.
import AppKit
import ARCHEngine
import ARCHEngineChromium
import ARCHEngineWebKit
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
    /// Lists the favorites and the spaces' pinned folders and tabs each time it opens (bookmark rule 7).
    private var bookmarksMenu: NSMenu?
    /// Edit ▸ Undo, and File ▸ Close Tab, Close Other Tabs, and Reopen Last Closed Tab, whose shortcuts, which Settings ▸ Shortcuts can change, the undo close monitor reads.
    private var undoItem: NSMenuItem?
    private var closingItems: [NSMenuItem] = []
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
        // The app's Application Support folder, which the session keeps its files and stores in (`BrowserSession.userDataDirectory`). Only `AIService.shared`, which views of several modules read, names it as well.
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch")
        // Data kept under the previous bundle identifier, then plugin data kept under the previous plugin identifiers, moves before the engines start and the preferences are read.
        BundleIdentifierMigration.runAtLaunch()
        PluginIdentifierMigration.runAtLaunch(in: supportDirectory)
        let registry = EngineRegistry.shared
        registry.register(WebKitEngine())
        let chromium = ChromiumEngine(frameworkPath: Self.cefFrameworkPath, helperPath: Self.cefHelperPath)
        if let chromium {
            registry.register(chromium)
        }
        // The session starts the default engine, or another one when the default fails to start, and starts the rest as tabs need them. Every Persona offers the built-in plugins that ship with the app. The Web Store asks for the Chromium version of Arch's engine, which its CEF version names, read without starting CEF. Web extensions reach native apps whose vendors install host manifests only for other browsers through links to those manifests, and the proof gate also counts the system folder that Chromium reads itself.
        let session: BrowserSession
        do {
            session = try BrowserSession(registry: registry, userDataDirectory: supportDirectory, builtInPlugins: [PageAddressPlugin.self],
                                         cefVersion: chromium?.extensionRuntimeVersion, nativeMessagingHostFolders: BrowserSource.nativeMessagingHostFolders,
                                         chromiumNativeMessagingHosts: chromium?.systemNativeMessagingHosts)
        } catch {
            fatalError("The browser session could not start: \(error)")
        }
        self.session = session
        session.showSettings = { PreferencesWindowController.shared.show() }
        session.installEngineVersion = { PreferencesWindowController.shared.showPlugin($2, in: $0, space: $1, installingVersionFor: $3) }
        session.installFromWebStore = { PreferencesWindowController.shared.showWebStoreInstall(of: $2, in: $0, space: $1) }
        session.pageAssistant.showAISettings = { PreferencesWindowController.shared.showAISection() }
        PreferencesWindowController.openTerminal = { TerminalWindowController.shared.show() }
        session.openTerminal = { TerminalWindowController.shared.show() }
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

    /// Opens links from other apps and addresses from `open location` scripts. Links received before launch finishes wait for the session and open as tabs of the main window. Afterwards, while Settings ▸ General allows small windows, a link that arrives while Arch is in the background opens in a small window of its own, which comes forward alone; otherwise links open in new tabs of the sidebar target. Only http and https addresses open (`BrowserSession.webAddress(forOpened:)`); a script's text without a scheme is read as the address field reads it, and anything else is dropped.
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.compactMap(BrowserSession.webAddress(forOpened:))
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

    /// Quitting stops the downloads in progress or paused, which the next launch does not list, and a program running in the built-in terminal, so the user confirms each first, as closing the terminal's window asks. `ArchApplication` asks before it answers the tabs' prompts, so that Cancel leaves their cards showing. Closing the last main window quits through the same path.
    func confirmsQuit() -> Bool {
        confirmsQuitStoppingDownloads() && TerminalWindowController.allowsQuit()
    }

    private func confirmsQuitStoppingDownloads() -> Bool {
        guard let count = session?.unfinishedDownloadCount, count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Arch?"
        alert.informativeText = count == 1 ? "A download has not finished. It stops when Arch quits." : "\(count) downloads have not finished. They stop when Arch quits."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

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

    /// Pages an import has not written yet, visits still on the history store's queue, and the Personas' cookie records go in before the app quits.
    func applicationWillTerminate(_ notification: Notification) {
        session?.saveAtQuit()
        session?.history.finishWrites()
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
        let closeTabItem = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        let closeWindowItem = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        let closeOthersItem = fileMenu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs), keyEquivalent: "w")
        closeOthersItem.keyEquivalentModifierMask = [.command, .option]
        let reopenItem = fileMenu.addItem(withTitle: "Reopen Last Closed Tab", action: #selector(reopenClosedTab), keyEquivalent: "T")
        reopenItem.keyEquivalentModifierMask = [.command, .shift]
        closingItems = [closeTabItem, closeOthersItem, reopenItem]
        fileMenu.addItem(withTitle: "Open Location", action: #selector(openLocation), keyEquivalent: "l")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Share\u{2026}", action: #selector(sharePage), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Import from Browser\u{2026}", action: #selector(importFromBrowser), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Import Bookmarks and History\u{2026}", action: #selector(importBookmarksAndHistory), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Export as PDF\u{2026}", action: #selector(exportAsPDF), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print\u{2026}", action: #selector(printPage), keyEquivalent: "p")
        mainMenu.addItem(submenu(fileMenu, title: "File"))

        let editMenu = NSMenu(title: "Edit")
        undoItem = editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
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
        // The saved page items have no default shortcuts; Settings ▸ Shortcuts can give them one.
        tabMenu.addItem(withTitle: "Go Back to Saved Page", action: #selector(goBackToSavedPage), keyEquivalent: "")
        tabMenu.addItem(withTitle: "Use Current Page as Saved Page", action: #selector(useCurrentPageAsSavedPage), keyEquivalent: "")
        tabMenu.addItem(withTitle: "Edit Saved Address\u{2026}", action: #selector(editSavedAddress), keyEquivalent: "")
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

        // Filled each time it opens (`menuWillOpen(_:)`). Until then it holds only No Bookmarks, so Settings ▸ Shortcuts, which lists the menu bar at launch, lists none of its items.
        let bookmarksMenu = NSMenu(title: "Bookmarks")
        bookmarksMenu.addItem(withTitle: "No Bookmarks", action: nil, keyEquivalent: "")
        bookmarksMenu.delegate = self
        self.bookmarksMenu = bookmarksMenu
        mainMenu.addItem(submenu(bookmarksMenu, title: "Bookmarks"))

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        let homeItem = historyMenu.addItem(withTitle: "Home", action: #selector(goHome), keyEquivalent: "H")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        historyMenu.addItem(.separator())
        historyMenu.addItem(withTitle: "Show All History", action: #selector(showHistory), keyEquivalent: "y")
        historyMenu.addItem(withTitle: "Clear History\u{2026}", action: #selector(clearHistory), keyEquivalent: "")
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
    /// ⌘W closes the window in front when it is another of the app's windows, such as History, Settings, or the developer tools, not a tab behind it. While such a window shows a sheet, the item is disabled (`showsSheetOfOtherWindow`). A browser window's sheets and popovers leave ⌘W to its tab.
    @objc private func closeTab() {
        if let key = NSApp.keyWindow, session.window(for: key) == nil, key.sheetParent == nil, key.styleMask.contains(.closable) { return key.performClose(nil) }
        session.activeWindow?.closeSelectedTab()
    }

    /// Whether the key window is a sheet, or a sheet on a sheet, of a window that is not a browser window, such as Settings' provider editor or History's Clear History…. The sheet ends through its own buttons, so ⌘W closes neither it, its window, nor a tab behind them.
    private var showsSheetOfOtherWindow: Bool {
        guard var window = NSApp.keyWindow, window.sheetParent != nil else { return false }
        while let parent = window.sheetParent { window = parent }
        return session?.window(for: window) == nil
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
    /// Open Location edits the address where the window shows it, so the palette comes out of the address pill as a click on it does.
    @objc private func openLocation() { session.activeWindow?.focusCommandBar(from: .addressPill) }
    // Not named `print(_:)`: windows and views answer that selector first in the responder chain.
    @objc private func printPage() { session.activeWindow?.printPage() }
    @objc private func exportAsPDF() { session.activeWindow?.exportPageAsPDF() }
    @objc private func sharePage() { session.activeWindow?.shareSelectedPage() }
    @objc private func toggleSidebar() { frontSidebarTarget().toggleSidebar() }
    /// While the window of floating tools is key, ⌥⌘I closes those tools, whichever tab the active window shows.
    @objc private func toggleDeveloperTools() {
        if let devTools = DevToolsDock.floatingDevTools(in: NSApp.keyWindow) { return devTools.close() }
        session.activeWindow?.toggleDeveloperTools()
    }
    /// Every window's tools follow the side. So do floating tools whose window is key, also while no window shows their tab: docked, they show once a window selects it.
    @objc private func chooseDevToolsSide(_ sender: NSMenuItem) {
        guard let side = (sender.representedObject as? String).flatMap(DevToolsSide.init(rawValue:)) else { return }
        let floatingDevTools = DevToolsDock.floatingDevTools(in: NSApp.keyWindow)
        DevToolsDockSettings.shared.side = side
        if side != .floating, let floatingDevTools { DevToolsDock.dock(floatingDevTools) }
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
    /// Asks for the range to clear in the History window's sheet, as its own Clear History… does.
    @objc private func clearHistory() { historyWindow.showClearHistory() }
    @objc private func clearSiteData() { session.activeWindow?.confirmClearSiteData() }

    @objc private func showHistory() { historyWindow.show() }

    /// The History window, made on first use. Its pages open as new tabs in the sidebar target, which comes to the front.
    private lazy var historyWindow: HistoryWindowController = {
        let history = HistoryWindowController(store: session.history)
        history.openURL = { [weak self] url in
            guard let session = self?.session else { return }
            session.openTab(url: url)
            session.sidebarTarget().nsWindow?.makeKeyAndOrderFront(nil)
        }
        return history
    }()

    /// Fills the Bookmarks menu for the sidebar target, and lists the active window's selected tab's previous ten pages, most recent first, between Forward and Show All History. Both are made when their menu opens rather than in `menuNeedsUpdate(_:)`, which AppKit also calls to search the menu for each key equivalent the user presses; their items have no key equivalents.
    func menuWillOpen(_ menu: NSMenu) {
        if menu === bookmarksMenu, let session { return fillBookmarks(menu, with: session.bookmarkMenuEntries) }
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

    /// Replaces the menu's items with the entries, each space and folder as a submenu. The Bookmarks menu is built like the History menu's pages, when it opens, and its items have no key equivalents.
    private func fillBookmarks(_ menu: NSMenu, with entries: [BookmarkMenu.Entry]) {
        menu.removeAllItems()
        for entry in entries {
            switch entry {
            case .heading(let title):
                menu.addItem(.sectionHeader(title: title))
            case .favorite(let id, let title, let url):
                menu.addItem(bookmarkItem(title: title, url: url, choice: .favorite(id)))
            case .tab(let id, let title, let url, let isUnread):
                let item = bookmarkItem(title: title, url: url, choice: .tab(id))
                // A live folder's unread item shows a dot where a checkmark would.
                if isUnread {
                    item.onStateImage = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Unread")?.withSymbolConfiguration(.init(pointSize: 6, weight: .regular))
                    item.state = .on
                }
                menu.addItem(item)
            case .submenu(let title, let entries, let unreadCount):
                let folderMenu = NSMenu(title: title)
                fillBookmarks(folderMenu, with: entries)
                let item = submenu(folderMenu, title: title)
                if unreadCount > 0 { item.badge = NSMenuItemBadge(count: unreadCount) }
                menu.addItem(item)
            case .divider:
                menu.addItem(.separator())
            case .noBookmarks:
                menu.addItem(withTitle: "No Bookmarks", action: nil, keyEquivalent: "")
            }
        }
    }

    private func bookmarkItem(title: String, url: URL?, choice: BookmarkMenu.Choice) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openBookmark(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = choice
        item.toolTip = url?.absoluteString
        return item
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? BookmarkMenu.Choice else { return }
        session.openBookmark(choice)
    }
    @objc private func togglePinned() { frontSidebarTarget().selectedTab.map(session.togglePinned) }
    @objc private func addFavorite() { session.activeWindow?.selectedTab.map(session.addFavorite) }
    @objc private func openInSplitView() { frontSidebarTarget().openSelectedTabInSplitView() }
    // The saved page items act on the sidebar target's selected tab, a pinned tab or a favorite's tab.
    @objc private func goBackToSavedPage() { frontSidebarTarget().goBackToSavedPage() }
    @objc private func useCurrentPageAsSavedPage() { frontSidebarTarget().useCurrentPageAsSavedPage() }
    @objc private func editSavedAddress() { frontSidebarTarget().promptToEditSavedAddress() }
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
        target.confirmDeletePersona(ofSpace: target.currentSpace)
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

    /// The Appearance checkmark reflects the stored value, which the Settings window can also change. Only an app bundle can become the default browser. Developer tools need an engine that offers them, or the key window of floating tools, which the Developer menu then acts on. Zooming needs a selected tab that no internal page or preview covers. Printing needs a page in front, no prompt waiting on its tab, and no sheet on its window. Sharing needs a page. Home needs a home page for the current space and no internal page or preview over the tab. Capturing needs a selected tab that no internal page or preview covers. Open in Split View needs a selected tab that no internal page covers and that can open as a pane. Page commands check the active window and sidebar commands the last main window.
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
            return DevToolsDock.floatingDevTools(in: NSApp.keyWindow) != nil || activeWindow?.canChooseDevToolsSide == true
        }
        if item.action == #selector(toggleDeveloperTools) {
            let actsOnFloatingTools = DevToolsDock.floatingDevTools(in: NSApp.keyWindow) != nil
            item.title = actsOnFloatingTools || activeWindow?.isShowingDeveloperTools == true ? "Hide Developer Tools" : "Show Developer Tools"
            return actsOnFloatingTools || activeWindow?.canShowDeveloperTools == true
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
        if item.action == #selector(closeTab) {
            return !showsSheetOfOtherWindow
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
        // Go Back needs a tab off its saved page with no internal page or preview over it, Use Current Page a page to save, and Edit Saved Address a pinned tab and no other sheet on its window.
        if item.action == #selector(goBackToSavedPage) {
            return session?.lastMainWindow?.canGoBackToSavedPage == true
        }
        if item.action == #selector(useCurrentPageAsSavedPage) {
            return session?.lastMainWindow?.canUseCurrentPageAsSavedPage == true
        }
        if item.action == #selector(editSavedAddress) {
            return session?.lastMainWindow?.canEditSavedAddress == true
        }
        // Clearing site data needs a web page in front, no prompt waiting on its tab, and no sheet on its window.
        if item.action == #selector(clearSiteData) {
            return activeWindow?.canClearSiteData == true
        }
        // The page reader stays out of the menu until a provider can serve it, and opens only over a tab no internal page covers.
        if item.action == #selector(togglePageReader) {
            item.isHidden = !PageAssistant.isReaderAvailable
            item.title = activeWindow?.isPageReaderVisible == true ? "Hide Page Reader" : "Show Page Reader"
            return activeWindow?.canTogglePageReader == true
        }
        // Both imports wait while another import runs or the last main window shows a sheet, and open a main window when none is open. They touch no tab, so an internal page does not disable them.
        if item.action == #selector(importBookmarksAndHistory) || item.action == #selector(importFromBrowser) {
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

    /// Edit ▸ Undo's shortcut, ⌘Z unless Settings ▸ Shortcuts changed it, reopens the tabs the user just closed, newest first, until the user presses a different key or clicks in the page. It runs before the focused page can handle the shortcut as its own undo. The monitor reads each item's shortcut when a key is pressed, so it follows changes in Settings ▸ Shortcuts.
    private func installUndoCloseShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let session = self.session, session.undoableCloseCount > 0 else { return event }
            let pressed = KeyShortcut(event: event)
            if pressed != nil, pressed == self.undoItem.flatMap(KeyShortcut.init(menuItem:)) {
                self.reopenClosedTab()
                CommandKeyState.shared.noteCommandUse()
                return nil
            }
            // Closing and reopening tabs keep the count. Any other key, whether typing or a shortcut such as ⌘V, makes the shortcut undo where the user works.
            let closesOrReopens = pressed != nil && self.closingItems.contains { KeyShortcut(menuItem: $0) == pressed }
            if !closesOrReopens { session.forgetUndoableCloses() }
            return event
        }
        // A click in the page of a window's selected tab can start an edit there, such as choosing a spelling suggestion, so ⌘Z then undoes in the page. A click in any page on the window's screen, also in a pane of its split view that the click is about to select, lets that page start one more download without asking.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let session = self?.session, let windowModel = session.window(for: event.window), let tab = windowModel.tabOnScreen(at: event) {
                if tab === windowModel.selectedTab { session.forgetUndoableCloses() }
                tab.userDidClickInPage()
            }
            return event
        }
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

    @objc private func importFromBrowser() {
        guard let window = frontSidebarTarget().nsWindow else { return }
        importController.importFromBrowser(in: window)
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
