// The session's browser event source follows tabs in spaces, favorites, and small windows, plus windows and downloads (`docs/hooks.md`, The source).
// It posts each event kind to the session's bus. The session attaches it after restoring saved tabs, reports each `removeTab` close, and restores windows inside `restoringWindows(_:)`.
import ARCHEngine
import Combine
import Events
import Foundation
import UniformTypeIdentifiers

/// What the source follows of a browser window.
@MainActor protocol BrowserEventWindow: AnyObject {
    var id: UUID { get }
    var selectedTabIDs: AnyPublisher<UUID?, Never> { get }
    var currentSpaceIDs: AnyPublisher<UUID, Never> { get }
}

extension BrowserWindowModel: BrowserEventWindow {
    var selectedTabIDs: AnyPublisher<UUID?, Never> { $selectedTabID.eraseToAnyPublisher() }
    var currentSpaceIDs: AnyPublisher<UUID, Never> { $currentSpaceID.eraseToAnyPublisher() }
}

extension BrowserTabCloseReason {
    init(_ reason: TabCloseReason) {
        switch reason {
        case .user: self = .user
        case .page: self = .page
        case .crash: self = .crash
        case .archive: self = .archive
        case .download: self = .download
        case .webExtension: self = .webExtension
        case .plugin: self = .plugin
        case .persona: self = .spaceDeleted
        case .sync: self = .sync
        }
    }
}

@MainActor
final class BrowserEventSource {
    let bus: BrowserEventBus
    /// Ends work on a replaced document as soon as it commits, even if the address stays the same.
    var documentDidChange: ((UUID, URL?, UUID) -> Void)?
    /// The Persona of a space, which a space switch names. Attaching to the session sets it.
    var personaOfSpace: (UUID) -> UUID? = { _ in nil }

    /// What the source keeps for a tab it follows.
    @MainActor
    private final class FollowedTab {
        weak var tab: Tab?
        var observers: Set<AnyCancellable> = []
        /// The inputs of the tab's shown name, its address, and its committed address as last published.
        var shown: Shown
        /// The inputs as the source last read the shown name, while the tab showed its committed address.
        var named: Shown
        /// The cause of the latest change to the tab's suggested name while its address waited to settle, which the title change that names it posts with once the address settles.
        var unsettledNameCause: BrowserEventCause?
        /// Set at the tab's `tabOpened` until its first load of a web address.
        var awaitsFirstLoadAfterOpen = false
        var hasLoaded = false

        init(_ tab: Tab) {
            self.tab = tab
            shown = Shown(title: tab.title, customTitle: tab.customTitle, suggestedTitle: tab.suggestedTitle, url: tab.url, committedURL: tab.committedURL)
            named = shown
        }
    }

    private struct Shown: Equatable {
        var title: String
        var customTitle: String?
        var suggestedTitle: SuggestedTitle?
        var url: URL?
        var committedURL: URL?

        /// Whether the tab shows its committed address, so that the shown name is its committed document's.
        var isSettled: Bool { url == committedURL }
        var name: String { Tab.displayTitle(customTitle: customTitle, suggestedTitle: suggestedTitle, title: title, url: committedURL) }
    }

    private var tabs: [UUID: FollowedTab] = [:]
    private var windows: [UUID: Set<AnyCancellable>] = [:]
    /// Each followed window's current space as last published.
    private var windowSpaces: [UUID: UUID] = [:]
    private var downloads: [UUID: AnyCancellable] = [:]
    private var isRestoringWindows = false
    private var cancellables: Set<AnyCancellable> = []

    /// Made with the session, which attaches it once it exists.
    nonisolated init(bus: BrowserEventBus) {
        self.bus = bus
    }

