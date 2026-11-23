// The session serves tab and page calls from plugins and hook scripts (`docs/plugins.md`, Manager, runtimes, and the browser host).
// It lists each Persona's open tabs as plugins see them, omitting agent tabs. Suggested names follow AI hook rules (`docs/hooks.md`, hook decision 13), and their events name the caller's cause.
// It also gives plugins access to tabs' pages and to each Persona's own history. One host serves every Persona's plugin manager and the JavaScript hook runner.
import ARCHEngine
import Events
import Foundation
import History
import Plugins

/// Implements plugin tab, download, history, notification, and page access through a browser session.
@MainActor
public final class SessionPluginBrowserHost: PluginBrowserHost {
    private weak var session: BrowserSession?

    /// Made with the session, which calls `attach(to:)` once it exists.
    nonisolated init() {}

    /// Attaches the session after the host has been created.
    func attach(to session: BrowserSession) {
        self.session = session
    }

    /// Lists one Persona's sidebar tabs for plugins, excluding agent tabs.
    public func tabs(in persona: PersonaID) -> [PluginTab] {
        guard let session else { return [] }
        return session.tabsInSidebarOrder.filter { $0.personaID == persona && BrowserEventSource.kind(of: $0) != .agent }.map(session.pluginTab)
    }

    /// Lists one Persona's downloads with the metadata available to plugins.
    public func downloads(in persona: PersonaID) -> [PluginDownload] {
        session?.downloads.filter { $0.personaID == persona }.map {
            PluginDownload(id: $0.id, name: $0.filename, state: $0.state.rawValue,
                           completedBytes: $0.completedBytes, totalBytes: $0.totalBytes)
        } ?? []
    }

    /// Renames a download only when it belongs to the requested Persona.
    public func renameDownload(_ id: UUID, to name: String, in persona: PersonaID) -> Bool {
        guard let entry = session?.downloads.first(where: { $0.id == id && $0.personaID == persona }) else { return false }
        return entry.rename(to: name)
    }

    /// The Persona's own visits in the session's history (`HistoryStore.pages(in:matching:limit:where:)`).
    public func history(matching text: String, limit: Int, in persona: PersonaID, where isIncluded: @escaping @Sendable (URL) -> Bool) async -> [PluginHistoryEntry] {
        guard let session else { return [] }
        return await session.history.pages(in: persona, matching: text, limit: limit, where: isIncluded).map {
            PluginHistoryEntry(url: $0.url, title: $0.title, lastVisit: $0.lastVisit, visitCount: $0.visitCount)
        }
    }

    /// Asks the session to post a local notification under the plugin's name.
    public func postNotification(pluginName: String, title: String, body: String) {
        session?.postPluginNotification(pluginName: pluginName, title: title, body: body)
    }

    /// Only a space's tab takes a suggested name; a favorite's tab goes by its favorite's name. The rename's title change posts inside `withCause`, so it names its cause.
    public func renameTab(_ id: UUID, to name: String?, showing document: URL?, cause: BrowserEventCause, applying: Bool) -> Bool {
        guard let session, let tab = session.tabs.first(where: { $0.id == id }), BrowserEventSource.kind(of: tab) != .agent,
              let document = document ?? tab.committedURL else { return false }
        return session.events.withCause(cause) { BrowserHooks.suggest(name, for: document, to: tab, applying: applying) }
    }

    /// The page of an open tab, a favorite's among them; the manager has checked that the tab is its Persona's.
    public func webContents(forTab id: UUID) -> (any EngineWebContents)? {
        pluginTab(id)?.webContents
    }

    /// The tab that a command from the window that last became main gets (`BrowserWindowModel.selectedPluginTab(of:)`).
    public func selectedTab(in persona: PersonaID) -> UUID? {
        session?.activeWindow?.selectedPluginTab(of: persona)?.id
    }

    /// The tab goes where a new tab that the user opens in the space goes, and its `tabOpened`, `tabSelected`, the `spaceSwitched` that the selection brings, and its first `addressChanged` and `pageLoaded` carry the cause, which the tab keeps for its first load. Its downloads ask until the user acts in its page or loads an address in it, and an address of a file downloads nothing (`PageDownloadGate.holdUntilUserActs()`).
    public func openTab(_ url: URL, _ options: PluginOpenTabOptions, in persona: PersonaID, cause: BrowserEventCause) throws -> UUID {
        guard let session, session.personas.contains(where: { $0.id == persona }) else { throw PluginError.closed }
        let space: Space
        if let id = options.spaceID {
            guard let named = session.spaces.first(where: { $0.id == id }), named.resolvedPersonaID == persona else { throw PluginError.notGranted(id) }
            space = named
        } else {
            space = session.preferredSpace(in: persona)
        }
        return session.events.withCause(cause) {
            let tab = session.openTab(url: url, in: space.id, select: false, engine: options.engine)
            tab.pageDownloads.holdUntilUserActs()
            if options.select { select(tab, in: session) }
            return tab.id
        }
    }

