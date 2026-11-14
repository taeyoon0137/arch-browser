// The session's side of the AI interface's hooks (`docs/hooks.md`, The AI hook center): turns the bus's page loads, new tabs, and finished downloads into the hook center's events, ends a tab's hooks when it commits another document or closes, applies the actions hooks return while they still fit their event, and subscribes the built-in hooks. It never sees agent tabs. The session only attaches it.
import AI
import Combine
import Events
import Foundation
import Plugins

@MainActor
final class BrowserHooks: AIHookHost {
    /// The longest tab name a hook gives.
    static let maximumTabNameLength = PluginTab.maximumNameLength
    /// The bus events the center hears of; the filter's empty tab kinds leave agent tabs out.
    static let events = BrowserEventFilter(kinds: [.pageLoaded, .tabOpened, .downloadFinished, .addressChanged, .tabClosed])

    private weak var session: BrowserSession?
    private let pageSource = TabPageSource()
    private var center: AIHookCenter?
    private var subscription: BrowserEventSubscription?
    /// The downloads in the list, to stop the hooks of one the user removes.
    private var downloadIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Made with the session, which calls `attach(to:)` once it exists.
    nonisolated init() {}

    var pages: any AIPageSource { pageSource }

    /// Hooks the session's bus to the shared AI service's center, and follows the session's downloads.
    func attach(to session: BrowserSession) {
        self.session = session
        pageSource.session = session
        attach(events: session.events, service: AIService.shared)
        session.$downloads
            .sink { [weak self] downloads in MainActor.assumeIsolated { self?.follow(downloads) } }
            .store(in: &cancellables)
    }

    /// Registers and subscribes the built-in hooks on `service`'s center, which this object hosts, and follows `events` for it.
    func attach(events: BrowserEventBus, service: AIService) {
        let center = service.hooks
        self.center = center
        center.host = self
        service.register(.tabNameHook)
        service.register(.downloadNameHook)
        center.subscribe(BuiltInHooks.tabName { [weak self] load in await self?.needsName(load) ?? false })
        center.subscribe(BuiltInHooks.downloadName)
        subscription = events.subscribe(Self.events) { [weak self] event in self?.handle(event) }
    }

    // MARK: Events

    /// Posts a page load, new tab, or finished download under the bus event's identifier, so other owners' hooks for it join its chain. A new document ends the tab's hooks for other documents, and a close ends its hooks except the close's own.
    private func handle(_ event: BrowserEvent) {
        guard let center else { return }
        switch event.payload {
        case .addressChanged(let tab, _):
            center.scheduler.cancel(subject: tab.id, otherThan: tab.url)
        case .tabClosed(let tab, _):
            center.scheduler.cancel(subject: tab.id, except: event.id)
        case .downloadFinished(let download):
            let fileURL = session?.downloads.first { $0.id == download.id }?.fileURL
            if let hookEvent = Self.hookEvent(for: event, fileURL: fileURL) { center.post(hookEvent, event: event.id) }
        default:
            if let hookEvent = Self.hookEvent(for: event, fileURL: nil) { center.post(hookEvent, event: event.id) }
        }
    }

    /// The center's event for a bus event: a page load with its tab's address, which a `pageLoaded` always has, a new tab, or a finished download with the file's URL from the session's entry, which the bus event leaves out.
    static func hookEvent(for event: BrowserEvent, fileURL: URL?) -> AIHookEvent? {
        switch event.payload {
        case .pageLoaded(let tab, let isRestore, _):
            guard let url = tab.url else { return nil }
            return .pageLoaded(AIPageLoad(tabID: tab.id, url: url, isRestore: isRestore))
        case .tabOpened(let tab, _):
            return .tabOpened(AITabOpen(tabID: tab.id, url: tab.url))
        case .downloadFinished(let download):
            guard let fileURL else { return nil }
            let info = AIDownloadInfo(filename: download.filename, mediaType: download.mediaType, byteCount: download.byteCount, sourceURL: download.sourceURL, pageURL: download.pageURL)
            return .downloadFinished(AIDownloadFinish(downloadID: download.id, fileURL: fileURL, info: info, isNamedByUser: download.isNamedByUser))
        default:
            return nil
        }
    }

