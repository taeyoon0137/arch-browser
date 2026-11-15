// Each tab wraps an engine web contents instance. It publishes the state shown in the sidebar and command bar. A tab in an agent folder is an agent's (docs/agents.md, In the browser ▸ Agent folders): it records no visits, and it applies the rules of agent tabs to its page's requests and reports what they did.
import Agent
import AppKit
import ARCHEngine
import Combine
import Events
import Foundation
import LiveFolders

@MainActor public final class Tab: ObservableObject, Identifiable {
    /// Kept across launches: `session.json` saves it with the tab, and the tab restores and reopens under it.
    public let id: UUID
    /// Replaced when the tab switches engines, and when a tab restored without its page gets it (`isLoaded`).
    @Published public private(set) var webContents: any EngineWebContents
    /// The space whose list shows the tab, or `nil` for a favorite's tab, which its favorite shows in every space of its Persona. A small window's tab joins this space's list when it moves to a main window. The session moves a tab only to a space of its Persona.
    @Published public internal(set) var spaceID: UUID?
    /// Set while a small window shows the tab, which keeps it out of its space's list until Move to Main Window clears it.
    @Published public internal(set) var isInSmallWindow = false
    /// The Persona of the space or favorite the tab opened in. It never changes, because the tab's pages keep one Persona's engine storage.
    public let personaID: UUID
    /// The current main document, including reloads at the same address. Never stored or sent to a model.
    @Published private(set) var documentID = UUID() {
        didSet {
            if agentOwnerID == nil { agentMonitor?.userDocumentDidEnd(in: id, document: oldValue) }
        }
    }
    /// Pinning saves the page the tab shows as its saved page, or the first address its page reports when it shows none yet, and unpinning forgets it (bookmark rule 2). Pin Tab, Unpin Tab, and drops among the pinned or open tabs or into a folder of either list all set it, so each follows the rule; a tab made pinned, as one that restores or reopens, takes its saved page from the caller.
    @Published public var isPinned: Bool {
        didSet {
            guard isPinned != oldValue else { return }
            savedPage = isPinned ? currentPage : nil
            // Pinning or unpinning is the user's own act on the tab, so the archive and unload timers count from it; otherwise a pin left alone for days, once unpinned, would be archived at the next check.
            lastActivatedAt = Date()
            if !isPinned { pendingSyncEngine = nil }
        }
    }
    /// A synced engine choice waits while a window shows this page. Only a pinned tab syncs, so unpinning drops it.
    var pendingSyncEngine: EngineKind?
    /// A newer site-settings choice cancels an engine switch still copying cookies.
    var requestedEngineSwitch: EngineKind?
    /// The page a pinned tab returns to (bookmark rule 2): set as the tab becomes pinned, from its record when it restores or reopens, and by Use Current Page as Saved Page and Edit Saved Address…. Nil for every other tab. `docs/bookmarks.md`, Saved pages, describes the rest.
    @Published public internal(set) var savedPage: SavedPage?
    /// The folder that holds the tab, always one in the tab's space and pinned or open list. The session sets it and clears it when the tab leaves that list.
    @Published public internal(set) var folderID: UUID?
    /// The ID of the live folder item whose tab this is, in the live folder `folderID` (live folder rule 4), or nil for every other tab. The session sets it as it adds the item's tab and clears it when the tab leaves the folder, which makes it an ordinary tab.
    @Published var liveItemID: String?
    /// The item as its folder last listed it, for the row's state symbol and tooltip, or nil before the folder's stored items name it and once the source no longer lists it. The session sets it; `session.json` keeps only `liveItemID`.
    @Published var liveItem: LiveItem?
    /// The window that selects the tab updates this, and so does a window that stops showing it. Archiving closes unpinned tabs whose dates are too old, and automatic unloading unloads tabs that no window shows (`TabUnloading.tabsToUnload`).
    var lastActivatedAt = Date()
    @Published public private(set) var title: String
    /// The name the user gave the tab, shown in place of the page's title. A window's rename sets it, and the session restores it.
    @Published public internal(set) var customTitle: String?
    /// The name a hook gave the tab's document, shown while the user has not named the tab, or a mark that the user turned it down. Another address clears it once the tab commits it (`committedURL`), even one a single-page site sets within its document, since the name may no longer fit; another fragment does not. The session restores it.
    @Published var suggestedTitle: SuggestedTitle?
    @Published public private(set) var url: URL?
    /// The address of the document the tab shows, which its events carry and a hook's name goes by. WebKit reports a navigation's address before it commits and the earlier address again once the navigation fails, stops, or becomes a download, so the tab takes a new document's address when the engine commits it, and `url` at once when it changes while the page does not load, as within the document, and otherwise once the load or its document's load ends.
    @Published private(set) var committedURL: URL?
    @Published public private(set) var isLoading: Bool
    @Published public private(set) var canGoBack: Bool
    @Published public private(set) var canGoForward: Bool
    @Published public private(set) var favicon: NSImage?
    /// Whether the page plays sound, for a speaker badge on its row.
    @Published public private(set) var isAudible = false
    /// Whether the user typed into the page since its main frame's document loaded, as `TabUnloading.inputScript` reports, which keeps the tab loaded (bookmark rule 5). A main document's commit clears it, and another web contents starts without.
    private(set) var hasTypedInput = false
    /// Set by the session while an automatic unload asks the page to leave, until the page answers, the user asks it to leave, or another web contents takes its place: a Chromium page's leave-page question then gets Stay without a card, which keeps the page (bookmark rule 5).
    var answersBeforeUnloadWithStay = false
    /// Set for a tab that a page opened behind the selected tab, until the user selects it, for a dot on its row. The session sets it, and the window that selects the tab clears it. A live folder item's tab follows its item's read state instead (live folder rule 5).
    @Published public internal(set) var isUnread = false
    /// Set when the page's process quit and nothing has loaded since. The window covers such a page with a notice and a Reload button.
    @Published public private(set) var hasCrashed = false
    /// How many times this tab's page process quit, kept for the tab close log.
    public private(set) var crashCount = 0
    /// The session sets this callback so popups from this tab open as new tabs, with the address the page opened when the engine reports one.
    var openNewTab: ((any EngineWebContents, URL?, EngineNavigationDisposition) -> Void)?
    /// The session sets this callback to put in the tab's place a web contents that the engine made to load a page the tab's web contents cannot, as WebKit does for a web extension's pages.
    var takeReplacement: ((any EngineWebContents) -> Void)?
    /// The page that opened this tab, which the window returns to when the tab's page closes itself, as a sign-in popup does once it has reported back. The session sets it for a tab a page opens.
    weak var opener: (any EngineWebContents)?
    /// Closes the tab, as `TabCloseAction` decides, when its page closes itself with `window.close()` or the engine closes its crashed page. Set by the session.
    var didClose: (() -> Void)?
    /// Ends outstanding requests that belonged to the previous main document.
    var didCommitDocument: (() -> Void)?
    /// The session sets this callback to learn that a page finished loading.
    var didFinishLoad: (() -> Void)?
    /// Sends each time the main frame finishes loading a document, for the AI interface's hooks. Loads of frames inside the page and navigations within the document send nothing.
    let didLoadDocument = PassthroughSubject<Void, Never>()
    /// The session sets this callback to end the prompts of a page whose dialogs no longer apply.
    var didCancelDialogs: (() -> Void)?
    /// The session sets this callback to bring the tab forward, so that a prompt it needs can show.
    var requestSelection: (() -> Void)?
    /// The session sets this callback to show the tab and bring its window and the app forward, as the return button of the page's picture-in-picture window asks.
    var requestActivation: (() -> Void)?
    /// The session sets this callback to ask the user before a site gets a permission. Without it every request is denied.
    var requestPermission: ((EnginePermissionRequest, @escaping (Bool) -> Void) -> Void)?
    /// Denies an agent tab's request without asking, as the session's permission answers do.
    var denyPermission: ((EnginePermissionRequest, @escaping (Bool) -> Void) -> Void)?
    /// The session sets this callback to answer the page's file chooser: with Arch's open or save panel as a sheet that waits in the tab's prompts until a window shows the page, or in an agent tab with the agent monitor's P7 card first (`BrowserSession.chooseFiles(inAgentTab:owner:request:completion:)`). Without it the page gets no file.
    var chooseFiles: ((EngineFileChooserRequest, @escaping ([URL]?) -> Void) -> Void)?
    /// The session sets this callback to show a prompt as a card over the tab's pane, which waits until a window shows the tab (`TabPromptQueue`). Without it the prompt ends at once without the user, which gives the page the safe answer.
    var presentPrompt: ((PromptContent, @escaping (PromptResponse) -> Void) -> Void)?
    /// The session sets this callback to name the web extension of the tab's Persona whose page is at an address (`BrowserSession.extensionName(ofPageAt:in:)`), which the tab's prompts name in place of the identifier that the address has as its host (`PromptSiteIdentity`), `shownTitle` and `shownPageTitle` put in place of a title that only repeats such a page's address, and Now Playing names as the page's site. Without it they show the identifier, or the address that Chromium reports as the title. The session has a tab on such a page announce a change when its extension's name changes (`BrowserSession.extensionNamesDidChange(from:to:in:)`).
    var extensionName: ((URL) -> String?)?
    /// Opens a link in a new tab, optionally selecting it in the source window.
    var openURLInNewTab: ((URL, Bool) -> Void)?
    /// The session sets this callback to show the search engine's results for text selected in the page in a new tab, for the context menu's Search with.
    var searchInNewTab: ((String) -> Void)?
    /// The page assistant sets this callback to ask about text selected in the page. The context menu offers it while a provider can answer questions about pages.
    var askAboutSelection: ((String, URL) -> Void)?
    /// The session's plugins set this callback to pass a value one of the page's scripts sent to the plugin it belongs to, with the reply. Without it, the script's promise settles with nothing.
    var receivePageScriptMessage: ((EnginePageScriptMessage, @escaping (String?) -> Void) -> Void)?
    /// The session's plugins set this callback to add their items for what the user clicked on to the end of the page's context menu.
    var addPluginMenuItems: ((EngineContextMenuElement, NSMenu) -> Void)?
    /// The session sets this callback to show a web link the user clicked with Shift in the preview panel instead of opening it.
    var previewLink: ((URL) -> Void)?
    /// The session sets this callback to fill the window with the page while it is in fullscreen. Only engines that leave the transition to the app report it.
    var didChangeFullscreen: ((Bool) -> Void)?
    /// Set while a card asks to open a link in another app, so that a page cannot queue more of them.
    private var isOfferingExternalApp = false
    /// The site whose own request to open another app the user declined: its host, or its scheme for a page without one, such as a file. The page asks no more until the tab moves to another site, so changing its own address or reloading does not bring the question back. A link the user clicks or an address the user types still asks.
    private var declinedExternalAppSite: String?
    /// The last page recorded in history, so it counts only once until the tab moves to another page. Restored tabs use their saved page as the initial value.
    var recordedURL: URL?
    /// The session sets this callback to record a visit to a page, with its title, in its history store.
    var recordVisit: ((URL, String) -> Void)?
    /// The session sets this for tabs it restores from the saved session, and for the pinned tabs that browser import or sidebar sync adds only while they join the list (`BrowserSession.appendJoiningPins(_:)`). Closing a pinned tab clears it (`unloadToSavedPage()`).
    var isRestored = false
    /// The cause of a navigation or new tab that code started, which the event source attaches to the tab's next `addressChanged` events and `pageLoaded`, which uses it up (`docs/hooks.md`, Causes). A load that ends without a `pageLoaded` drops it, and so does a navigation the user starts in the tab from the app.
    var pendingCause: BrowserEventCause?
    /// The session sets this callback to learn that the tab only ever pointed at a file. The argument tells whether the file downloads; the session then closes the tab as `TabCloseAction` decides for such a tab: a pinned tab unloads, and any other leaves without a closed-list entry.
    var didOpenOnlyDownload: ((Bool) -> Void)?
    /// Set when the tab turned out to point at a file, so the file's address does not enter history.
    private(set) var isDownloadOnly = false
    /// Whether the page may start downloads without asking (`BrowserSession`'s download delegate).
    var pageDownloads = PageDownloadGate()
    /// The address of the document the main frame last committed, as the engine reports the commit, or nil before the web contents commits one. A page's dialogs name it as their page: `url` can already be the address of a navigation the page started and has not committed, as WebKit gives it. The tab's events and a hook's name go by `committedURL` instead.
    private var engineCommittedURL: URL?
    /// The session sets this to name the agent whose agent folder has the given ID, or nil for a folder of the user's.
    var agentOwnerOfFolder: ((UUID) -> UUID?)?
    /// Where an agent tab asks about its navigations and reports what its rules did. The session sets it.
    weak var agentMonitor: (any AgentTabMonitor)?