    /// Follows the session. The tabs open now are the restored ones, so none of them counts as a new tab.
    func attach(to session: BrowserSession) {
        personaOfSpace = { [weak session] id in session?.spaces.first { $0.id == id }?.resolvedPersonaID }
        follow(tabs: session.allTabs, postingNewTabs: false)
        session.$tabs.combineLatest(session.$favoriteTabs).dropFirst()
            .sink { [weak self] tabs, favoriteTabs in MainActor.assumeIsolated { self?.follow(tabs: tabs + favoriteTabs.values, postingNewTabs: true) } }
            .store(in: &cancellables)
        session.$windows
            .sink { [weak self] windows in MainActor.assumeIsolated { self?.follow(windows: windows) } }
            .store(in: &cancellables)
        session.$downloads
            .sink { [weak self] downloads in MainActor.assumeIsolated { self?.follow(downloads: downloads) } }
            .store(in: &cancellables)
    }

    // MARK: Tabs

    /// Follows each tab's loads, address, and shown name, and posts `tabOpened` for a tab that joins, other than one restored from the saved session or a pinned tab that browser import or sidebar sync adds. A tab opened inside `withCause` keeps the cause for its first load. A tab that leaves is no longer followed.
    func follow(tabs current: [Tab], postingNewTabs: Bool) {
        let ids = Set(current.map(\.id))
        for id in tabs.keys where !ids.contains(id) {
            tabs[id] = nil
        }
        for tab in current where tabs[tab.id] == nil {
            let followed = FollowedTab(tab)
            tabs[tab.id] = followed
            observe(tab, followed)
            guard postingNewTabs, !tab.isRestored else { continue }
            followed.awaitsFirstLoadAfterOpen = true
            if let cause = bus.currentCause { tab.pendingCause = cause }
            bus.post(.tabOpened(tab: ref(tab), openerTabID: openerID(of: tab)))
        }
    }

    /// Posts `tabClosed` while the session still lists the tab, so the event's consumers can read its last name and address.
    func tabWillClose(_ tab: Tab, reason: BrowserTabCloseReason) {
        bus.post(.tabClosed(tab: ref(tab), reason: reason))
    }

    private func observe(_ tab: Tab, _ followed: FollowedTab) {
        tab.$documentID.dropFirst()
            .sink { [weak self, weak tab] documentID in
                MainActor.assumeIsolated {
                    if let tab { self?.documentDidChange?(tab.id, tab.committedURL, documentID) }
                }
            }
            .store(in: &followed.observers)
        tab.didLoadDocument
            .sink { [weak self, weak tab] in
                MainActor.assumeIsolated {
                    if let self, let tab { self.tabDidLoadDocument(tab) }
                }
            }
            .store(in: &followed.observers)
        // The tab publishes its loading state on every progress report, so only a change counts.
        tab.$isLoading.removeDuplicates().dropFirst().filter { !$0 }
            .sink { [weak self, weak tab] _ in
                MainActor.assumeIsolated {
                    if let self, let tab { self.tabDidStopLoading(tab) }
                }
            }
            .store(in: &followed.observers)
        // A published value reaches its subscribers before the tab holds it, so the change comes with its new value.
        Publishers.CombineLatest(Publishers.CombineLatest4(tab.$title, tab.$customTitle, tab.$suggestedTitle, tab.$url),
                                 tab.$committedURL).dropFirst()
            .sink { [weak self, weak tab] inputs, committedURL in
                MainActor.assumeIsolated {
                    let (title, customTitle, suggestedTitle, url) = inputs
                    if let self, let tab {
                        self.tab(tab, didChangeTo: Shown(title: title, customTitle: customTitle, suggestedTitle: suggestedTitle, url: url,
                                                       committedURL: committedURL))
                    }
                }
            }
            .store(in: &followed.observers)
    }

