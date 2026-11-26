// The browser side of the hook registry (`docs/hooks.md`, Hook registry): the session's Personas and spaces for filters, its tabs as the bus describes them, and a closing tab's last name and address for close runs. It never lists agent tabs.
import Agent
import Combine
import Events
import Foundation
import Hooks

/// Adapts the session's user tabs and places to the hook registry.
@MainActor public final class BrowserHookHost: HookBrowserHost {
    private unowned let session: BrowserSession
    public var placesDidChange: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    /// Watches Persona and space changes and notifies the hook registry after they settle.
    public init(session: BrowserSession) {
        self.session = session
        // On the next turn, once the session has finished a change that touches both lists, as deleting a Persona does.
        session.$personas.combineLatest(session.$spaces)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.placesDidChange?() } }
            .store(in: &cancellables)
    }

    public var places: [HookPersonaPlaces] {
        session.personas.map { persona in
            HookPersonaPlaces(id: persona.id, name: persona.name, spaces: session.spaces(in: persona.id).map { HookSpace(id: $0.id, name: $0.name) })
        }
    }

    /// Returns the event-facing facts for an open tab.
    public func tab(_ id: UUID) -> BrowserTabRef? {
        session.allTabs.first { $0.id == id && !$0.isPrivate }.map(Self.ref)
    }

    /// Returns the Persona's sidebar tabs in order, excluding agent tabs.
    public func tabs(inPersona id: UUID) -> [BrowserTabRef] {
        session.tabsInSidebarOrder.filter { $0.personaID == id && !$0.isPrivate }.map(Self.ref).filter { $0.kind != .agent }
    }

    /// The session posts `tabClosed` while it still lists the tab, so during that delivery this is the closing tab's last name and committed address.
    public func closingTab(_ id: UUID) -> AgentRunClosedTab? {
        session.allTabs.first { $0.id == id && !$0.isPrivate }.map { AgentRunClosedTab(name: $0.displayTitle, url: $0.committedURL) }
    }

    /// The tab as `BrowserEventSource` describes it in events: with its committed address, not the address a WebKit navigation shows before it commits, so a run's documents and site checks follow the page the tab shows.
    static func ref(_ tab: Tab) -> BrowserTabRef {
        BrowserTabRef(id: tab.id, personaID: tab.personaID, spaceID: tab.spaceID, kind: BrowserEventSource.kind(of: tab), engine: tab.engineKind, url: tab.committedURL, documentID: tab.documentID)
    }
}