    init(id: UUID, webContents: any EngineWebContents, spaceID: UUID?, isPinned: Bool, personaID: UUID) {
        self.id = id
        self.webContents = webContents
        self.spaceID = spaceID
        self.isPinned = isPinned
        self.personaID = personaID
        self.title = webContents.title
        self.url = webContents.url?.withoutCredentials
        self.committedURL = webContents.url?.withoutCredentials
        self.isLoading = webContents.isLoading
        self.canGoBack = webContents.canGoBack
        self.canGoForward = webContents.canGoForward
        self.favicon = webContents.favicon
        webContents.uiDelegate = self
        webContents.navigationDelegate = self
        webContents.pageScriptDelegate = self
    }

    /// The engine that renders the tab.
    public var engineKind: EngineKind { webContents.engineKind }

    /// The engine to use again when the page is restored. During a temporary fallback the visible page still reports its actual engine.
    public internal(set) var preferredEngine: EngineKind {
        get { fallbackPreference ?? engineKind }
        set {
            let preference = newValue == engineKind ? nil : newValue
            if fallbackPreference != preference {
                originalEngineState = nil
                fallbackPreference = preference
            }
        }
    }
    @Published private var fallbackPreference: EngineKind?
    private var originalEngineState: (url: URL, data: Data)?

