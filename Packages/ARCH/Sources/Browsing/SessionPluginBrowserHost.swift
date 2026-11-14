// The session's side of the tab calls of plugins and hook scripts (`docs/plugins.md`, Manager, runtimes, and the browser host): every Persona's open tabs as plugins see them, never agent tabs, and suggested names under the AI hooks' rules (`docs/hooks.md`, hook decision 13), whose events carry the caller's cause. One host serves every Persona's plugin manager and the JavaScript hook runner.
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
}