    /// A new committed address (`Tab.committedURL`) posts `addressChanged` with the tab's pending cause. A new shown name posts `titleChanged` with the input that supplies it while the tab shows its committed address; a name that changes while the tab's address waits to settle posts once it settles, if it differs then, since the tab may leave that address before it commits. A suggested name that code gave while the address waited keeps its cause for that later title change, so a hook or plugin still sees its own rename as its own.
    private func tab(_ tab: Tab, didChangeTo shown: Shown) {
        guard let followed = tabs[tab.id], followed.shown != shown else { return }
        let previous = followed.shown
        followed.shown = shown
        if shown.committedURL != previous.committedURL {
            bus.post(.addressChanged(tab: ref(tab, url: shown.committedURL), previousURL: previous.committedURL), cause: tab.pendingCause)
        }
        guard shown.isSettled else {
            if shown.suggestedTitle != previous.suggestedTitle { followed.unsettledNameCause = bus.currentCause }
            return
        }
        let named = followed.named
        followed.named = shown
        let unsettledNameCause = followed.unsettledNameCause
        followed.unsettledNameCause = nil
        guard shown.name != named.name else { return }
        let source = Self.titleSource(of: shown, after: named)
        // Without a cause of its own, the post takes the enclosing `withCause` block's, as a change that settles at once does.
        bus.post(.titleChanged(tab: ref(tab, url: shown.committedURL), source: source), cause: source == .suggested ? unsettledNameCause : nil)
    }

    /// The input that supplies a new shown name: the user's name or its removal, and the user turning down a hook's name, are `user`; a hook's name is `suggested`; the page's title or host, also once another address drops a hook's name, is `page`.
    private static func titleSource(of shown: Shown, after previous: Shown) -> BrowserTitleSource {
        if shown.customTitle != previous.customTitle { return .user }
        guard shown.suggestedTitle != previous.suggestedTitle, let suggested = shown.suggestedTitle else { return .page }
        return suggested.title == nil ? .user : .suggested
    }

    /// The tab's load ended, whether it committed or not. A pending cause that no `pageLoaded` uses up by the end of the update goes, since its navigation failed or became a download; WebKit reports the end of a load just before its document's load.
    private func tabDidStopLoading(_ tab: Tab) {
        guard tabs[tab.id] != nil, let cause = tab.pendingCause else { return }
        DispatchQueue.main.async { [weak tab] in
            MainActor.assumeIsolated {
                guard let tab, !tab.webContents.isLoading, tab.pendingCause == cause else { return }
                tab.pendingCause = nil
            }
        }
    }

    /// Posts the load of a tab that has an address, after its address, which the tab commits first, with its pending cause, which the load uses up. The first load of a restored tab is a restore.
    private func tabDidLoadDocument(_ tab: Tab) {
        guard let followed = tabs[tab.id], let url = tab.committedURL else { return }
        let isFirstLoad = !followed.hasLoaded
        followed.hasLoaded = true
        let isWebAddress = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        let isFirstLoadAfterOpen = followed.awaitsFirstLoadAfterOpen && isWebAddress
        if isFirstLoadAfterOpen { followed.awaitsFirstLoadAfterOpen = false }
        let cause = tab.pendingCause
        tab.pendingCause = nil
        bus.post(.pageLoaded(tab: ref(tab), isRestore: tab.isRestored && isFirstLoad, isFirstLoadAfterOpen: isFirstLoadAfterOpen), cause: cause)
    }

    private func ref(_ tab: Tab) -> BrowserTabRef {
        ref(tab, url: tab.committedURL)
    }

    private func ref(_ tab: Tab, url: URL?) -> BrowserTabRef {
        BrowserTabRef(id: tab.id, personaID: tab.personaID, spaceID: tab.spaceID, kind: Self.kind(of: tab), engine: tab.engineKind, url: url, documentID: tab.documentID,
                      agentOwnerID: tab.agentOwnerID)
    }

    /// A tab that an agent folder holds (`Tab.agentOwnerID`) is an agent's, whatever else it is, and becomes the user's kind again once it leaves the folder.
    static func kind(of tab: Tab) -> BrowserTabKind {
        if tab.agentOwnerID != nil { return .agent }
        if tab.spaceID == nil { return .favorite }
        if tab.isInSmallWindow { return .smallWindow }
        return tab.isPinned ? .pinned : .open
    }

    private func openerID(of tab: Tab) -> UUID? {
        guard let opener = tab.opener else { return nil }
        return tabs.values.first { $0.tab?.webContents === opener }?.tab?.id
    }

    // MARK: Windows