    var restorableStateForPreferredEngine: Data? {
        guard preferredEngine != engineKind else { return webContents.restorableState }
        return originalEngineState?.url == url ? originalEngineState?.data : nil
    }

    /// A fallback may show the saved address but cannot interpret or update the original renderer's history.
    func restoreEngine(_ kind: EngineKind, state: Data?, at savedURL: URL?) {
        preferredEngine = kind
        originalEngineState = nil
        guard kind != engineKind, let state, let savedURL, url == nil || savedURL == url else { return }
        originalEngineState = (savedURL, state)
    }

    /// Whether the tab has its engine's page. A tab restored from `session.json` has an `UnloadedWebContents` in its place until a window first shows it, and so does a tab whose page unloaded until a window next shows it (`BrowserSession.loadPage(of:)`).
    var isLoaded: Bool { !(webContents is UnloadedWebContents) }

    /// Puts the engine's page in place of the stand-in of a tab without one: `make` creates it at the address, in the engine, and with the page state that the stand-in keeps. A tab that has its page keeps it.
    func loadPage(_ make: (_ url: URL?, _ engine: EngineKind, _ state: Data?) -> any EngineWebContents) {
        guard let unloaded = webContents as? UnloadedWebContents else { return }
        let engine = preferredEngine
        let state = restorableStateForPreferredEngine
        replaceWebContents(with: make(unloaded.url, engine, state))
        restoreEngine(engine, state: state, at: unloaded.url)
    }

    /// Takes what a saved tab's record keeps besides its page and place, as relaunching reopens the tab: when it was last active, its names, its saved page, its folder, `folderID` being the record's folder while that folder exists, and its live folder item while it is in that folder. The tab counts as restored, and loading its saved page does not count as a visit, apart from an item's tab, which the user opens as a new page: its first load is a visit, and a file it points at downloads (`docs/bookmarks.md`, Items as tabs).
    func restore(_ record: SessionSnapshot.TabRecord, folderID: UUID?) {
        lastActivatedAt = record.lastActivatedAt ?? Date()
        customTitle = record.customTitle
        suggestedTitle = record.suggestedTitle
        savedPage = record.savedPage
        self.folderID = folderID
        liveItemID = folderID == nil ? nil : record.liveItemID
        isRestored = liveItemID == nil
        recordedURL = isRestored ? record.url?.withoutCredentials : nil
    }

    /// Takes what a closed tab's record keeps besides its page and place, as ⌘Z reopens the tab: the user's name for it, its saved page, and its folder, `folderID` being the record's folder while that folder exists.
    func reopen(_ record: SessionSnapshot.TabRecord, folderID: UUID?) {
        customTitle = record.customTitle
        savedPage = record.savedPage
        self.folderID = folderID
    }

