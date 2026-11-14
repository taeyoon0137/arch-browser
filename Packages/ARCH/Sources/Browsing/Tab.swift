// Each tab wraps an engine web contents instance. It publishes the state shown in the sidebar and command bar.
import AppKit
import ARCHEngine
import Combine
import Foundation
import LiveFolders

public final class Tab: ObservableObject, Identifiable {
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
    /// Pinning saves the page the tab shows as its saved page, or the first address its page reports when it shows none yet, and unpinning forgets it (bookmark rule 2). Pin Tab, Unpin Tab, and drops among the pinned or open tabs or into a folder of either list all set it, so each follows the rule; a tab made pinned, as one that restores or reopens, takes its saved page from the caller.
    @Published public var isPinned: Bool {
        didSet {
            guard isPinned != oldValue else { return }
            savedPage = isPinned ? currentPage : nil
        }
    }
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
    /// The name a hook gave the tab's document, shown while the user has not named the tab, or a mark that the user turned it down. Another address clears it, even one a single-page site sets within its document, since the name may no longer fit; another fragment does not. The session restores it.
    @Published var suggestedTitle: SuggestedTitle?
    @Published public private(set) var url: URL?
    @Published public private(set) var isLoading: Bool
    @Published public private(set) var canGoBack: Bool
    @Published public private(set) var canGoForward: Bool
    @Published public private(set) var favicon: NSImage?
    /// Whether the page plays sound, for a speaker badge on its row.
    @Published public private(set) var isAudible = false
    /// Whether the page uses the camera or the microphone, which keeps the tab loaded (bookmark rule 5).
    @Published public private(set) var isCapturingMedia = false
    /// Whether the user typed into the page since its main frame's document loaded, as `TabUnloading.inputScript` reports, which keeps the tab loaded (bookmark rule 5). Another web contents starts without.
    private(set) var hasTypedInput = false
    /// Set by the session while an automatic unload asks the page to leave, until the page answers, the user asks it to leave, or another web contents takes its place: a Chromium page's leave-page question then gets Stay without a card, which keeps the page (bookmark rule 5).
    var answersBeforeUnloadWithStay = false
    /// Set for a tab that a page opened behind the selected tab, until the user selects it, for a dot on its row. The session sets it, and the window that selects the tab clears it. A live folder item's tab follows its item's read state instead (live folder rule 5).
    @Published public internal(set) var isUnread = false
    /// Set when the page's process quit and nothing has loaded since. The window covers such a page with a notice and a Reload button.
    @Published public private(set) var hasCrashed = false
    /// How many times this tab's page process quit, kept for the tab close log.
    public private(set) var crashCount = 0
    /// The session sets this callback so popups from this tab open as new tabs.
    var openNewTab: ((any EngineWebContents) -> Void)?
    /// The session sets this callback to put in the tab's place a web contents that the engine made to load a page the tab's web contents cannot, as WebKit does for a web extension's pages.
    var takeReplacement: ((any EngineWebContents) -> Void)?
    /// The page that opened this tab, which the window returns to when the tab's page closes itself, as a sign-in popup does once it has reported back. The session sets it for a tab a page opens.
    weak var opener: (any EngineWebContents)?
    /// Closes the tab, as `TabCloseAction` decides, when its page closes itself with `window.close()` or the engine closes its crashed page. Set by the session.
    var didClose: (() -> Void)?
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
    /// The session sets this callback to show a prompt as a card over the tab's pane, which waits until a window shows the tab (`TabPromptQueue`). Without it the prompt ends at once without the user, which gives the page the safe answer.
    var presentPrompt: ((PromptContent, @escaping (PromptResponse) -> Void) -> Void)?
    /// The session sets this callback to open an address from the page's context menu in a background tab.
    var openURLInNewTab: ((URL) -> Void)?
    /// The session sets this callback to show the search engine's results for text selected in the page in a new tab, for the context menu's Search with.
    var searchInNewTab: ((String) -> Void)?
    /// The page assistant sets this callback to ask about text selected in the page. The context menu offers it while a provider can answer questions about pages.
    var askAboutSelection: ((String) -> Void)?
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
    /// The session sets this for tabs it restores from the saved session and for the pinned tabs a browser import opens. Closing a pinned tab clears it (`unloadToSavedPage()`).
    var isRestored = false
    /// The session sets this callback to learn that the tab only ever pointed at a file. The argument tells whether the file downloads; the session then closes the tab as `TabCloseAction` decides for such a tab: a pinned tab unloads, and any other leaves without a closed-list entry.
    var didOpenOnlyDownload: ((Bool) -> Void)?
    /// Set when the tab turned out to point at a file, so the file's address does not enter history.
    private(set) var isDownloadOnly = false
    /// Whether the page may start downloads without asking (`BrowserSession`'s download delegate).
    var pageDownloads = PageDownloadGate()