    /// The tab closes as a web extension's `tabs.remove` closes it, without asking its page (`BrowserSession.closeTab(_:reason:)`), and its `tabClosed` and the `tabSelected` of each window that moves to another tab carry the cause. ⌘Z reopens only the tabs the user just closed, newest first, so a close that puts its record ahead of theirs ends that, as a page's own close does; Reopen Last Closed Tab and the Library still reopen it.
    public func closeTab(_ id: UUID, cause: BrowserEventCause) {
        guard let session, let tab = pluginTab(id) else { return }
        let remembers = TabCloseAction.of(tab, reason: .plugin) == .close(remember: true)
        let closed = session.events.withCause(cause) { session.closeTab(tab, reason: .plugin) }
        if closed, remembers { session.forgetUndoableCloses() }
    }

    /// The `tabSelected` and the `spaceSwitched` that the selection brings carry the cause.
    public func selectTab(_ id: UUID, cause: BrowserEventCause) {
        guard let session, let tab = pluginTab(id) else { return }
        session.events.withCause(cause) { select(tab, in: session) }
    }

    /// The tab moves as a drag to a tab's row (`BrowserSession.moveTab(_:to:after:)`) or a drop on a space's symbol (`moveTab(_:toSpace:)`) moves it, or to the end of its own list (`moveTabToListEnd(_:pinned:)`), and keeps its list, so that it stays pinned or open. A move next to a tab of another space first goes to that space, which takes the tab out of its split view and has each window that selects it follow it there, with the `spaceSwitched` carrying the cause. A tab that a space's lists do not show, a favorite's or a small window's, and a live folder's tab, which keeps its source's order (live folder rule 4) and which nothing else enters, neither move nor take a tab next to them.
    public func moveTab(_ id: UUID, to place: PluginTabPlace, cause: BrowserEventCause) throws -> Bool {
        guard let session, let tab = pluginTab(id) else { return false }
        switch place {
        case let .before(neighborID), let .after(neighborID):
            guard let neighbor = pluginTab(neighborID), neighbor.id != tab.id, Self.isMovable(tab, in: session), Self.isMovable(neighbor, in: session),
                  neighbor.isPinned == tab.isPinned, let spaceID = neighbor.spaceID, session.canMoveTab(tab.id, toSpace: spaceID) else { return false }
            session.events.withCause(cause) {
                if tab.spaceID != spaceID { session.moveTab(tab.id, toSpace: spaceID) }
                session.moveTab(tab.id, to: neighbor, after: place == .after(neighborID))
            }
        case let .end(ofSpace: named):
            if let named, session.spaces.first(where: { $0.id == named })?.resolvedPersonaID != tab.personaID { throw PluginError.notGranted(named) }
            guard Self.isMovable(tab, in: session), let spaceID = named ?? tab.spaceID else { return false }
            session.events.withCause(cause) {
                if tab.spaceID == spaceID { session.moveTabToListEnd(tab.id, pinned: tab.isPinned) } else { session.moveTab(tab.id, toSpace: spaceID) }
            }
        }
        return true
    }

    /// Whether a plugin moves the tab and puts a tab next to it: a space's tab that its lists show, outside live folders.
    private static func isMovable(_ tab: Tab, in session: BrowserSession) -> Bool {
        tab.spaceID != nil && tab.isListedInSidebar && tab.liveItemID == nil && !session.folderTree.isLive(tab.folderID)
    }

    /// Selects the tab in a window of its Persona only, so that a window of another Persona keeps its Persona / Space, which selecting a favorite's tab of another Persona would change: the window of the Persona that shows it, else the front main window on its space, else the front main window of its Persona, which then shows the tab's space, or for a favorite's tab stays on its own. None selects it without such a window. A window that has the tab selected already stays as it is, so that the internal page, palette, or find bar that the user has open there stays.
    private func select(_ tab: Tab, in session: BrowserSession) {
        let window = session.windows.first { $0.personaID == tab.personaID && $0.shows(tab) }
            ?? session.windows.first { $0.kind == .main && tab.spaceID != nil && $0.currentSpaceID == tab.spaceID }
            ?? session.windows.first { $0.kind == .main && $0.personaID == tab.personaID }
        guard let window, window.selectedTabID != tab.id else { return }
        window.selectTab(tab.id)
    }

    /// An open tab other than an agent tab, a favorite's among them.
    private func pluginTab(_ id: UUID) -> Tab? {
        guard let tab = session?.allTabs.first(where: { $0.id == id }), BrowserEventSource.kind(of: tab) != .agent else { return nil }
        return tab
    }
}