    /// Takes what a pinned tab that browser import adds keeps besides its page and place: its folder, the name the user gave it in the other browser, and its imported address and title as its saved page (bookmark rule 2).
    func takeImport(_ pinned: SidebarImport.Plan.PinnedTab) {
        folderID = pinned.folderID
        customTitle = pinned.customTitle
        savedPage = SavedPage(url: pinned.url, title: pinned.title)
    }

    /// Sends with each change to what `session.json` keeps of the tab: its page, engine, space, pin, saved page, folder, live folder item, title, and names. The page's loading state, icon, sound, and crash notice are left out, because each save reads every tab's restorable page state.
    var persistedChanges: AnyPublisher<Void, Never> {
        func changes<Value>(_ publisher: Published<Value>.Publisher) -> AnyPublisher<Void, Never> {
            // A published value also sends its current value to each new subscriber, which is no change.
            publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        return Publishers.MergeMany(changes($webContents), changes($spaceID), changes($isPinned), changes($savedPage), changes($folderID), changes($liveItemID), changes($url),
                                    changes($title), changes($customTitle), changes($suggestedTitle), changes($fallbackPreference))
            .eraseToAnyPublisher()
    }

    /// Whether its space's list shows the tab. Everything that lists, picks, or closes a space's tabs, such as the sidebar, ⌘-numbers, the tab switcher, the palette, Close Other Tabs, the selection after a tab closes, and archiving, passes over a tab it does not show.
    var isListedInSidebar: Bool { !isInSmallWindow }

    /// The user's name for the tab, a hook's name for its page, or the page's title. A live folder item's tab shows its item's title, which its saved page keeps, while it is on the saved page, and takes no hook's name.
    public var displayTitle: String { Self.displayTitle(customTitle: customTitle, suggestedTitle: suggestedTitle, title: title, url: url, livePage: liveItemID == nil ? nil : savedPage) }

    /// The page's title, or its host if it has no title.
    public var pageTitle: String { Self.pageTitle(title: title, url: url) }

    /// `displayTitle`, with the name of the web extension whose own page the tab shows (`extensionName`), as its options page in a tab, in place of a page title that only repeats the address (`titleRepeatsAddress(_:of:)`), which would show the extension's identifier. A user's name, a hook's name, a live folder item's title, and a page's own title stay. The sidebar's rows, the window's title, the tab switcher, the palette's tab rows, the pane of a tab shown in another window, the Bookmarks menu, floating developer tools, Edit Saved Address…, a new favorite, the print job, and the file names of Export as PDF and a capture show it; plugins, hooks, agents, scripts, and the tab close log read `displayTitle`.
    var shownTitle: String {
        guard let name = extensionPageName else { return displayTitle }
        return Self.displayTitle(customTitle: customTitle, suggestedTitle: suggestedTitle, title: name, url: url, livePage: liveItemID == nil ? nil : savedPage)
    }

    /// `pageTitle` as `shownTitle` names the page: the extension's name in place of a title that only repeats the address of the extension's page. Renaming the tab to it restores the page's title, as renaming it to `pageTitle` does for any other page (`BrowserWindowModel.renameTab(_:to:)`). Sharing the page, Now Playing without the page's media metadata, and Use Current Page as Saved Page take it.
    var shownPageTitle: String { extensionPageName ?? pageTitle }

    /// The name of the web extension whose own page the tab shows (`extensionName`), while the page's title only repeats its address; nil otherwise.
    private var extensionPageName: String? {
        guard let url, Self.titleRepeatsAddress(title, of: url) else { return nil }
        return extensionName?(url)
    }

    /// Whether `title` names the page at `url` by nothing but its address: empty, as WebKit reports a page without a title and `pageTitle` then shows the host, the host itself, or the address, as Chromium reports a page without a title (`NavigationEntryImpl::GetTitleForDisplay`), compared without percent escapes and a trailing `/`.
    nonisolated static func titleRepeatsAddress(_ title: String, of url: URL) -> Bool {
        let plain = { (text: String) -> String in
            let decoded = text.removingPercentEncoding ?? text
            return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
        }
        return title.isEmpty || title == url.host || plain(title) == plain(url.absoluteString)
    }

    /// The name a tab with these inputs shows, which the event source computes from a change's new value before the tab publishes it.
    nonisolated static func displayTitle(customTitle: String?, suggestedTitle: SuggestedTitle?, title: String, url: URL?, livePage: SavedPage?) -> String {
        if let customTitle { return customTitle }
        if let livePage {
            if !livePage.title.isEmpty, url.map({ $0.isSamePage(as: livePage.url) }) ?? true { return livePage.title }
        } else if let name = suggestedTitle?.title { return name }
        return pageTitle(title: title, url: url)
    }

    nonisolated private static func pageTitle(title: String, url: URL?) -> String {
        if !title.isEmpty { return title }
        return url?.host ?? "New Tab"
    }

    /// The user acted in the tab's page, with a click that reaches it or a key that activates its focused link or button (`PageDownloadGate`), which lets the page start one more download without asking, as for the link of a file.
    public func userDidActInPage() {
        pageDownloads.userDidAct()
    }

    /// Arch loads a page in the tab for the user, as an address typed in the palette, Back, or Reload, so a download it starts is not the page's (`PageDownloadGate`).
    func userDidNavigate() {
        pageDownloads.userDidNavigate()
    }

    /// The agent session or outside client's grant whose agent folder holds the tab, or nil for the user's own tab. It follows the folder: a tab the user drags out of its folder, or whose folder's tabs the user keeps, is the user's from then on.
    public var agentOwnerID: UUID? {
        folderID.flatMap { agentOwnerOfFolder?($0) }
    }

    /// Reports to the agent monitor when the tab is an agent's.
    private func reportToAgent(_ report: AgentTabReport) {
        guard let owner = agentOwnerID else { return }
        agentMonitor?.agentTab(self, owner: owner, didReport: report)
    }
}

/// Where agent tabs report what happened in them and ask about their navigations (docs/agents.md, Permissions, approvals, and injection defenses). `BrowserAgentHost` is the session's.
@MainActor protocol AgentTabMonitor: AnyObject {
    func userDocumentDidEnd(in tabID: UUID, document: UUID)
    func userTabAddressDidChange(_ tabID: UUID)
    /// Whether the agent tab's main frame may load `url`, asked before each navigation, again before each redirect hop's request, and for a popup's first address, which `kind` tells apart (rules P13 and P16).
    func agentTab(_ tab: Tab, owner: UUID, mayLoad url: URL, kind: AgentLoadKind) -> Bool
    /// Whether a download the agent tab's page started from `url` may go ahead, because the user allowed it (rule P6).
    func agentTab(_ tab: Tab, owner: UUID, mayDownload url: URL) -> Bool
    /// The agent tab's page opened a file chooser, which the monitor ends through its P7 card before any panel opens (`AgentFileChooser`).
    func agentTab(_ tab: Tab, owner: UUID, choosesFiles chooser: AgentFileChooser)
    /// What happened in an agent tab, for its agent's next result.
    func agentTab(_ tab: Tab, owner: UUID, didReport report: AgentTabReport)
    /// The agent tab closed, before the session removes an agent folder it leaves empty.
    func agentTabDidClose(_ tab: Tab, owner: UUID)
}

extension Tab: @preconcurrency EngineWebContentsUIDelegate {
    /// A saved page taken before its page showed a title takes the first title the page shows at the saved address.
    public func webContentsDidChangeTitle(_ webContents: any EngineWebContents) {
        title = webContents.title
        if let saved = savedPage, saved.title.isEmpty, !title.isEmpty, url.map({ $0.isSamePage(as: saved.url) }) == true { savedPage?.title = title }
    }
    /// A pinned tab without a saved page, as one pinned before its page reported an address, takes the first address its page reports (bookmark rule 2), with an empty title: the tab's title is still the previous page's, and the new page's first title fills it.
    public func webContentsDidChangeURL(_ webContents: any EngineWebContents) {
        let previous = url
        url = webContents.url?.withoutCredentials
        if agentOwnerID == nil, url != previous { agentMonitor?.userTabAddressDidChange(id) }
        if let originalEngineState, let url, originalEngineState.url != url { self.originalEngineState = nil }
        reportToAgent(.addressChanged(url))
        if Self.site(of: url) != declinedExternalAppSite { declinedExternalAppSite = nil }
        if !webContents.isLoading { commit(url) }
        if isPinned, savedPage == nil, let url { savedPage = SavedPage(url: url, title: "") }
    }
    public func webContentsDidChangeFavicon(_ webContents: any EngineWebContents) { favicon = webContents.favicon }
    public func webContentsDidChangeAudibleState(_ webContents: any EngineWebContents) { isAudible = webContents.isAudible }
    public func webContentsDidClose(_ webContents: any EngineWebContents) { didClose?() }
    /// A page's request to be shown, such as an opener's `focus()` on its popup. An agent's tab never takes focus or switches the window's space, so it asks for nothing; picture in picture's way back to the tab, which comes the same way, then does nothing either, and the user reaches the tab through its folder.
    public func webContentsDidRequestActivation(_ webContents: any EngineWebContents) {
        guard agentOwnerID == nil else { return }
        requestActivation?()
    }
    public func webContentsDidRequestEnterFullscreen(_ webContents: any EngineWebContents) { didChangeFullscreen?(true) }
    public func webContentsDidRequestExitFullscreen(_ webContents: any EngineWebContents) { didChangeFullscreen?(false) }
    public func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) {
        let wasLoading = isLoading
        isLoading = webContents.isLoading
        // The Chromium engine reloads a page after a crash unless it crashed just after its last reload; any new load clears the notice.
        if isLoading { hasCrashed = false }
        canGoBack = webContents.canGoBack
        canGoForward = webContents.canGoForward
        if !isLoading {
            commit(url)
            didFinishLoad?()
        }
        if wasLoading, !isLoading { reportToAgent(.stoppedLoading) }
        // Record a page when it finishes loading, when its title is usually known. An agent's tab records none (Persona rule 6).
        if !isLoading, !isDownloadOnly, agentOwnerID == nil, let url = webContents.url?.withoutCredentials, url != recordedURL, url.scheme == "http" || url.scheme == "https" {
            recordedURL = url
            recordVisit?(url, webContents.title)
        }
    }
    public func webContents(_ webContents: any EngineWebContents, didCommitDocumentAt url: URL?) {
        guard webContents === self.webContents else { return }
        documentID = UUID()
        hasTypedInput = false
        engineCommittedURL = url
        // The commit can come long before the load ends, and before the engine reports the address as `url`.
        if let url = url?.withoutCredentials { commit(url) }
        pageDownloads.documentDidCommit(site: Self.site(of: url))
        didCommitDocument?()
    }
    public func webContentsDidFinishLoadingDocument(_ webContents: any EngineWebContents) {
        commit(url)
        didLoadDocument.send()
        reportToAgent(.loaded(url: webContents.url, title: webContents.title))
    }