    /// A download the user removes from the list stops its hooks.
    private func follow(_ downloads: [DownloadEntry]) {
        let ids = Set(downloads.map(\.id))
        for id in downloadIDs.subtracting(ids) { center?.cancel(subject: id) }
        downloadIDs = ids
    }

    // MARK: Actions

    /// A tab's new name applies to the page load's tab only; a file's new name applies to the finished download's file only, while the user has not chosen its name and it is still where the event found it.
    func apply(_ action: AIHookAction, for event: AIHookEvent) -> Bool {
        switch (action, event) {
        case let (.renameTab(id, title), .pageLoaded(load)) where id == load.tabID:
            guard let name = Self.tabName(from: title), let tab = unnamedTab(showing: load) else { return false }
            tab.suggestedTitle = SuggestedTitle(title: name, url: load.url)
            return true
        case let (.renameDownload(id, filename), .downloadFinished(download)) where id == download.downloadID && !download.isNamedByUser:
            guard let entry = session?.downloads.first(where: { $0.id == id }), entry.fileURL == download.fileURL else { return false }
            return entry.rename(to: filename)
        default:
            return false
        }
    }

    /// Whether the tab name hook asks for a name for the load's page: not for the first load of a restored tab or of a pinned tab that a browser import opened, so that launching and importing send nothing, and not for a document the tab has a hook's name for already.
    func needsName(_ load: AIPageLoad) -> Bool {
        guard !load.isRestore, let tab = unnamedTab(showing: load) else { return false }
        return tab.suggestedTitle?.isFor(load.url) != true
    }

    /// The load's tab while it is a space's tab that takes a hook's name for the loaded document. A favorite's tab goes by its favorite's name, and a live folder item's tab by its item's title.
    private func unnamedTab(showing load: AIPageLoad) -> Tab? {
        guard let tab = session?.tabs.first(where: { $0.id == load.tabID }), tab.liveItemID == nil,
              Self.takesName(for: load.url, customTitle: tab.customTitle, suggestedTitle: tab.suggestedTitle, shownURL: tab.committedURL) else { return nil }
        return tab
    }

    /// Whether a tab that shows `shownURL`, with the user's name `customTitle` and a hook's name or its refusal `suggestedTitle`, takes a hook's name for the document at `url`: while it still shows the document, the user has not named it, and the user has not turned down a hook's name for the document.
    static func takesName(for url: URL, customTitle: String?, suggestedTitle: SuggestedTitle?, shownURL: URL?) -> Bool {
        let isTurnedDown = suggestedTitle.map { $0.title == nil && $0.isFor(url) } ?? false
        return customTitle == nil && !isTurnedDown && shownURL?.withoutFragment == url.withoutFragment
    }

    /// The first line of a hook's name, trimmed and cut to `maximumTabNameLength` characters, or nil when nothing is left.
    static func tabName(from title: String) -> String? {
        PluginTab.name(from: title)
    }

    /// Gives the tab the suggested name for the document at `document`, under the rules the AI hooks' names follow (`docs/hooks.md`, hook decision 13), for plugins and hook scripts: the name's first line, trimmed and cut, while the tab still shows the document, the user has not named it, and the user has not turned down a suggested name for the document. Nil removes a suggested name for the document, leaving the user's name and a turned-down name as they are, while the tab shows it and the user has not named it. Returns whether the tab took the change; with `applying` false nothing changes.
    static func suggest(_ name: String?, for document: URL, to tab: Tab, applying: Bool) -> Bool {
        guard tab.liveItemID == nil else { return false }
        guard let name else {
            guard tab.customTitle == nil, tab.committedURL?.withoutFragment == document.withoutFragment else { return false }
            if applying, let suggested = tab.suggestedTitle, suggested.title != nil, suggested.isFor(document) { tab.suggestedTitle = nil }
            return true
        }
        guard let shown = tabName(from: name),
              takesName(for: document, customTitle: tab.customTitle, suggestedTitle: tab.suggestedTitle, shownURL: tab.committedURL) else { return false }
        if applying { tab.suggestedTitle = SuggestedTitle(title: shown, url: document) }
        return true
    }
}
