// The browser side of the agents' service (docs/agents.md, Parts and modules): the session's Personas, spaces, and tabs in sidebar order, the Agents Persona, which it adds on demand and keeps agent-only, the front main window for the grant sheet, and the search engine's results address for the sessions' site scope. Later tasks add agent tabs and folders, dialogs, downloads, and permission requests here.
import Agent
import AppKit
import Combine
import Foundation

@MainActor public final class BrowserAgentHost: AgentBrowserHost {
    static let agentsPersonaName = "Agents"

    private unowned let session: BrowserSession
    public var personasDidChange: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    public init(session: BrowserSession) {
        self.session = session
        // On the next turn, once the session has finished a change that touches both lists, as deleting a Persona does.
        session.$personas.combineLatest(session.$spaces)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.personasDidChange?() } }
            .store(in: &cancellables)
    }

    public var personas: [AgentPersonaInfo] {
        session.personas.map { AgentPersonaInfo(id: $0.id, name: $0.name) }
    }

    public func spaces(in personaID: UUID) -> [AgentSpaceInfo] {
        session.spaces(in: personaID).map { AgentSpaceInfo(id: $0.id, name: $0.name) }
    }

    public func tabs(withIDs ids: Set<UUID>) -> [AgentTabInfo] {
        guard !ids.isEmpty else { return [] }
        return session.tabsInSidebarOrder.filter { ids.contains($0.id) }.map(Self.info(of:))
    }

    /// A tab as the agents' service sees it.
    static func info(of tab: Tab) -> AgentTabInfo {
        AgentTabInfo(id: tab.id, spaceID: tab.spaceID, title: tab.displayTitle, url: tab.url, isLoading: tab.isLoading, engine: tab.engineKind)
    }

    /// The results page of the search engine chosen in Settings ▸ General, which takes the terms in `q`.
    public var searchResultsAddress: AgentSearchResultsAddress? {
        AgentSearchResultsAddress(base: SearchEngine.current.resultsURL)
    }

    /// A Persona of its own named Agents, with one space and storage of its own on both engines (Persona rule 2), so it holds no sign-ins.
    public func makeAgentsPersona() -> UUID {
        session.addPersona(named: Self.agentsPersonaName).id
    }

    public func setAgentOnlyPersona(_ id: UUID?) {
        session.agentOnlyPersonaID = id
    }

    public func windowForSheet() -> NSWindow? {
        session.sidebarTarget().nsWindow
    }
}