    /// Takes `address` as the committed address, then drops a hook's name, or its refusal, that is not for it.
    private func commit(_ address: URL?) {
        if committedURL != address { committedURL = address }
        if let address, let suggested = suggestedTitle, !suggested.isFor(address) { suggestedTitle = nil }
    }

    public func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {
        openNewTab?(newWebContents, targetURL, disposition)
    }
    public func webContents(_ webContents: any EngineWebContents, didCreateReplacement replacement: any EngineWebContents) {
        guard webContents === self.webContents else { return }
        takeReplacement?(replacement)
    }
    /// An agent's tab gets no permission and asks nobody (rule P8): the agent hears of the request and can hand the tab to the user. Its denial leaves the Persona's kept answers as they were (`denyPermission`).
    public func webContents(_ webContents: any EngineWebContents, requestPermission request: EnginePermissionRequest, completion: @escaping (Bool) -> Void) {
        if agentOwnerID != nil {
            reportToAgent(.permissionDenied(request.types))
            guard let denyPermission else { return completion(false) }
            return denyPermission(request, completion)
        }
        guard let requestPermission else { return completion(false) }
        requestPermission(request, completion)
    }

    /// A tab that opened straight onto a file closes once its download starts. A restored tab like that does not fetch the file again, and a tab that a plugin or a web extension opened onto a file, or that a page of such a tab opened onto one, before the user acted in it or loaded an address there, downloads nothing and closes at once (`PageDownloadGate.isHeldUntilUserActs`). An agent's tab downloads only what the user allowed (rule P6): any other download stops, and the user's card about it asks for the address again after Allow.
    public func webContents(_ webContents: any EngineWebContents, shouldDownload url: URL, hasPage: Bool) -> Bool {
        if let owner = agentOwnerID {
            guard agentMonitor?.agentTab(self, owner: owner, mayDownload: url) == true else {
                reportToAgent(.downloadAsked(url))
                return false
            }
            reportToAgent(.downloadStarted(url))
            return true
        }
        // The engine can report no current document while a link to an attachment navigates away.
        guard !hasPage, engineCommittedURL == nil else { return true }
        isDownloadOnly = true
        let downloads = !isRestored && !pageDownloads.isHeldUntilUserActs
        didOpenOnlyDownload?(downloads)
        return downloads
    }

