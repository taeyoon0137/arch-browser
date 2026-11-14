// Live folders in the sidebar (`docs/bookmarks.md`, Live folders: Items as tabs, Read and unread, and Interface; live folder rules 1, 4, 5, and 8): a pinned folder whose tabs a source fills. `LiveFolderService` refreshes the folders and keeps their items; the session registers its live folders with it, applies each refresh's plan to the folder's tabs, and keeps the tabs' read state, dismissed items, and icons. `LiveFolderTabs` holds the parts that need no session, so tests drive them with `PageStub` and stand-in tabs; the session's side follows.
import AppKit
import ARCHEngine
import Combine
import Foundation
import LiveFolders

enum LiveFolderTabs {
    // MARK: session.json

    /// Live folders sit among the pinned tabs (live folder rule 1), so a live folder that a file puts among the open tabs moves to the pinned list; `FolderTree.repairingParents(of:)` then clears a parent left in the open list.
    static func pinningLiveFolders(_ folders: [TabFolder]) -> [TabFolder] {
        folders.map { folder in
            var folder = folder
            if folder.live != nil { folder.isPinned = true }
            return folder
        }
    }

    /// Live folders hold no folders (bookmark rule 6), so a folder whose parent is a live folder moves to the top of its list with what it holds.
    static func repairingLiveFolders(_ folders: [TabFolder]) -> [TabFolder] {
        let liveIDs = Set(folders.filter { $0.live != nil }.map(\.id))
        return folders.map { folder in
            var folder = folder
            if let parentID = folder.parentID, liveIDs.contains(parentID) { folder.parentID = nil }
            return folder
        }
    }

