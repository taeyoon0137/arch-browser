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
    /// Names Undo Close Tab in its Undo item while ⌘Z reopens closed tabs.
    private var editMenu: NSMenu?
    /// Edit ▸ Undo, and File ▸ Close Tab, Close Other Tabs, and Reopen Last Closed Tab, whose shortcuts, which Settings ▸ Shortcuts can change, the undo close monitor reads.
    private var undoItem: NSMenuItem?
    private var closingItems: [NSMenuItem] = []
    private static let recentPageTag = 9_100
    /// The longest title of a page in the History menu, which takes its width from its longest item.
    private static let recentPageTitleLength = 60
    /// The Window, Services, and Help menus, which become `NSApp.windowsMenu`, `servicesMenu`, and `helpMenu` once the shortcut settings have listed the menu bar.
    private var windowMenu: NSMenu?
    private var servicesMenu: NSMenu?
    private var helpMenu: NSMenu?
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
        // Set after the shortcut settings list the menu bar, so that the window list AppKit adds to the Window menu, the services it lists in the Services menu, and the search field it puts in the Help menu stay out of Settings ▸ Shortcuts.
        NSApp.windowsMenu = windowMenu
        NSApp.servicesMenu = servicesMenu
        NSApp.helpMenu = helpMenu
        // The sidebar's and the small window's buttons name their command's shortcut, which Settings ▸ Shortcuts can change, in their tooltips.
        session.menuShortcut = { name in
            NSApp.mainMenu.flatMap { Self.visibleItem(withAction: name, in: $0) }.flatMap(KeyShortcut.init(menuItem:))?.displayName
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

    /// The first item of `menu` or its submenus, in menu bar order, whose action has the name, leaving out hidden twins such as the second Zoom In.
    private static func visibleItem(withAction name: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items where !item.isHidden {
            if let action = item.action, NSStringFromSelector(action) == name { return item }
            if let submenu = item.submenu, let found = visibleItem(withAction: name, in: submenu) { return found }
        }
        return nil
    }

    /// Quitting stops the downloads in progress or paused, which the next launch does not list, and a program running in the built-in terminal, so the user confirms first in one alert that names both, with the terminal brought forward while a program runs there, as closing the terminal's window asks. `ArchApplication` asks before it answers the windows' sheets, so that Cancel leaves them showing. Closing the last main window quits through the same path.
    func confirmsQuit() -> Bool {
        let downloads = session?.unfinishedDownloadCount ?? 0
        let runsProgram = TerminalWindowController.hasRunningProgram
        guard downloads > 0 || runsProgram else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Arch?"
        alert.informativeText = Self.quitWarning(downloads: downloads, runsProgram: runsProgram)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if runsProgram { TerminalWindowController.bringForward() }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What stops when Arch quits.
    private static func quitWarning(downloads: Int, runsProgram: Bool) -> String {
        switch (downloads, runsProgram) {
        case (0, _): return "The program running in the terminal will stop."
        case (1, false): return "A download has not finished. It stops when Arch quits."
        case (_, false): return "\(downloads) downloads have not finished. They stop when Arch quits."
        case (1, true): return "A download has not finished, and a program is running in the terminal. Both stop when Arch quits."
        case (_, true): return "\(downloads) downloads have not finished, and a program is running in the terminal. They all stop when Arch quits."
        }
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
        // The application menu has the items every Mac app's has, in their order. NSApplication answers and validates About, Hide, Hide Others, and Show All itself.
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Arch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Set as Default Browser\u{2026}", action: #selector(setAsDefaultBrowser), keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        appMenu.addItem(submenu(servicesMenu, title: "Services"))
        self.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Arch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Arch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu(appMenu, title: "Arch"))

        // Open Location… asks for an address before it opens anything, so it sits with the New commands and ends with an ellipsis.
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Location\u{2026}", action: #selector(openLocation), keyEquivalent: "l")
        fileMenu.addItem(.separator())
        let closeTabItem = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        let closeWindowItem = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        let closeOthersItem = fileMenu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOtherTabs), keyEquivalent: "w")
        closeOthersItem.keyEquivalentModifierMask = [.command, .option]
        let reopenItem = fileMenu.addItem(withTitle: "Reopen Last Closed Tab", action: #selector(reopenClosedTab), keyEquivalent: "T")
        reopenItem.keyEquivalentModifierMask = [.command, .shift]
        closingItems = [closeTabItem, closeOthersItem, reopenItem]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Share\u{2026}", action: #selector(sharePage), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Import from Browser\u{2026}", action: #selector(importFromBrowser), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Import Bookmarks and History\u{2026}", action: #selector(importBookmarksAndHistory), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Export as PDF\u{2026}", action: #selector(exportAsPDF), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print\u{2026}", action: #selector(printPage), keyEquivalent: "p")
        mainMenu.addItem(submenu(fileMenu, title: "File"))

        // Undo becomes Undo Close Tab while ⌘Z reopens closed tabs (`menuNeedsUpdate(_:)`).
        let editMenu = NSMenu(title: "Edit")
        undoItem = editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste and Match Style", action: #selector(pasteAndMatchStyle(_:)), keyEquivalent: "V").keyEquivalentModifierMask = [.command, .option, .shift]
        // SwiftUI's delete commands, such as the History list's, answer Delete.
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find\u{2026}", action: #selector(showFindBar), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        let findPreviousItem = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "G")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.delegate = self
        self.editMenu = editMenu
        mainMenu.addItem(submenu(editMenu, title: "Edit"))

        // The panels' toggles name what they will do, as the sidebar's button does; Settings ▸ Shortcuts lists them by these launch titles. The library item keeps its `toggleDownloads` action, by which saved shortcuts know it.
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Show Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        let libraryItem = viewMenu.addItem(withTitle: "Show Library", action: #selector(toggleDownloads), keyEquivalent: "J")
        libraryItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: "Show Page Reader", action: #selector(togglePageReader), keyEquivalent: "")
        viewMenu.addItem(.separator())
        // Targeted, so that a focused web view, which answers `reload:` itself, cannot take it past the window's rules.
        viewMenu.addItem(withTitle: "Reload Page", action: #selector(reload), keyEquivalent: "r").target = self
        // Without a shortcut of its own: ⌘. stays the terminal's and the sheets' cancel key. Settings ▸ Shortcuts can give it one.
        viewMenu.addItem(withTitle: "Stop Loading", action: #selector(stopLoading), keyEquivalent: "").target = self
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
        // Unpin Tab while the selected tab is pinned (`validateMenuItem(_:)`), as in the tab row's context menu.
        tabMenu.addItem(withTitle: "Pin Tab", action: #selector(togglePinned), keyEquivalent: "d")
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

        // Back and Forward are targeted as Reload Page is: a focused web view answers `goBack:` and `goForward:` itself.
        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[").target = self
        historyMenu.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]").target = self
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

        // AppKit puts its menu search field in the Help menu. Arch has no help of its own to add.
        let helpMenu = NSMenu(title: "Help")
        self.helpMenu = helpMenu
        mainMenu.addItem(submenu(helpMenu, title: "Help"))
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
    @objc private func openLocation() { session.activeWindow?.focusCommandBar() }
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
    @objc private func stopLoading() { session.activeWindow?.stopLoading() }
    @objc private func zoomIn() { session.activeWindow?.zoomIn() }
    @objc private func zoomOut() { session.activeWindow?.zoomOut() }
    @objc private func resetZoom() { session.activeWindow?.resetZoom() }
    /// Find… in the History window, which the browser window behind it does not answer, goes to the window's search field.
    @objc private func showFindBar() {
        if let history = keyHistoryWindow { return history.focusSearch() }
        session.activeWindow?.showFindBar()
    }

    /// The History window while it, or its Clear History sheet, is key.
    private var keyHistoryWindow: HistoryWindowController? {
        var window = NSApp.keyWindow
        while let parent = window?.sheetParent { window = parent }
        return window?.windowController as? HistoryWindowController
    }
    @objc private func findNext() { session.activeWindow?.findNext() }
    @objc private func findPrevious() { session.activeWindow?.findPrevious() }
    /// Chromium's view answers Paste and Match Style itself. A WebKit page and AppKit's text views name the command `pasteAsPlainText:`, so it reaches them under that name.
    @objc private func pasteAndMatchStyle(_ sender: Any?) {
        NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: sender)
    }
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

    /// Lists the active window's selected tab's previous ten pages, most recent first, under a This Tab header between Forward and Show All History. Each title ends with an ellipsis after 60 characters, as tab rows and History rows cut titles at their end, and the page's tooltip gives the full title and its address. The list is made when the menu opens rather than in `menuNeedsUpdate(_:)`, which AppKit also calls to search the menu for each key equivalent the user presses; the pages have no key equivalents.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === historyMenu else { return }
        for item in menu.items where item.tag == Self.recentPageTag { menu.removeItem(item) }
        let activeWindow = session?.activeWindow
        let pages = activeWindow?.recentBackItems(limit: 10) ?? []
        guard !pages.isEmpty, let tabID = activeWindow?.selectedTabID, let separator = menu.items.firstIndex(where: \.isSeparatorItem) else { return }
        var index = separator + 1
        let header = NSMenuItem.sectionHeader(title: "This Tab")
        header.tag = Self.recentPageTag
        menu.insertItem(header, at: index)
        index += 1
        for page in pages {
            let fullTitle = page.title.isEmpty ? page.url.host ?? page.url.absoluteString : page.title
            let title = fullTitle.count > Self.recentPageTitleLength ? String(fullTitle.prefix(Self.recentPageTitleLength - 1)) + "\u{2026}" : fullTitle
            let item = NSMenuItem(title: title, action: #selector(goToRecentPage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RecentPage(tabID: tabID, item: page)
            item.toolTip = [fullTitle, page.url.absoluteString].joined(separator: "\n")
            item.tag = Self.recentPageTag
            menu.insertItem(item, at: index)
            index += 1
        }
        let end = NSMenuItem.separator()
        end.tag = Self.recentPageTag
        menu.insertItem(end, at: index)
    }

    /// While ⌘Z reopens closed tabs (`installUndoCloseShortcut()`), Edit ▸ Undo is Undo Close Tab, so that choosing it does what pressing its shortcut does; otherwise it undoes in the first responder. AppKit calls this before the Edit menu shows and before it searches the menu for a key equivalent. The key monitor compares only the item's shortcut, which this leaves alone.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === editMenu, let undoItem else { return }
        if (session?.undoableCloseCount ?? 0) > 0 {
            undoItem.title = "Undo Close Tab"
            undoItem.target = self
            undoItem.action = #selector(reopenClosedTab)
        } else {
            undoItem.title = "Undo"
            undoItem.target = nil
            undoItem.action = Selector(("undo:"))
        }
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

    /// The Appearance checkmark reflects the stored value, which the Settings window can also change. Only an app bundle can become the default browser. Developer tools need an engine that offers them, or the key window of floating tools, which the Developer menu then acts on. Zooming needs a selected tab that no internal page or preview covers. Printing needs a page in front and no sheet on its window. Sharing needs a page. Home needs a home page for the current space and no internal page or preview over the tab. Capturing needs a selected tab that no internal page or preview covers. Open in Split View needs a selected tab that no internal page covers and that can open as a pane. Toggles name what they will do. Page commands check the active window and sidebar commands the last main window.
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
        // As the sidebar's buttons, Back, Forward, Reload Page, and Stop Loading need a page to act on, the preview's while the panel shows.
        if item.action == #selector(addFavorite) { return activeWindow?.selectedTab.map(session.canAddFavorite) == true }
        if item.action == #selector(goBack) { return activeWindow?.canGoBack == true }
        if item.action == #selector(goForward) { return activeWindow?.canGoForward == true }
        if item.action == #selector(reload) { return activeWindow?.canReload == true }
        if item.action == #selector(stopLoading) { return activeWindow?.isLoadingPage == true }
        // These commands work on the selected tab's place in its space's list. A favorite's tab is in no list. Pin Tab names what it will do, as the tab row's context menu does.
        if item.action == #selector(togglePinned) || item.action == #selector(moveTabUp) || item.action == #selector(moveTabDown)
            || item.action == #selector(nextTab) || item.action == #selector(previousTab) {
            if item.action == #selector(togglePinned) { item.title = session?.lastMainWindow?.selectedTab?.isPinned == true ? "Unpin Tab" : "Pin Tab" }
            return session?.lastMainWindow?.selectedTab?.spaceID != nil
        }
        // The sidebar and library toggles name what they will do, for the sidebar target, which they act on. With the sidebar hidden, the library always opens.
        if item.action == #selector(toggleSidebar) {
            item.title = session?.lastMainWindow?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar"
        }
        if item.action == #selector(toggleDownloads) {
            let window = session?.lastMainWindow
            item.title = window?.isSidebarVisible == true && window?.isLibraryVisible == true ? "Hide Library" : "Show Library"
        }
        // The History window's search field has no next or previous match, and the find bar of the window behind it does not show.
        if item.action == #selector(findNext) || item.action == #selector(findPrevious) {
            return keyHistoryWindow == nil
        }
        // Chromium's view answers the item before it reaches the app, so here it needs a web view or text view that answers `pasteAsPlainText:`.
        if item.action == #selector(pasteAndMatchStyle(_:)) {
            return NSApp.target(forAction: #selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: item) != nil
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
                return nil
            }
            // Closing and reopening tabs keep the count. Any other key, whether typing or a shortcut such as ⌘V, makes the shortcut undo where the user works.
            let closesOrReopens = pressed != nil && self.closingItems.contains { KeyShortcut(menuItem: $0) == pressed }
            if !closesOrReopens { session.forgetUndoableCloses() }
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