    public func webContentsProcessDidTerminate(_ webContents: any EngineWebContents) {
        crashCount += 1
        hasCrashed = true
    }

    /// Swaps in another web contents: one from another engine, one that the engine made to load a page the old one cannot, or the page of a tab that had none. The old one stops reporting to the tab before the session closes it, and the tab keeps its title and icon until the new page reports its own, and its address unless the new web contents already has one, which it may have set before it reported to the tab.
    func replaceWebContents(with replacement: any EngineWebContents) {
        webContents.uiDelegate = nil
        webContents.navigationDelegate = nil
        webContents.pageScriptDelegate = nil
        documentID = UUID()
        webContents = replacement
        replacement.uiDelegate = self
        replacement.navigationDelegate = self
        replacement.pageScriptDelegate = self
        if replacement.url != nil { webContentsDidChangeURL(replacement) }
        isLoading = replacement.isLoading
        canGoBack = replacement.canGoBack
        canGoForward = replacement.canGoForward
        isAudible = replacement.isAudible
        hasTypedInput = false
        answersBeforeUnloadWithStay = false
        hasCrashed = false
        isDownloadOnly = false
        engineCommittedURL = nil
    }

    /// Loads the crashed page's address again, which starts a new page process.
    public func reloadAfterCrash() {
        userDidNavigate()
        pendingCause = nil
        guard let url else { return webContents.navigationController.reload() }
        webContents.navigationController.load(URLRequest(url: url))
    }

    // MARK: JavaScript dialogs

    // A page's own dialogs show its words under its site, which a page cannot choose, so that a page cannot pass its dialog off as one from the app. The site is that of the document the main frame last committed, so that a page cannot show its dialog under the site of an address it starts to load. Words from a frame on another host, or from one without a host while the page has one, say so, so that an embedded page cannot pass its words off as the page's (`PromptSiteIdentity.embeddedFrame`).

    /// An agent's tab dismisses its page's alert at once and reports its text with the frame's origin (rule P10).
    public func webContents(_ webContents: any EngineWebContents, runJavaScriptAlert message: String, frameOrigin: URL?, completion: @escaping () -> Void) {
        if agentOwnerID != nil {
            reportToAgent(.alertDismissed(message: message, frame: frameOrigin))
            return completion()
        }
        showPrompt(TabPromptContent.alert(message: message, embeddedFrame: embeddedFrame(of: frameOrigin), identity: dialogIdentity(frameOrigin))) { _ in completion() }
    }

