// The session's side of the tab calls of plugins and hook scripts (`docs/plugins.md`, Manager, runtimes, and the browser host): every Persona's open tabs as plugins see them, never agent tabs, suggested names under the AI hooks' rules (`docs/hooks.md`, hook decision 13), whose events carry the caller's cause, and the tabs' pages for plugins' page calls. One host serves every Persona's plugin manager and the JavaScript hook runner.
import ARCHEngine
import Events
import Foundation
import Plugins

@MainActor
public final class SessionPluginBrowserHost: PluginBrowserHost {
    private weak var session: BrowserSession?

    /// Made with the session, which calls `attach(to:)` once it exists.
    nonisolated init() {}

    func attach(to session: BrowserSession) {
        self.session = session
    }

    public func tabs(in persona: PersonaID) -> [PluginTab] {
        guard let session else { return [] }
        return session.tabsInSidebarOrder.filter { $0.personaID == persona && BrowserEventSource.kind(of: $0) != .agent }.map(session.pluginTab)
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

    /// The tab goes where a new tab that the user opens in the space goes, and its `tabOpened`, `tabSelected`, and first `pageLoaded` carry the cause, which the tab keeps for its first load. Its downloads ask until the user clicks in its page or loads an address in it, and an address of a file downloads nothing (`PageDownloadGate.pluginDidOpen()`).
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
            tab.pageDownloads.pluginDidOpen()
            if options.select { select(tab, in: session) }
            return tab.id
        }
    }

    /// The tab closes as a web extension's `tabs.remove` closes it, without asking its page (`BrowserSession.closeTab(_:reason:)`). ⌘Z reopens only the tabs the user just closed, newest first, so a close that puts its record ahead of theirs ends that, as a page's own close does; Reopen Last Closed Tab and the Library still reopen it.
    public func closeTab(_ id: UUID, cause: BrowserEventCause) {
        guard let session, let tab = pluginTab(id) else { return }
        let remembers = TabCloseAction.of(tab, reason: .plugin) == .close(remember: true)
        let closed = session.events.withCause(cause) { session.closeTab(tab, reason: .plugin) }
        if closed, remembers { session.forgetUndoableCloses() }
    }

    public func selectTab(_ id: UUID, cause: BrowserEventCause) {
        guard let session, let tab = pluginTab(id) else { return }
        session.events.withCause(cause) { select(tab, in: session) }
    }

    /// Selects the tab in a window of its Persona only, so that a window of another Persona keeps its Persona / Space, which selecting a favorite's tab of another Persona would change: the window of the Persona that shows it, else the front main window on its space, else the front main window of its Persona, which then shows the tab's space, or for a favorite's tab stays on its own. None selects it without such a window.
    private func select(_ tab: Tab, in session: BrowserSession) {
        let window = session.windows.first { $0.personaID == tab.personaID && $0.shows(tab) }
            ?? session.windows.first { $0.kind == .main && tab.spaceID != nil && $0.currentSpaceID == tab.spaceID }
            ?? session.windows.first { $0.kind == .main && $0.personaID == tab.personaID }
        window?.selectTab(tab.id)
    }

    /// An open tab other than an agent tab, a favorite's among them.
    private func pluginTab(_ id: UUID) -> Tab? {
        guard let tab = session?.allTabs.first(where: { $0.id == id }), BrowserEventSource.kind(of: tab) != .agent else { return nil }
        return tab
    }
}