    init(id: UUID, webContents: any EngineWebContents, spaceID: UUID?, isPinned: Bool, personaID: UUID) {
        self.id = id
        self.webContents = webContents
        self.spaceID = spaceID
        self.isPinned = isPinned
        self.personaID = personaID
        self.title = webContents.title
        self.url = webContents.url?.withoutCredentials
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

    /// Whether the tab has its engine's page. A tab restored from `session.json` has an `UnloadedWebContents` in its place until a window first shows it, and so does a tab whose page unloaded until a window next shows it (`BrowserSession.loadPage(of:)`).
    var isLoaded: Bool { !(webContents is UnloadedWebContents) }

    /// Puts the engine's page in place of the stand-in of a tab without one: `make` creates it at the address, in the engine, and with the page state that the stand-in keeps. A tab that has its page keeps it.
    func loadPage(_ make: (_ url: URL?, _ engine: EngineKind, _ state: Data?) -> any EngineWebContents) {
        guard let unloaded = webContents as? UnloadedWebContents else { return }
        replaceWebContents(with: make(unloaded.url, unloaded.engineKind, unloaded.restorableState))
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

    /// Takes what a pinned tab that browser import opens keeps besides its page and place: its folder, the name the user gave it in the other browser, and its imported address and title as its saved page (bookmark rule 2). It opens as a restored tab does: the hooks post it as no new tab, its first load is no visit, and an address that turns out to be a file downloads nothing.
    func takeImport(_ pinned: SidebarImport.Plan.PinnedTab) {
        folderID = pinned.folderID
        customTitle = pinned.customTitle
        savedPage = SavedPage(url: pinned.url, title: pinned.title)
        isRestored = true
        recordedURL = pinned.url
    }

    /// Sends with each change to what `session.json` keeps of the tab: its page, engine, space, pin, saved page, folder, live folder item, title, and names. The page's loading state, icon, sound, and crash notice are left out, because each save reads every tab's restorable page state.
    var persistedChanges: AnyPublisher<Void, Never> {
        func changes<Value>(_ publisher: Published<Value>.Publisher) -> AnyPublisher<Void, Never> {
            // A published value also sends its current value to each new subscriber, which is no change.
            publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        return Publishers.MergeMany(changes($webContents), changes($spaceID), changes($isPinned), changes($savedPage), changes($folderID), changes($liveItemID), changes($url),
                                    changes($title), changes($customTitle), changes($suggestedTitle))
            .eraseToAnyPublisher()
    }

    /// Whether its space's list shows the tab. Everything that lists, picks, or closes a space's tabs, such as the sidebar, ⌘-numbers, the tab switcher, the palette, Close Other Tabs, the selection after a tab closes, and archiving, passes over a tab it does not show.
    var isListedInSidebar: Bool { !isInSmallWindow }

    /// The user's name for the tab, a hook's name for its page, or the page's title. A live folder item's tab shows its item's title, which its saved page keeps, while it is on the saved page, and takes no hook's name.
    public var displayTitle: String {
        if let customTitle { return customTitle }
        guard liveItemID != nil else { return suggestedTitle?.title ?? pageTitle }
        if let saved = savedPage, !saved.title.isEmpty, url.map({ $0.isSamePage(as: saved.url) }) ?? true { return saved.title }
        return pageTitle
    }

    /// The page's title, or its host if it has no title.
    public var pageTitle: String {
        if !title.isEmpty { return title }
        return url?.host ?? "New Tab"
    }

    /// The user clicked in the tab's page, which lets the page start one more download without asking, as for the link of a file.
    public func userDidClickInPage() {
        pageDownloads.userDidClick()
    }

    /// Arch loads a page in the tab for the user, as an address typed in the palette, Back, or Reload, so a download it starts is not the page's (`PageDownloadGate`).
    func userDidNavigate() {
        pageDownloads.userDidNavigate()
    }
}

extension Tab: EngineWebContentsUIDelegate {
    /// A saved page taken before its page showed a title takes the first title the page shows at the saved address.
    public func webContentsDidChangeTitle(_ webContents: any EngineWebContents) {
        title = webContents.title
        if let saved = savedPage, saved.title.isEmpty, !title.isEmpty, url.map({ $0.isSamePage(as: saved.url) }) == true { savedPage?.title = title }
    }
    /// A pinned tab without a saved page, as one pinned before its page reported an address, takes the first address its page reports (bookmark rule 2), with an empty title: the tab's title is still the previous page's, and the new page's first title fills it.
    public func webContentsDidChangeURL(_ webContents: any EngineWebContents) {
        url = webContents.url?.withoutCredentials
        if Self.site(of: url) != declinedExternalAppSite { declinedExternalAppSite = nil }
        if let url, let suggested = suggestedTitle, !suggested.isFor(url) { suggestedTitle = nil }
        if isPinned, savedPage == nil, let url { savedPage = SavedPage(url: url, title: "") }
    }
    public func webContentsDidChangeFavicon(_ webContents: any EngineWebContents) { favicon = webContents.favicon }
    public func webContentsDidChangeAudibleState(_ webContents: any EngineWebContents) { isAudible = webContents.isAudible }
    public func webContentsDidChangeMediaCapture(_ webContents: any EngineWebContents) { isCapturingMedia = webContents.isCapturingMedia }
    public func webContentsDidClose(_ webContents: any EngineWebContents) { didClose?() }
    public func webContentsDidRequestActivation(_ webContents: any EngineWebContents) { requestActivation?() }
    public func webContentsDidRequestEnterFullscreen(_ webContents: any EngineWebContents) { didChangeFullscreen?(true) }
    public func webContentsDidRequestExitFullscreen(_ webContents: any EngineWebContents) { didChangeFullscreen?(false) }
    public func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) {
        isLoading = webContents.isLoading
        // The Chromium engine reloads a page after a crash unless it crashed just after its last reload; any new load clears the notice.
        if isLoading { hasCrashed = false }
        canGoBack = webContents.canGoBack
        canGoForward = webContents.canGoForward
        if !isLoading { didFinishLoad?() }
        // Record a page when it finishes loading, when its title is usually known.
        if !isLoading, !isDownloadOnly, let url = webContents.url?.withoutCredentials, url != recordedURL, url.scheme == "http" || url.scheme == "https" {
            recordedURL = url
            recordVisit?(url, webContents.title)
        }
    }
    public func webContents(_ webContents: any EngineWebContents, didCommitDocumentAt url: URL?) {
        pageDownloads.documentDidCommit(site: Self.site(of: url))
    }
    public func webContentsDidFinishLoadingDocument(_ webContents: any EngineWebContents) {
        didLoadDocument.send()
    }

    public func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {
        openNewTab?(newWebContents)
    }
    public func webContents(_ webContents: any EngineWebContents, didCreateReplacement replacement: any EngineWebContents) {
        guard webContents === self.webContents else { return }
        takeReplacement?(replacement)
    }
    public func webContents(_ webContents: any EngineWebContents, requestPermission request: EnginePermissionRequest, completion: @escaping (Bool) -> Void) {
        guard let requestPermission else { return completion(false) }
        requestPermission(request, completion)
    }

    /// A tab that opened straight onto a file closes once its download starts. A restored tab like that does not fetch the file again.
    public func webContents(_ webContents: any EngineWebContents, shouldDownload url: URL, hasPage: Bool) -> Bool {
        guard !hasPage else { return true }
        isDownloadOnly = true
        didOpenOnlyDownload?(!isRestored)
        return !isRestored
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
        webContents = replacement
        replacement.uiDelegate = self
        replacement.navigationDelegate = self
        replacement.pageScriptDelegate = self
        if replacement.url != nil { webContentsDidChangeURL(replacement) }
        isLoading = replacement.isLoading
        canGoBack = replacement.canGoBack
        canGoForward = replacement.canGoForward
        isAudible = replacement.isAudible
        isCapturingMedia = replacement.isCapturingMedia
        hasTypedInput = false
        answersBeforeUnloadWithStay = false
        hasCrashed = false
        isDownloadOnly = false
    }

    /// Loads the crashed page's address again, which starts a new page process.
    public func reloadAfterCrash() {
        userDidNavigate()
        guard let url else { return webContents.navigationController.reload() }
        webContents.navigationController.load(URLRequest(url: url))
    }

    // MARK: JavaScript dialogs

    // A page's own dialogs show its words under its site, which a page cannot choose, so that a page cannot pass its dialog off as one from the app.
    public func webContents(_ webContents: any EngineWebContents, runJavaScriptAlert message: String, completion: @escaping () -> Void) {
        showPrompt(TabPromptContent.alert(message: message, identity: pageIdentity)) { _ in completion() }
    }

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void) {
        showPrompt(TabPromptContent.confirm(message: message, identity: pageIdentity)) { completion(TabPromptContent.confirmResult($0)) }
    }

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptPrompt message: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        showPrompt(TabPromptContent.textInput(message: message, defaultText: defaultText, identity: pageIdentity)) { completion(TabPromptContent.textInputResult($0)) }
    }

