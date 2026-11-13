// What the agents' service needs from the browser (docs/agents.md, Parts and modules): Personas, spaces, tabs in sidebar order, the Agents Persona, and a window for the grant sheet. `Browsing` implements it as `BrowserAgentHost`, so that `Agent` depends on neither `Browsing` nor `Plugins`. Later tasks add agent tabs, dialogs, downloads, and permissions.
import AppKit
import ARCHEngine
import Foundation

public struct AgentPersonaInfo: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AgentSpaceInfo: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AgentTabInfo: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var spaceID: UUID?
    /// The title the sidebar shows.
    public var title: String
    public var url: URL?
    public var isLoading: Bool
    public var engine: EngineKind

    public init(id: UUID, spaceID: UUID?, title: String, url: URL?, isLoading: Bool, engine: EngineKind) {
        self.id = id
        self.spaceID = spaceID
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.engine = engine
    }
}

@MainActor public protocol AgentBrowserHost: AnyObject {
    /// Every Persona, in the session's order.
    var personas: [AgentPersonaInfo] { get }
    /// A Persona's spaces in switcher order.
    func spaces(in personaID: UUID) -> [AgentSpaceInfo]
    /// The tabs with these IDs that are open, in sidebar order (`BrowserSession.tabsInSidebarOrder`).
    func tabs(withIDs ids: Set<UUID>) -> [AgentTabInfo]
    /// Adds the Agents Persona, empty and with no sign-ins, and returns its ID.
    func makeAgentsPersona() -> UUID
    /// The Persona whose profiles get no remembered permission answers and whose permission requests are denied without a sheet (agent decision 9), or nil for none.
    func setAgentOnlyPersona(_ id: UUID?)
    /// The front main window, opened if none is, for the grant sheet.
    func windowForSheet() -> NSWindow?
    /// Set by the service; the host calls it after Personas or spaces change, as when the user deletes one.
    var personasDidChange: (() -> Void)? { get set }
    /// The search engine's results address, which every in-app session's site scope holds (docs/agents.md, Site scope and navigation).
    var searchResultsAddress: AgentSearchResultsAddress? { get }
}

public extension AgentBrowserHost {
    var searchResultsAddress: AgentSearchResultsAddress? { nil }
}