    /// The records as live folder rule 4 has them: only item tabs of the folder's space are in a live folder, and they are pinned. A record outside live folders loses its item, and a record in a live folder without an item, or of another space, leaves it for the folder that holds the live folder.
    static func repairingItems(of records: [SessionSnapshot.TabRecord], in folders: [TabFolder]) -> [SessionSnapshot.TabRecord] {
        let liveFolders = Dictionary(folders.filter { $0.live != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return records.map { record in
            var record = record
            guard let folder = record.folderID.flatMap({ liveFolders[$0] }) else {
                record.liveItemID = nil
                return record
            }
            if record.liveItemID == nil || record.spaceID != folder.spaceID {
                record.folderID = record.spaceID == folder.spaceID ? folder.parentID : nil
                record.liveItemID = nil
            } else {
                record.isPinned = true
            }
            return record
        }
    }

    /// The live folders' configurations by folder, as `LiveFolderService.register(_:)` takes them.
    static func configurations(in folders: [TabFolder]) -> [UUID: LiveFolderConfiguration] {
        Dictionary(folders.compactMap { folder in folder.live.map { (folder.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// The names of the private feeds' live folders, which their Keychain items' labels carry (`docs/bookmarks.md`, Storage).
    static func privateFeedNames(in folders: [TabFolder]) -> [UUID: String] {
        Dictionary(folders.compactMap { folder in
            guard case .feed(_, isPrivate: true)? = folder.live?.source else { return nil }
            return (folder.id, folder.name)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The private feeds' folders in both `old` and `new` whose names changed, by Rename Folder or Edit Live Folder…, with their new names.
    static func renamedPrivateFeeds(from old: [UUID: String], to new: [UUID: String]) -> [UUID: String] {
        new.filter { id, name in old[id].map { $0 != name } ?? false }
    }

    // MARK: Item tabs

    /// The item tabs of a live folder, in sidebar order.
    static func itemTabs(inFolder id: UUID, among tabs: [Tab]) -> [Tab] {
        tabs.filter { $0.folderID == id && $0.liveItemID != nil }
    }

    /// The stand-in of a new item tab: the item's address and title in `engine`, with the folder's icon, requesting no site icon, so that the item's site hears nothing until the user opens the item.
    static func standIn(for item: LiveItem, engine: EngineKind, icon: NSImage?) -> UnloadedWebContents {
        UnloadedWebContents(url: item.url, title: item.title, engine: engine, state: nil, icon: icon, requestsSiteIcon: false)
    }

    /// Makes a new pinned tab the item's tab in the live folder `folderID`, saved at the item's address and title (bookmark rule 2).
    static func prepare(_ tab: Tab, as item: LiveItem, inFolder folderID: UUID) {
        tab.folderID = folderID
        tab.liveItemID = item.id
        tab.liveItem = item
        tab.savedPage = SavedPage(url: item.url, title: item.title)
    }

    /// The folder's item tabs as `LiveFolderReconciler.plan(items:tabs:dismissed:)` weighs them.
    static func reconcilerTabs(_ tabs: [Tab], isShown: (Tab) -> Bool) -> [LiveItemTab] {
        tabs.compactMap { tab in
            tab.liveItemID.map { LiveItemTab(tabID: tab.id, itemID: $0, hasPage: tab.isLoaded, isShown: isShown(tab), title: tab.savedPage?.title ?? tab.title) }
        }
    }

    /// `tabs` with the plan applied to the live folder `folderID`: the retitled tabs' saved pages take their items' titles, the removed tabs leave, `makeTab` makes each new item's tab, and the folder's item tabs take the plan's order where the first of them was, or at the end without one. Returns the new list and the tabs it removed, which have no pages and no window shows.
    static func applying(_ plan: LiveFolderPlan, toFolder folderID: UUID, in tabs: [Tab], makeTab: (LiveItem) -> Tab) -> (tabs: [Tab], removed: [Tab]) {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, title) in plan.retitled { byID[id]?.savedPage?.title = title }
        let removedIDs = Set(plan.removals)
        let additions = Dictionary(plan.additions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered: [Tab] = plan.order.compactMap { entry in
            switch entry {
            case .tab(let id): return byID[id]
            case .newItem(let itemID): return additions[itemID].map(makeTab)
            }
        }
        var result: [Tab] = []
        var isPlaced = false
        for tab in tabs {
            guard tab.folderID == folderID, tab.liveItemID != nil else {
                result.append(tab)
                continue
            }
            if !isPlaced {
                result += ordered
                isPlaced = true
            }
        }
        if !isPlaced { result += ordered }
        return (result, tabs.filter { removedIDs.contains($0.id) })
    }

    /// Gives each of a folder's item tabs its item as the folder's state lists it, its unread dot (live folder rule 5), and its item's saved page, whose address a feed can change under the same ID; a tab without its page that is still on the old saved page moves there. A tab whose item the source no longer lists keeps its page without an item or a dot.
    static func update(_ itemTabs: [Tab], from state: LiveFolderState) {
        let items = Dictionary(state.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unread = state.unreadItemIDs
        for tab in itemTabs {
            guard let itemID = tab.liveItemID else { continue }
            let item = items[itemID]
            if tab.liveItem != item { tab.liveItem = item }
            let isUnread = unread.contains(itemID)
            if tab.isUnread != isUnread { tab.isUnread = isUnread }
            guard let item else { continue }
            let saved = SavedPage(url: item.url, title: item.title)
            guard tab.savedPage != saved else { continue }
            let previous = tab.savedPage
            tab.savedPage = saved
            if !tab.isLoaded, let previous, previous.url != item.url, tab.url.map({ $0.isSamePage(as: previous.url) }) ?? true {
                tab.webContents.navigationController.load(URLRequest(url: item.url))
            }
        }
    }

    /// An item tab that leaves its live folder, by a drag, Move to Folder, another space's symbol, or Unpin Tab, or whose folder is converted or deleted, becomes an ordinary tab: it keeps its saved page while pinned (bookmark rule 2) and loses its item and its dot.
    static func takeOut(_ tab: Tab) {
        tab.liveItemID = nil
        tab.liveItem = nil
        tab.isUnread = false
    }

    /// Runs `change`, a change of tabs' places, and returns the item tabs among `tabs` that it took out of their live folders, each with the folder it left.
    static func itemTabsLeaving(_ tabs: [Tab], during change: () -> Void) -> [(tab: Tab, folderID: UUID)] {
        let itemTabs = tabs.filter { $0.liveItemID != nil }.map { (tab: $0, folderID: $0.folderID) }
        change()
        return itemTabs.compactMap { entry in
            guard let folderID = entry.folderID, entry.tab.folderID != folderID else { return nil }
            return (entry.tab, folderID)
        }
    }

    /// Item tabs that left their live folders are ordinary tabs now, and their items count as viewed at `date`, so that the new tab each folder gets for the item, which the user has in view, shows no dot (live folder rule 4). Returns the folders they left.
    @MainActor
    static func takeOut(_ left: [(tab: Tab, folderID: UUID)], in store: LiveFolderStore, at date: Date) -> Set<UUID> {
        for (tab, folderID) in left {
            if let itemID = tab.liveItemID { store.update(folderID) { $0.markViewed([itemID], at: date) } }
            takeOut(tab)
        }
        return Set(left.map(\.folderID))
    }

    /// Records that windows showed the item tabs or stopped showing them, or that a refresh arrived while they showed: each item's `viewedAt` becomes `date` (live folder rule 5). With `sparingMarkedUnread`, as when a window stops showing a tab or a refresh arrives, an item without a `viewedAt` stays unread: a shown tab's item has one unless Mark as Unread cleared it while the tab showed, which then lasts until a window shows the tab again. Returns the folders whose state changed.
    @MainActor
    @discardableResult
    static func markViewed(_ itemTabs: [Tab], in store: LiveFolderStore, at date: Date, sparingMarkedUnread: Bool = false) -> Set<UUID> {
        var folders: Set<UUID> = []
        for tab in itemTabs {
            guard let folderID = tab.folderID, let itemID = tab.liveItemID else { continue }
            if sparingMarkedUnread, store[folderID].viewedAt[itemID] == nil { continue }
            store.update(folderID) { $0.markViewed([itemID], at: date) }
            folders.insert(folderID)
        }
        return folders
    }
}

// MARK: Statuses

/// What a live folder's row shows besides its name and what its menu offers: the unread items' count, whether it refreshes, the last refresh's failure with the timer's next attempt, and the dismissed items' count.
struct LiveFolderStatus: Equatable {
    var unreadCount = 0
    var isRefreshing = false
    /// The last refresh's failure, which a success clears.
    var error: String?
    /// When the timer next tries a folder whose last refresh failed.
    var nextAttempt: Date?
    /// The dismissed items that the source still lists, which Show Dismissed Items brings back.
    var dismissedCount = 0
}

/// The live folders' statuses, published apart from the session, so that a refresh redraws only the folder rows.
final class LiveFolderStatuses: ObservableObject {
    @Published private(set) var byFolder: [UUID: LiveFolderStatus] = [:]

    subscript(folder: UUID) -> LiveFolderStatus {
        byFolder[folder] ?? LiveFolderStatus()
    }

    func set(_ status: LiveFolderStatus?, for folder: UUID) {
        if byFolder[folder] != status { byFolder[folder] = status }
    }

    /// Forgets the folders that are no longer live folders.
    func keep(_ folders: Set<UUID>) {
        let kept = byFolder.filter { folders.contains($0.key) }
        if kept.count != byFolder.count { byFolder = kept }
    }
}

// MARK: The session's side

extension BrowserSession {
    /// At launch: registers the live folders, which removes `live-folders.json` entries and Keychain items of folders that are gone, plans each folder's tabs from its stored items, starts the check every 5 minutes, and follows the folders, the app's activation, and the windows' spaces.
    @MainActor func startLiveFolders() {
        liveFolderService.didChange = { [weak self] in self?.liveFolderDidChange($0) }
        registerLiveFolders()
        for folder in folders where folder.live != nil { planLiveFolder(folder.id) }
        liveFolderService.start()
        // After the change, so that registering reads the session's new folders. A rename changes no configuration.
        $folders.map(LiveFolderTabs.configurations).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.registerLiveFolders() } }
            .store(in: &liveFolderObservers)
        // A private feed's Keychain item is labelled with its folder's name, so a rename relabels it.
        $folders.map(LiveFolderTabs.privateFeedNames).removeDuplicates()
            .scan(([UUID: String](), [UUID: String]())) { ($0.1, $1) }
            .sink { [weak self] old, new in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (id, name) in LiveFolderTabs.renamedPrivateFeeds(from: old, to: new) { self.liveFolderService.setPrivateAddressFolderName(name, for: id) }
                }
            }
            .store(in: &liveFolderObservers)
        // Live folder rule 6: GitHub folders refresh when Arch becomes active and when a window shows their space, at most once every 5 minutes.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.liveFolderService.applicationDidBecomeActive() } }
            .store(in: &liveFolderObservers)
        $windows.map { windows in Publishers.MergeMany(windows.filter { $0.kind == .main }.map { $0.$currentSpaceID }) }.switchToLatest()
            .sink { [weak self] spaceID in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.liveFolderService.windowDidShowFolders(self.folders.filter { $0.spaceID == spaceID && $0.live != nil }.map(\.id))
                }
            }
            .store(in: &liveFolderObservers)
    }

    /// Registers every live folder's configuration, as at launch and after each change of one: a new folder or a changed source starts over and refreshes, and the entries and Keychain items of folders, spaces, and Personas that went are removed (`docs/bookmarks.md`, Storage).
    @MainActor func registerLiveFolders() {
        let configurations = LiveFolderTabs.configurations(in: folders)
        liveFolderService.register(configurations)
        liveFolderStatuses.keep(Set(configurations.keys))
        liveFolderIcons = liveFolderIcons.filter { configurations[$0.key] != nil }
        for folder in folders where folder.live != nil {
            loadIcon(ofLiveFolder: folder)
            updateLiveFolderStatus(folder.id)
        }
    }

    /// A refresh started or ended: the items of the folder's tabs that windows show count as viewed again, so that what the user looked at stays read, and the folder's tabs follow its items.
    @MainActor private func liveFolderDidChange(_ id: UUID) {
        let shown = LiveFolderTabs.itemTabs(inFolder: id, among: tabs).filter { window(showing: $0) != nil }
        LiveFolderTabs.markViewed(shown, in: liveFolderService.store, at: Date(), sparingMarkedUnread: true)
        planLiveFolder(id)
    }

    /// Brings a live folder's tabs in line with its stored items (`LiveFolderReconciler`): new items get tabs without pages in the default engine, tabs of items the source no longer lists go unless they have their pages or a window shows them, or will once the saved session's windows open (`windowShowsOrWillShow(_:)`), and the tabs take the source's order. A folder that has not fetched since it started over keeps its tabs until it has. Then the tabs take their items' read state, and the row its status.
    @MainActor func planLiveFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }), folder.live != nil else { return }
        let state = liveFolderService.store[id]
        if state.lastSuccess != nil {
            let itemTabs = LiveFolderTabs.itemTabs(inFolder: id, among: tabs)
            let plan = LiveFolderReconciler.plan(items: state.items, tabs: LiveFolderTabs.reconcilerTabs(itemTabs, isShown: windowShowsOrWillShow), dismissed: state.dismissed)
            let personaID = personaID(ofSpace: folder.spaceID)
            let icon = liveFolderIcons[id]?.image
            let result = LiveFolderTabs.applying(plan, toFolder: id, in: tabs) { item in
                let tab = makeTab(LiveFolderTabs.standIn(for: item, engine: defaultEngine, icon: icon), id: UUID(), spaceID: folder.spaceID, personaID: personaID, pinned: true)
                LiveFolderTabs.prepare(tab, as: item, inFolder: id)
                return tab
            }
            if result.tabs.map(\.id) != tabs.map(\.id) { replaceTabs(with: result.tabs, removing: result.removed) }
        }
        LiveFolderTabs.update(LiveFolderTabs.itemTabs(inFolder: id, among: tabs), from: state)
        updateLiveFolderStatus(id)
    }

    /// Publishes the folder's status for its row, or forgets it once the folder is no live folder.
    @MainActor private func updateLiveFolderStatus(_ id: UUID) {
        guard folders.contains(where: { $0.id == id && $0.live != nil }) else { return liveFolderStatuses.set(nil, for: id) }
        let state = liveFolderService.store[id]
        liveFolderStatuses.set(LiveFolderStatus(unreadCount: state.unreadItemIDs.count, isRefreshing: liveFolderService.isRefreshing(id), error: state.lastError,
                                                nextAttempt: state.lastError == nil ? nil : liveFolderService.nextAttempt(for: id),
                                                dismissedCount: state.items.filter { state.dismissed.contains($0.id) }.count), for: id)
    }

    /// Shows a feed folder's icon, the `/favicon.ico` of its feed's host, which the folder fetches from anyway, in the rows of its items' tabs without pages, loaded once per folder and launch through `FaviconLoader`, and again when the feed moves to another host. A private feed's address has no query here, so the icon's address carries no token.
    @MainActor private func loadIcon(ofLiveFolder folder: TabFolder) {
        guard case .feed(let address, _)? = folder.live?.source, let iconURL = FaviconLoader.defaultIconURL(for: address), liveFolderIcons[folder.id]?.url != iconURL else { return }
        liveFolderIcons[folder.id] = (iconURL, nil)
        FaviconLoader.load(iconURL) { [weak self] image in
            guard let self, let image, self.liveFolderIcons[folder.id]?.url == iconURL else { return }
            self.liveFolderIcons[folder.id] = (iconURL, image)
            for tab in LiveFolderTabs.itemTabs(inFolder: folder.id, among: self.tabs) where !tab.isLoaded && tab.favicon == nil {
                (tab.webContents as? UnloadedWebContents)?.showIcon(image)
            }
        }
    }

    // MARK: Closing and moving item tabs

    /// Closing an item's tab (live folder rule 4): the tab leaves without joining the closed list, and the item stays out of the folder while the source lists it, until Show Dismissed Items.
    @MainActor func dismissItem(_ tab: Tab, reason: TabCloseReason) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let folderID = tab.folderID, itemID = tab.liveItemID
        removeTab(tab, closedRecord: nil, reason: reason)
        guard let folderID, let itemID else { return }
        liveFolderService.store.update(folderID) { $0.dismiss(itemID) }
        updateLiveFolderStatus(folderID)
    }

    /// Item tabs that a move took out of their live folders are ordinary tabs now; each folder immediately gets a new tab for the item, marked read (live folder rule 4).
    @MainActor func itemTabsDidLeave(_ left: [(tab: Tab, folderID: UUID)]) {
        LiveFolderTabs.takeOut(left, in: liveFolderService.store, at: Date()).forEach(planLiveFolder)
    }

    /// A window started or stopped showing tabs: the items of those that are item tabs count as viewed now, so that the changes the user made while looking stay read (live folder rule 5), apart from an item marked unread while its tab showed.
    func windowDidChangeShownTabs(from old: [UUID], to new: [UUID]) {
        guard old != new else { return }
        let started = Set(new).subtracting(old), stopped = Set(old).subtracting(new)
        let itemTabs = tabs.filter { $0.liveItemID != nil && (started.contains($0.id) || stopped.contains($0.id)) }
        guard !itemTabs.isEmpty else { return }
        MainActor.assumeIsolated {
            let store = liveFolderService.store, date = Date()
            let changed = LiveFolderTabs.markViewed(itemTabs.filter { started.contains($0.id) }, in: store, at: date)
                .union(LiveFolderTabs.markViewed(itemTabs.filter { stopped.contains($0.id) }, in: store, at: date, sparingMarkedUnread: true))
            changed.forEach(followItems(ofLiveFolder:))
        }
    }

    /// The folder's tabs and row follow a change of its read state or dismissed items.
    @MainActor private func followItems(ofLiveFolder id: UUID) {
        LiveFolderTabs.update(LiveFolderTabs.itemTabs(inFolder: id, among: tabs), from: liveFolderService.store[id])
        updateLiveFolderStatus(id)
    }

    // MARK: New Live Folder… and Edit Live Folder…

    /// The live folders of every space and Persona, which live folder rule 7 limits to 20.
    var liveFolderCount: Int {
        folders.filter { $0.live != nil }.count
    }

    /// New Live Folder…'s Add (`docs/bookmarks.md`, Interface): a private feed's whole address goes to the Keychain first (live folder rule 8), then the folder joins the space's pinned list after its folders, expanded, and registering it refreshes it. Returns the folder's ID, or nil when the space went meanwhile; throws the Keychain's failure, or `LiveFolderSheetError.folderLimit` when the app reached 20 live folders meanwhile.
    @MainActor func addLiveFolder(_ submission: LiveFolderSheetModel.Submission, toSpace spaceID: UUID) async throws -> UUID? {
        guard liveFolderCount < LiveFolderConfiguration.maximumFolders else { throw LiveFolderSheetError.folderLimit }
        let folder = submission.newFolder(in: spaceID)
        if let address = submission.keychainAddress {
            try await liveFolderService.setPrivateAddress(address, for: folder.id, folderName: folder.name)
        }
        let isAtLimit = liveFolderCount >= LiveFolderConfiguration.maximumFolders
        guard !isAtLimit, spaces.contains(where: { $0.id == spaceID }) else {
            // No folder will register the address written for it.
            if submission.keychainAddress != nil { try? await liveFolderService.addresses.removeAddress(for: folder.id) }
            if isAtLimit { throw LiveFolderSheetError.folderLimit }
            return nil
        }
        appendFolder(folder)
        return folder.id
    }

    /// Edit Live Folder…'s Save: the folder takes the sheet's name, source, item limit, and refresh interval. A private feed's new whole address goes to the Keychain first (live folder rule 8), which starts over a private feed whose whole address alone changed; registering the change starts the folder over when its source changed and refreshes it when its item limit changed (`LiveFolderService`). A folder that went or stopped being live meanwhile changes nothing.
    @MainActor func editLiveFolder(_ id: UUID, with submission: LiveFolderSheetModel.Submission) async throws {
        guard folders.contains(where: { $0.id == id && $0.live != nil }) else { return }
        if let address = submission.keychainAddress {
            try await liveFolderService.setPrivateAddress(address, for: id, folderName: submission.name)
        }
        guard folders.contains(where: { $0.id == id && $0.live != nil }) else { return }
        updateFolder(id) { submission.apply(to: &$0) }
    }

    // MARK: Commands

    /// Refresh Now.
    @MainActor func refreshLiveFolder(_ id: UUID) {
        liveFolderService.refresh(id)
    }

    /// Mark All as Read.
    @MainActor func markAllAsRead(inLiveFolder id: UUID) {
        liveFolderService.store.update(id) { $0.markAllViewed(at: Date()) }
        followItems(ofLiveFolder: id)
    }

    /// Mark as Read or Mark as Unread on an item's tab.
    @MainActor func setRead(_ isRead: Bool, ofItemTab tab: Tab) {
        guard let folderID = tab.folderID, let itemID = tab.liveItemID else { return }
        liveFolderService.store.update(folderID) { state in
            if isRead { state.markViewed([itemID], at: Date()) } else { state.markUnread(itemID) }
        }
        followItems(ofLiveFolder: folderID)
    }

    /// Show Dismissed Items: the dismissed items the source still lists get their tabs again.
    @MainActor func showDismissedItems(inLiveFolder id: UUID) {
        liveFolderService.store.update(id) { $0.restoreDismissed() }
        planLiveFolder(id)
    }

    /// Convert to Folder: the folder becomes an ordinary folder whose tabs are ordinary pinned tabs with their saved pages. Registering then forgets the source, the folder's entry in `live-folders.json`, and its Keychain item.
    @MainActor func convertToFolder(_ id: UUID) {
        guard folders.contains(where: { $0.id == id && $0.live != nil }) else { return }
        LiveFolderTabs.itemTabs(inFolder: id, among: tabs).forEach(LiveFolderTabs.takeOut)
        updateFolder(id) { $0.live = nil }
        liveFolderStatuses.set(nil, for: id)
    }

    /// Delete Folder for a live folder: the folder goes, and its item tabs close without joining the closed list once their pages agree. Until then each is an ordinary pinned tab where the folder was, so a tab whose page asks to stay keeps its place with its saved page. As after an unload, ⌘Z then reopens none of the tabs closed before.
    @MainActor func deleteLiveFolder(_ id: UUID) {
        let itemTabs = LiveFolderTabs.itemTabs(inFolder: id, among: tabs)
        itemTabs.forEach(LiveFolderTabs.takeOut)
        changeFolderTree { $0.deleteFolder(id) }
        windows.forEach { $0.endRenamingFolder(id) }
        liveFolderStatuses.set(nil, for: id)
        forgetUndoableCloses()
        for tab in itemTabs {
            whenPageAgreesToLeave(tab) { [weak self] tab in self?.perform(.close(remember: false), on: tab, reason: .user) }
        }
    }
}