    /// Asks before the page is left. A page cannot choose this card's text, so the message is ignored, as in other browsers. Closing a background tab brings it forward so the question can show. Only Stay keeps the page, so a card that ends without the user, as when Arch quits, leaves it. An automatic unload asks nothing and stays (`answersBeforeUnloadWithStay`).
    public func webContents(_ webContents: any EngineWebContents, runBeforeUnloadPanel message: String, completion: @escaping (Bool) -> Void) {
        if answersBeforeUnloadWithStay { return completion(false) }
        requestSelection?()
        showPrompt(TabPromptContent.leavePage(identity: pageIdentity)) { completion(TabPromptContent.leavePageResult($0)) }
    }

    public func webContentsDidCancelDialogs(_ webContents: any EngineWebContents) {
        didCancelDialogs?()
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
           let askAboutSelection, MainActor.assumeIsolated({ PageAssistant.isQuestionAvailable }) {
            sections.append([EngineActionMenuItem("Ask About Selection") { askAboutSelection(selection) }])
        }
        sections += [handed.fieldSubmenus, handed.share]
        if sections.allSatisfy(\.isEmpty) {
            sections = [[
                EngineActionMenuItem("Back", isEnabled: webContents.canGoBack) { [weak webContents] in webContents?.navigationController.goBack() },
                EngineActionMenuItem("Forward", isEnabled: webContents.canGoForward) { [weak webContents] in webContents?.navigationController.goForward() },
                EngineActionMenuItem("Reload") { [weak webContents] in webContents?.navigationController.reload() },
            ]]
        }
        PageContextMenuSections.show(sections, in: menu)
        addPluginMenuItems?(element, menu)
    }