    /// Follows each window's selected tab and current space. A window's space when the source first sees it is no switch.
    func follow(windows current: [any BrowserEventWindow]) {
        let ids = Set(current.map(\.id))
        for id in windows.keys where !ids.contains(id) {
            windows[id] = nil
            windowSpaces[id] = nil
        }
        for window in current where windows[window.id] == nil {
            let windowID = window.id
            var observers: Set<AnyCancellable> = []
            window.selectedTabIDs.removeDuplicates().dropFirst()
                .sink { [weak self] tabID in MainActor.assumeIsolated { self?.window(windowID, didSelect: tabID) } }
                .store(in: &observers)
            window.currentSpaceIDs.removeDuplicates()
                .sink { [weak self] spaceID in MainActor.assumeIsolated { self?.window(windowID, didSwitchTo: spaceID) } }
                .store(in: &observers)
            windows[windowID] = observers
        }
    }

    /// Restoring windows selects their saved tabs and spaces, which post nothing.
    func restoringWindows(_ body: () -> Void) {
        isRestoringWindows = true
        defer { isRestoringWindows = false }
        body()
    }

    private func window(_ windowID: UUID, didSelect tabID: UUID?) {
        guard !isRestoringWindows, let tabID, let tab = tabs[tabID]?.tab else { return }
        bus.post(.tabSelected(tab: ref(tab), windowID: windowID))
    }

    private func window(_ windowID: UUID, didSwitchTo spaceID: UUID) {
        let previousSpaceID = windowSpaces.updateValue(spaceID, forKey: windowID)
        guard !isRestoringWindows, let previousSpaceID, let personaID = personaOfSpace(spaceID) else { return }
        bus.post(.spaceSwitched(windowID: windowID, spaceID: spaceID, personaID: personaID, previousSpaceID: previousSpaceID, previousPersonaID: personaOfSpace(previousSpaceID)))
    }

    // MARK: Downloads

    /// Posts each download that finishes from now on.
    func follow(downloads current: [DownloadEntry]) {
        let ids = Set(current.map(\.id))
        for id in downloads.keys where !ids.contains(id) {
            downloads[id] = nil
        }
        for entry in current where downloads[entry.id] == nil {
            // A download joins the list as it starts, when Settings decides whether a save panel asks the user for its name.
            let isNamedByUser = UserDefaults.standard.bool(forKey: BrowserSession.asksWhereToSaveDownloadsKey)
            // The tab may leave its agent folder or close before the download finishes.
            let tab = entry.item.webContents.flatMap { page in tabs.values.first { $0.tab?.webContents === page }?.tab }
            let tabID = tab?.id
            let tabKind = tab.map(Self.kind(of:))
            // An entry publishes its state before its file's path, so the event waits for the rest of the update.
            downloads[entry.id] = entry.$state.removeDuplicates().dropFirst().filter { $0 == .completed }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak entry] _ in
                    MainActor.assumeIsolated {
                        if let self, let entry { self.downloadDidFinish(entry, isNamedByUser: isNamedByUser, tabID: tabID, tabKind: tabKind) }
                    }
                }
        }
    }

    /// The event names the file, its type from its extension, its size, its addresses, and the tab it started from with its kind, never its folder or contents. A file that is not in place posts nothing.
    private func downloadDidFinish(_ entry: DownloadEntry, isNamedByUser: Bool, tabID: UUID?, tabKind: BrowserTabKind?) {
        guard let fileURL = entry.fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let byteCount = max(entry.totalBytes, entry.completedBytes)
        let openTabID = tabID.flatMap { tabs[$0]?.tab?.id }
        bus.post(.downloadFinished(download: BrowserDownloadRef(id: entry.id, personaID: entry.personaID, tabID: openTabID, filename: fileURL.lastPathComponent,
                                                                mediaType: UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType,
                                                                byteCount: byteCount > 0 ? byteCount : nil, sourceURL: entry.item.sourceURL, pageURL: entry.item.pageURL,
                                                                isNamedByUser: isNamedByUser, tabKind: tabKind)))
    }
}
