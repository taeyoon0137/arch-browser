// The session's side of the AI interface's hooks: posts the tabs' document loads, new tabs, and finished downloads to the hook center, applies the actions hooks return while they still fit their event, and subscribes the built-in hooks. It follows the session's tabs and downloads, so the session only attaches it.
import AI
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class BrowserHooks: AIHookHost {
    /// The longest tab name a hook gives.
    static let maximumTabNameLength = 60

    private weak var session: BrowserSession?
    private let pageSource = TabPageSource()
    private var center: AIHookCenter { AIService.shared.hooks }
    /// The document loads of each followed tab, by tab.
    private var tabObservers: [UUID: AnyCancellable] = [:]
    /// The state of each followed download, by entry.
    private var downloadObservers: [UUID: AnyCancellable] = [:]
    /// The tabs whose first document load went out, to mark a restored tab's first load.
    private var loadedTabIDs: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Made with the session, which calls `attach(to:)` once it exists.
    nonisolated init() {}

    var pages: any AIPageSource { pageSource }

    /// Registers and subscribes the built-in hooks, then follows the session's tabs, the favorites' tabs among them, and its downloads. The tabs open now are the restored ones, so none of them counts as a new tab.
    func attach(to session: BrowserSession) {
        self.session = session
        pageSource.session = session
        center.host = self
        AIService.shared.register(.tabNameHook)
        AIService.shared.register(.downloadNameHook)
        center.subscribe(BuiltInHooks.tabName { [weak self] load in await self?.needsName(load) ?? false })
        center.subscribe(BuiltInHooks.downloadName)
        follow(session.allTabs, postingNewTabs: false)
        session.$tabs.combineLatest(session.$favoriteTabs).dropFirst()
            .sink { [weak self] tabs, favoriteTabs in MainActor.assumeIsolated { self?.follow(tabs + favoriteTabs.values, postingNewTabs: true) } }
            .store(in: &cancellables)
        session.$downloads
            .sink { [weak self] downloads in MainActor.assumeIsolated { self?.follow(downloads) } }
            .store(in: &cancellables)
    }

    // MARK: Events

    /// Follows each tab's document loads and posts a tab that opens, other than one restored from the saved session, a pinned tab that a browser import opened, and a live folder item's tab, which a refresh adds. A tab that leaves stops its hooks.
    private func follow(_ tabs: [Tab], postingNewTabs: Bool) {
        let ids = Set(tabs.map(\.id))
        for id in tabObservers.keys where !ids.contains(id) {
            tabObservers[id] = nil
            loadedTabIDs.remove(id)
            center.cancel(subject: id)
        }
        for tab in tabs where tabObservers[tab.id] == nil {
            tabObservers[tab.id] = tab.didLoadDocument
                .sink { [weak self, weak tab] in
                    MainActor.assumeIsolated {
                        if let self, let tab { self.tabDidLoadDocument(tab) }
                    }
                }
            if postingNewTabs, !tab.isRestored, tab.liveItemID == nil { center.post(.tabOpened(AITabOpen(tabID: tab.id, url: tab.url))) }
        }
    }

    private func tabDidLoadDocument(_ tab: Tab) {
        guard let url = tab.url else { return }
        let isFirstLoad = loadedTabIDs.insert(tab.id).inserted
        center.post(.pageLoaded(AIPageLoad(tabID: tab.id, url: url, isRestore: tab.isRestored && isFirstLoad)))
    }

    /// Posts each download that finishes from now on. A download the user removes from the list stops its hooks.
    private func follow(_ downloads: [DownloadEntry]) {
        let ids = Set(downloads.map(\.id))
        for id in downloadObservers.keys where !ids.contains(id) {
            downloadObservers[id] = nil
            center.cancel(subject: id)
        }
        for entry in downloads where downloadObservers[entry.id] == nil {
            // A download joins the list as it starts, when Settings decides whether a save panel asks the user for its name.
            let isNamedByUser = UserDefaults.standard.bool(forKey: BrowserSession.asksWhereToSaveDownloadsKey)
            // An entry publishes its state before its file's path, so the event waits for the rest of the update.
            downloadObservers[entry.id] = entry.$state.removeDuplicates().dropFirst().filter { $0 == .completed }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak entry] _ in
                    MainActor.assumeIsolated {
                        if let self, let entry { self.downloadDidFinish(entry, isNamedByUser: isNamedByUser) }
                    }
                }
        }
    }

    /// Hooks learn the file's name, type, size, and address, and the page it started from, never its contents.
    private func downloadDidFinish(_ entry: DownloadEntry, isNamedByUser: Bool) {
        guard let fileURL = entry.fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let byteCount = max(entry.totalBytes, entry.completedBytes)
        let info = AIDownloadInfo(filename: fileURL.lastPathComponent, mediaType: UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType,
                                  byteCount: byteCount > 0 ? byteCount : nil, sourceURL: entry.item.sourceURL, pageURL: entry.item.pageURL)
        center.post(.downloadFinished(AIDownloadFinish(downloadID: entry.id, fileURL: fileURL, info: info, isNamedByUser: isNamedByUser)))
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
              Self.takesName(for: load.url, customTitle: tab.customTitle, suggestedTitle: tab.suggestedTitle, shownURL: tab.url) else { return nil }
        return tab
    }

    /// Whether a tab that shows `shownURL`, with the user's name `customTitle` and a hook's name or its refusal `suggestedTitle`, takes a hook's name for the document at `url`: while it still shows the document, the user has not named it, and the user has not turned down a hook's name for the document.
    static func takesName(for url: URL, customTitle: String?, suggestedTitle: SuggestedTitle?, shownURL: URL?) -> Bool {
        let isTurnedDown = suggestedTitle.map { $0.title == nil && $0.isFor(url) } ?? false
        return customTitle == nil && !isTurnedDown && shownURL?.withoutFragment == url.withoutFragment
    }

    /// The first line of a hook's name, trimmed and cut to `maximumTabNameLength` characters, or nil when nothing is left.
    static func tabName(from title: String) -> String? {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = String(line.trimmingCharacters(in: .whitespaces).prefix(maximumTabNameLength)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