    /// Only web addresses open in a tab; a link for another app offers just Copy Link.
    private func newTabItem(_ title: String, for url: URL) -> NSMenuItem? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return EngineActionMenuItem(title) { [weak self] in self?.openURLInNewTab?(url) }
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

    public func webContents(_ webContents: any EngineWebContents, openExternally url: URL, isUserInitiated: Bool) {
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
        let content = TabPromptContent.openInApp(appName: appName, appIcon: NSWorkspace.shared.icon(forFile: appURL.path), scheme: url.scheme ?? "",
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

    /// Asks for a user name and password for a site or proxy, in a card whose password field is secure. The credential lasts for this session only and is never saved.
    public func webContents(_ webContents: any EngineWebContents, didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge, completion: @escaping (URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let identity = PromptSiteIdentity.signIn(space, tabURL: url, favicon: favicon)
        let content = TabPromptContent.signIn(space, proposedUser: challenge.proposedCredential?.user, failed: challenge.previousFailureCount > 0, identity: identity)
        showPrompt(content) { completion(TabPromptContent.signInCredential($0)) }
    }

    /// The tab's page as the asker of its own prompts.
    private var pageIdentity: PromptIdentity {
        PromptSiteIdentity.make(for: url, in: self)
    }

    private func showPrompt(_ content: PromptContent, completion: @escaping (PromptResponse) -> Void) {
        guard let presentPrompt else { return completion(.dismissed) }
        presentPrompt(content, completion)
    }

}

// MARK: Page scripts

extension Tab: EnginePageScriptDelegate {
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

// MARK: Link previews

extension Tab: EngineWebContentsNavigationDelegate {
    /// A web link the user clicked with Shift opens in the preview panel instead of the page. The engine is still deciding, so the panel opens once its callback returns.
    public func webContents(_ webContents: any EngineWebContents, decidePolicyFor action: EngineNavigationAction) -> EngineNavigationPolicy {
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