    /// In an agent's tab, as for `prompt`, the user answers on this card and the agent hears that it waits (rule P9).
    public func webContents(_ webContents: any EngineWebContents, runJavaScriptConfirm message: String, frameOrigin: URL?, completion: @escaping (Bool) -> Void) {
        reportToAgent(.dialogWaiting(.confirm, message: message, frame: frameOrigin))
        showPrompt(TabPromptContent.confirm(message: message, embeddedFrame: embeddedFrame(of: frameOrigin), identity: dialogIdentity(frameOrigin))) { completion(TabPromptContent.confirmResult($0)) }
    }

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptPrompt message: String, defaultText: String?, frameOrigin: URL?, completion: @escaping (String?) -> Void) {
        reportToAgent(.dialogWaiting(.prompt, message: message, frame: frameOrigin))
        showPrompt(TabPromptContent.textInput(message: message, defaultText: defaultText, embeddedFrame: embeddedFrame(of: frameOrigin), identity: dialogIdentity(frameOrigin))) {
            completion(TabPromptContent.textInputResult($0))
        }
    }

    /// Asks before the page is left. A page cannot choose this card's text, so the message is ignored, as in other browsers. Closing a background tab brings it forward so the question can show; an agent's tab stays where it is, and the agent hears that the question waits for the user (rule P9). Only Stay keeps the page, so a card that ends without the user, as when Arch quits, leaves it. An automatic unload stays without asking.
    public func webContents(_ webContents: any EngineWebContents, runBeforeUnloadPanel message: String, completion: @escaping (Bool) -> Void) {
        if answersBeforeUnloadWithStay { return completion(false) }
        if agentOwnerID != nil {
            reportToAgent(.dialogWaiting(.leavePage, message: ""))
        } else {
            requestSelection?()
        }
        showPrompt(TabPromptContent.leavePage(identity: pageIdentity)) { completion(TabPromptContent.leavePageResult($0)) }
    }

    public func webContentsDidCancelDialogs(_ webContents: any EngineWebContents) {
        didCancelDialogs?()
    }

    // MARK: File choosers

    /// The session answers every chooser, and in an agent tab asks the agent monitor first, whatever started it, including a DOM `click()` from the agents' world (rule P7).
    public func webContents(_ webContents: any EngineWebContents, runFileChooser request: EngineFileChooserRequest, completion: @escaping ([URL]?) -> Void) {
        guard let chooseFiles else { return completion(nil) }
        chooseFiles(request, completion)
    }

    // MARK: Context menus

    /// Builds the same menu on both engines, in the order of WebKit's own menu: the sections of the items the engine hands (`PageContextMenuSections`) with the tab's own between them: spelling suggestions, Ignore and Learn Spelling, the link, the image, Look Up and Translate, Search with, then editing or Copy, Ask About Selection, the field's text submenus, and Share… (with Speech outside a field), separated by lines. Back, Forward, and Reload show only when none of those apply. The plugins' items follow.
    public func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {
        let handed = PageContextMenuSections(takingItemsOf: menu, for: element)
        var sections = [handed.suggestions, handed.spelling]
        // WebKit puts a link's items before the selection's in a field; outside one, a click on a link or image gets no selection items.
        if let link = element.linkURL {
            sections.append([newTabItem("Open Link in New Tab", for: link), EngineActionMenuItem("Copy Link") { Self.copyToPasteboard(link) }].compactMap { $0 })
        }
        if let image = element.imageURL {
            sections.append([newTabItem("Open Image in New Tab", for: image), EngineActionMenuItem("Copy Image Address") { Self.copyToPasteboard(image) }].compactMap { $0 })
        }
        sections.append(handed.lookUp)
        if let selection = EngineTextMenuItems.selection(of: element), let searchInNewTab {
            sections.append([EngineActionMenuItem("Search with \(SearchEngine.current.title)") { searchInNewTab(selection) }])
        }
        sections.append(handed.editing)
        // Text in a field is never sent, so the question needs a selection outside one. The question goes out under the page's site, so a selection in a frame inside the page, which can come from another site, gets none.
        if let selection = element.selectedText, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !element.isEditable, element.isInMainFrame,
           let sourceURL = url, let askAboutSelection, PageAssistant.isQuestionAvailable {
            let sourceDocument = documentID
            sections.append([EngineActionMenuItem("Ask About Selection\u{2026}") { [weak self] in
                guard self?.documentID == sourceDocument else { return }
                askAboutSelection(selection, sourceURL)
            }])
        }
        sections += [handed.fieldSubmenus, handed.share]
        if sections.allSatisfy(\.isEmpty) {
            sections = [[
                EngineActionMenuItem("Back", isEnabled: webContents.canGoBack) { [weak self, weak webContents] in
                    self?.pendingCause = nil
                    webContents?.navigationController.goBack()
                },
                EngineActionMenuItem("Forward", isEnabled: webContents.canGoForward) { [weak self, weak webContents] in
                    self?.pendingCause = nil
                    webContents?.navigationController.goForward()
                },
                EngineActionMenuItem("Reload") { [weak self, weak webContents] in
                    self?.pendingCause = nil
                    webContents?.navigationController.reload()
                },
            ]]
        }
        PageContextMenuSections.show(sections, in: menu)
        addPluginMenuItems?(element, menu)
    }

    /// Only web addresses open in a tab; a link for another app offers just Copy Link.
    private func newTabItem(_ title: String, for url: URL) -> NSMenuItem? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return EngineActionMenuItem(title) { [weak self] in self?.openURLInNewTab?(url, false) }
    }

    /// Puts the address on the pasteboard as a URL and as text, for Copy Link, Copy Image Address, and Copy Address.
    static func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        pasteboard.writeObjects([item])
    }

    // MARK: Links for other apps

    /// An agent's tab hands a link to another app only after the user allows it on a card in the agent panel, which names the app (rule P11).
    public func webContents(_ webContents: any EngineWebContents, openExternally url: URL, isUserInitiated: Bool) {
        if agentOwnerID != nil { return reportToAgent(.externalAppAsked(url)) }
        if isUserInitiated { forgetExternalAppDecline() }
        offerExternalApp(for: url)
    }

    /// The user asked for the next page, as by typing its address, so a site's earlier decline no longer applies.
    func forgetExternalAppDecline() {
        declinedExternalAppSite = nil
    }

    private static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        return url.host ?? "\(url.scheme ?? ""):"
    }

    /// Asks before a page hands a link to another app, with the app's name and icon, then opens the link there. Nothing happens without an app for the link. One question shows at a time, and a site the user said no to asks no more.
    private func offerExternalApp(for url: URL) {
        guard !isOfferingExternalApp, declinedExternalAppSite == nil || declinedExternalAppSite != Self.site(of: self.url),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        isOfferingExternalApp = true
        let appName = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        let content = TabPromptContent.openInApp(appName: appName, appIcon: NSWorkspace.shared.icon(forFile: appURL.path),
                                                 hasHost: self.url?.host?.isEmpty == false, identity: pageIdentity)
        let pageSite = Self.site(of: self.url)
        showPrompt(content) { [weak self] response in
            self?.isOfferingExternalApp = false
            switch TabPromptContent.openInAppResult(response) {
            case .open:
                NSWorkspace.shared.open(url)
            case .decline:
                // Only Cancel, clicked or through Escape, counts as an answer; a card that ended without the user, as for an engine switch, does not.
                if let self, Self.site(of: self.url) == pageSite { self.declinedExternalAppSite = pageSite }
            case .none:
                break
            }
        }
    }

    // MARK: HTTP authentication

    /// Asks for a user name and password for a site or proxy, in a card whose password field is secure. The credential lasts for this session only and is never saved. In an agent's tab, the user answers and the agent hears that the question waits (rule P9).
    public func webContents(_ webContents: any EngineWebContents, didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge, completion: @escaping (URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        reportToAgent(.dialogWaiting(.signIn, message: space.host))
        let identity = PromptSiteIdentity.signIn(space, tabURL: url, favicon: favicon)
        let content = TabPromptContent.signIn(space, proposedUser: challenge.proposedCredential?.user, failed: challenge.previousFailureCount > 0, identity: identity)
        showPrompt(content) { completion(TabPromptContent.signInCredential($0)) }
    }

    /// The tab's page as the asker of its own prompts.
    private var pageIdentity: PromptIdentity {
        PromptSiteIdentity.make(for: url, in: self)
    }

    /// The page that shows a dialog of the frame at `frameOrigin`: the document the main frame last committed, or before the first one, the frame's own, as for the empty page of a new tab whose opener's script runs it.
    private func dialogPage(of frameOrigin: URL?) -> URL? {
        engineCommittedURL ?? frameOrigin
    }

    /// The page of a dialog as its asker.
    private func dialogIdentity(_ frameOrigin: URL?) -> PromptIdentity {
        let page = dialogPage(of: frameOrigin)
        return PromptSiteIdentity.make(for: page, tabURL: page, favicon: favicon) { self.extensionName?($0) }
    }

    /// The frame that shows a page dialog when it is not the page's own (`PromptSiteIdentity.embeddedFrame`).
    private func embeddedFrame(of frameOrigin: URL?) -> PromptSiteIdentity.EmbeddedFrame? {
        PromptSiteIdentity.embeddedFrame(of: frameOrigin, pageURL: dialogPage(of: frameOrigin))
    }

    private func showPrompt(_ content: PromptContent, completion: @escaping (PromptResponse) -> Void) {
        guard let presentPrompt else { return completion(.dismissed) }
        presentPrompt(content, completion)
    }

}

