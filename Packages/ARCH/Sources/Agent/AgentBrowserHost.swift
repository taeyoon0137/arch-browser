// What the agents' service needs from the browser (docs/agents.md, Parts and modules): Personas, spaces, tabs in sidebar order, the Agents Persona, a window for the grant sheet, the agent tabs with what happens in them, the page script and captures that snapshots, actions, and screenshots use, the user's tabs that `request_tab` offers, the downloads of agent tabs, and the agent panel's place in the windows. `Browsing` implements it as `BrowserAgentHost`, so that `Agent` depends on neither `Browsing` nor `Plugins`.
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
    /// Changes when a different document commits, including a reload of the same address.
    public var documentID: UUID
    public var spaceID: UUID?
    /// The title the sidebar shows.
    public var title: String
    public var url: URL?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var engine: EngineKind
    /// The agent session or outside client's grant whose agent folder holds the tab, or nil for a tab of the user's.
    public var agentOwnerID: UUID?

    public init(id: UUID, spaceID: UUID?, title: String, url: URL?, isLoading: Bool, canGoBack: Bool = false, canGoForward: Bool = false, engine: EngineKind, agentOwnerID: UUID? = nil, documentID: UUID = UUID()) {
        self.id = id
        self.documentID = documentID
        self.spaceID = spaceID
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.engine = engine
        self.agentOwnerID = agentOwnerID
    }

    func showsSameDocument(as other: Self) -> Bool {
        id == other.id && documentID == other.documentID && url == other.url
    }
}

/// Whose agent tabs these are: an outside client's grant, and in-app sessions with plan task VII.17.1 (docs/agents.md, In the browser ▸ Agent folders). Its tabs sit in one agent folder named `folderName` among the open tabs of the space `spaceID`.
public struct AgentTabOwner: Equatable, Sendable {
    /// The grant's or session's ID, which the agent folder keeps as its `agentSessionID`.
    public var id: UUID
    public var spaceID: UUID
    public var folderName: String

    public init(id: UUID, spaceID: UUID, folderName: String) {
        self.id = id
        self.spaceID = spaceID
        self.folderName = folderName
    }
}

public enum AgentNavigation: Equatable, Sendable {
    case load(URL)
    case back
    case forward
    case reload
}

/// What `Browsing` reports from an agent tab for its agent's next result (docs/agents.md, Tools ▸ Results), including what rules P6 and P8 to P11 did there.
public enum AgentTabReport: Equatable, Sendable {
    /// The main frame's address changed: a navigation started or committed a document there, before it finishes loading, or the page changed its address within the document. It is no event of its own; the tool host counts a new page from it.
    case addressChanged(URL?)
    /// The main frame finished loading a document, at this address and title.
    case loaded(url: URL?, title: String)
    /// The tab stopped loading, as when a load finished, failed, or was stopped. It is no event of its own; waits read it.
    case stoppedLoading
    /// A page in the tab opened the tab `tab`, which joined the agent folder in the opener's engine.
    case opened(tab: UUID)
    /// The tab closed other than through `closeAgentTab(_:)`: the user or its page closed it.
    case closed
    /// The user took the tab over, by moving it out of its agent folder or keeping the folder's tabs, so that it is the user's.
    case takenOver
    /// Rule P8 denied a permission request without asking.
    case permissionDenied([EnginePermissionType])
    /// Rule P9: a dialog waits for the user on Arch's own card over the tab, with the page's text and the origin of the frame that shows it, or the site for a sign-in.
    case dialogWaiting(AgentDialogKind, message: String, frame: URL? = nil)
    /// Rule P10 dismissed an alert, with its text and the origin of the frame that showed it.
    case alertDismissed(message: String, frame: URL? = nil)
    /// Rule P6: a page started a download from this address, which waits for the user, since `agentTabMayDownload` did not allow it.
    case downloadAsked(URL)
    /// A download from this address that the user allowed started.
    case downloadStarted(URL)
    /// Rule P11: a page opened this link to another app, which waits for the user.
    case externalAppAsked(URL)
}

public enum AgentDialogKind: String, Equatable, Sendable {
    case confirm
    case prompt
    case leavePage
    case signIn
}

/// A download an agent tab started, as `list_downloads` shows it: no path.
public struct AgentDownloadInfo: Equatable, Sendable {
    public var name: String
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var state: EngineDownloadState

    public init(name: String, completedBytes: Int64, totalBytes: Int64, state: EngineDownloadState) {
        self.name = name
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.state = state
    }
}

/// A page of the browsing history.
public struct AgentHistoryPage: Equatable, Sendable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

@MainActor public protocol AgentBrowserHost: AnyObject {
    /// Every Persona, in the session's order.
    var personas: [AgentPersonaInfo] { get }
    /// A Persona's spaces in switcher order.
    func spaces(in personaID: UUID) -> [AgentSpaceInfo]
    /// The tabs with these IDs that are open, in sidebar order (`BrowserSession.tabsInSidebarOrder`).
    func tabs(withIDs ids: Set<UUID>) -> [AgentTabInfo]
    /// The open tabs of the agent folders whose `agentSessionID` is `ownerID`, in sidebar order.
    func agentTabs(of ownerID: UUID) -> [AgentTabInfo]
    /// Opens a tab at `url` in the background, in `engine` or the default engine, in the owner's agent folder, which it makes among the open tabs of the owner's space when there is none. It selects nothing and switches no window's space. Nil when the space is gone.
    func openAgentTab(at url: URL, engine: EngineKind?, for owner: AgentTabOwner) -> AgentTabInfo?
    /// Opens a background session tab. Before its first page request the host installs the one-use, main-frame address check. While owned it accepts no popups or downloads.
    func openResearchTab(at url: URL, for owner: AgentTabOwner, mayLoad: @escaping @MainActor (URL) -> Bool) -> AgentTabInfo?
    func navigate(_ tabID: UUID, _ navigation: AgentNavigation)
    /// Closes an agent tab without asking its page; it joins neither the closed list nor the tab close log, and reports nothing.
    func closeAgentTab(_ tabID: UUID)
    /// The tab's main frame text through `readableContent(limit:completion:)`, which may never answer while the page shows a dialog.
    func readableContent(of tabID: UUID, limit: Int, completion: @escaping (Result<EngineReadableContent, any Error>) -> Void)
    /// Runs a function expression of the agents' page script in the tab's main frame, in the script world `world`, through `executeJavaScript(_:inWorld:completion:)`. A tab that no window shows gets a viewport of a window's size first, so that its page lays out. It may never answer while the page shows a dialog.
    func runPageScript(_ source: String, world: String, in tabID: UUID, completion: @escaping (Result<String?, any Error>) -> Void)
    /// The tab's viewport, or its whole page, as an image; nil when the engine gives none, as Chromium may for a tab that no window shows.
    func capture(_ tabID: UUID, fullPage: Bool, completion: @escaping (NSImage?) -> Void)
    /// The user's own open tabs of a Persona, without agent tabs, in sidebar order, which `request_tab` offers.
    func userTabs(in personaID: UUID) -> [AgentTabInfo]
    /// Shows the tab in a main window, without moving it out of its folder: for Take Over, `hand_to_user`, and the panel's steps.
    func showTab(_ tabID: UUID)
    /// The downloads the owner's agent tabs started, which the user allowed.
    func agentDownloads(of ownerID: UUID) -> [AgentDownloadInfo]
    /// The name of the app that opens `url`, or nil when none does.
    func appName(forOpening url: URL) -> String?
    /// Opens `url` in the app that handles it, once the user allowed it (P11).
    func openExternally(_ url: URL)
    /// Set by the service: the model of the agent panel, which the host places in the windows' trailing column.
    var agentPanel: AgentPanelModel? { get set }
    /// Shows the agent panel for the owner in the front main window, as when one of its cards waits.
    func showAgentPanel(for ownerID: UUID)
    /// The pages of the browsing history, shared by every Persona, whose address or title contains `query`, most visited first.
    func searchHistory(_ query: String, limit: Int) async -> [AgentHistoryPage]
    /// Adds the Agents Persona, empty and with no sign-ins, and returns its ID.
    func makeAgentsPersona() -> UUID
    /// The Persona whose profiles get no remembered permission answers and whose permission requests are denied without a card (agent decision 9), or nil for none.
    func setAgentOnlyPersona(_ id: UUID?)
    /// The front main window, opened if none is, for the grant sheet.
    func windowForSheet() -> NSWindow?
    /// Set by the service; the host calls it after Personas or spaces change, as when the user deletes one.
    var personasDidChange: (() -> Void)? { get set }
    /// The search engine's results address, which every in-app session's site scope holds (docs/agents.md, Site scope and navigation).
    var searchResultsAddress: AgentSearchResultsAddress? { get }
    /// Set by the service; the host calls it with what happened in an agent tab and the tab's owner, the owner before a take-over for `takenOver`.
    var agentTabDidReport: ((_ ownerID: UUID, _ tabID: UUID, _ report: AgentTabReport) -> Void)? { get set }
    /// Set by the service; the host asks it before each main frame navigation of an agent tab, again before each redirect hop's request, and for the first address of a popup that joins an agent folder. False stops the navigation, or closes the popup.
    var agentTabMayLoad: ((_ ownerID: UUID, _ tabID: UUID, _ url: URL) -> Bool)? { get set }
    /// Set by the service; the host asks it when a page in an agent tab starts a download. False refuses the download, and the tab then reports `downloadAsked` (P6).
    var agentTabMayDownload: ((_ ownerID: UUID, _ tabID: UUID, _ url: URL) -> Bool)? { get set }
}

public extension AgentBrowserHost {
    var searchResultsAddress: AgentSearchResultsAddress? { nil }
}

public extension EnginePermissionType {
    /// The permission as an event names it.
    var agentName: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .geolocation: return "location"
        case .notifications: return "notifications"
        case .clipboard: return "clipboard"
        case .midi: return "MIDI devices"
        case .screenCapture: return "screen recording"
        }
    }
}