// MARK: Page scripts

extension Tab: @preconcurrency EnginePageScriptDelegate {
    /// `TabUnloading.inputScript`'s reports set `hasTypedInput`; every other world's values go to the plugins.
    public func webContents(_ webContents: any EngineWebContents, didReceive message: EnginePageScriptMessage, reply: @escaping (String?) -> Void) {
        if message.world == TabUnloading.inputWorld {
            if webContents === self.webContents, let event = TabUnloading.InputEvent(message) { hasTypedInput = event == .typed }
            return reply(nil)
        }
        guard let receivePageScriptMessage else { return reply(nil) }
        receivePageScriptMessage(message, reply)
    }
}

// MARK: Navigation checks and link previews

extension Tab: @preconcurrency EngineWebContentsNavigationDelegate {
    /// An agent's tab loads each address in its main frame, and each redirect hop, only once the agent monitor allows it (rules P13 and P16), whoever started the navigation; a link or window that opens elsewhere is asked about as a popup, not as a hop of the tab's navigation. A modified link can open a new tab or a Shift preview. Both open after the engine's policy callback returns.
    public func webContents(_ webContents: any EngineWebContents, decidePolicyFor action: EngineNavigationAction) -> EngineNavigationPolicy {
        let kind: AgentLoadKind = action.disposition != .currentTab ? .popup : action.isRedirect ? .redirect : .navigation
        if let owner = agentOwnerID, agentMonitor?.agentTab(self, owner: owner, mayLoad: action.url, kind: kind) == false { return .cancel }
        if action.opensLinkInNewTab, action.isUserInitiated, let scheme = action.url.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme), let openURLInNewTab {
            guard agentOwnerID == nil else { return .cancel }
            if webContents.engineKind == .webKit { return .openLinkInNewTab }
            let foreground = action.disposition == .newForegroundTab
            DispatchQueue.main.async { openURLInNewTab(action.url, foreground) }
            return .cancel
        }
        guard action.disposition == .newWindow, action.isUserInitiated, let previewLink,
              let scheme = action.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .allow }
        let url = action.url
        DispatchQueue.main.async { previewLink(url) }
        return .cancel
    }
}

/// A hook's name for a tab's document, with the document's address, so that the name goes when the tab moves to another address.
struct SuggestedTitle: Codable, Equatable {
    /// Nil once the user turned the name down: the tab shows the page's title, and hooks leave the document unnamed.
    var title: String?
    var url: URL

    /// Whether the name or its refusal is about the document at `url`, whose fragment only names a place in it.
    func isFor(_ url: URL) -> Bool {
        self.url.withoutFragment == url.withoutFragment
    }
}

extension URL {
    /// The address without its fragment, which only names a place in the document.
    var withoutFragment: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false), components.fragment != nil else { return self }
        components.fragment = nil
        return components.url ?? self
    }

    /// The address without a user name and password, as a page's own `location.href` has it. WebKit reports the address it loaded with them, and the sidebar, the history, and `session.json` keep the address without them.
    var withoutCredentials: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false), components.user != nil || components.password != nil else { return self }
        components.user = nil
        components.password = nil
        return components.url ?? self
    }
}
