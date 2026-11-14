// Browser events (`docs/hooks.md`, Browser events): what happened to a tab, a download, or a window, as `BrowserEventSource` in `Browsing` posts it to the bus. Events carry identifiers, kinds, engines, reasons, and addresses, never page text, titles, or file paths (hook decision 2).
import ARCHEngine
import Foundation

public enum BrowserEventKind: String, Codable, Hashable, Sendable, CaseIterable {
    case tabOpened, tabClosed, pageLoaded, addressChanged, titleChanged, tabSelected, downloadFinished, spaceSwitched
}

public enum BrowserTabKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// A space's tab outside its pinned list.
    case open
    case pinned
    /// A favorite's tab, which belongs to no space.
    case favorite
    case smallWindow
    /// A tab in an agent folder (`docs/agents.md`, Agent folders). Hooks and the AI hook center never see these.
    case agent
}

public struct BrowserTabRef: Codable, Hashable, Sendable {
    public var id: UUID
    public var personaID: UUID
    /// nil for a favorite's tab.
    public var spaceID: UUID?
    public var kind: BrowserTabKind
    public var engine: EngineKind
    /// The committed address; nil until the engine reports one.
    public var url: URL?

    public init(id: UUID, personaID: UUID, spaceID: UUID?, kind: BrowserTabKind, engine: EngineKind, url: URL?) {
        self.id = id
        self.personaID = personaID
        self.spaceID = spaceID
        self.kind = kind
        self.engine = engine
        self.url = url
    }
}

public struct BrowserDownloadRef: Codable, Hashable, Sendable {
    public var id: UUID
    public var personaID: UUID
    /// The tab the download started from, while that tab is open.
    public var tabID: UUID?
    /// The file's name, which the server or the page chose; never its folder or contents.
    public var filename: String
    public var mediaType: String?
    public var byteCount: Int64?
    public var sourceURL: URL?
    public var pageURL: URL?
    /// The user chose the name in a save panel.
    public var isNamedByUser: Bool
    /// The source tab's kind when the download started, including after the user takes over or closes the tab. Nil for an unknown source.
    public var tabKind: BrowserTabKind?

    public init(id: UUID, personaID: UUID, tabID: UUID?, filename: String, mediaType: String?, byteCount: Int64?, sourceURL: URL?, pageURL: URL?, isNamedByUser: Bool,
                tabKind: BrowserTabKind? = nil) {
        self.id = id
        self.personaID = personaID
        self.tabID = tabID
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.isNamedByUser = isNamedByUser
        self.tabKind = tabKind
    }
}

public enum BrowserTabCloseReason: String, CaseIterable, Codable, Hashable, Sendable {
    /// `TabCloseReason`'s cases, then closes by code and with a deleted space or Persona.
    case user, page, crash, archive, download, webExtension, plugin, hook, agent, spaceDeleted
}

public enum BrowserTitleSource: String, Codable, Hashable, Sendable {
    /// The page's own title, or the host that stands in for a page without one, also when another address drops a hook's name.
    case page
    /// The user named the tab or cleared its name (`Tab.customTitle`), or turned down a hook's name.
    case user
    /// A hook, plugin, or agent named the tab (`Tab.suggestedTitle`).
    case suggested
}

/// The labels name each value, so the synthesized JSON reads `{"pageLoaded":{"tab":{…},"isRestore":false,…}}`.
public enum BrowserEventPayload: Codable, Hashable, Sendable {
    case tabOpened(tab: BrowserTabRef, openerTabID: UUID?)
    /// Posted while the session still lists the tab, so a consumer can read its last name and address during delivery.
    case tabClosed(tab: BrowserTabRef, reason: BrowserTabCloseReason)
    /// `isRestore`: the first load of a tab restored from the saved session or of a pinned tab that a browser import opened. `isFirstLoadAfterOpen`: the tab's first load with an `http` or `https` address since this launch's `tabOpened` for it.
    case pageLoaded(tab: BrowserTabRef, isRestore: Bool, isFirstLoadAfterOpen: Bool)
    case addressChanged(tab: BrowserTabRef, previousURL: URL?)
    case titleChanged(tab: BrowserTabRef, source: BrowserTitleSource)
    case tabSelected(tab: BrowserTabRef, windowID: UUID)
    case downloadFinished(download: BrowserDownloadRef)
    /// `previousPersonaID` differs from `personaID` when the Persona changes with the space.
    case spaceSwitched(windowID: UUID, spaceID: UUID, personaID: UUID, previousSpaceID: UUID?, previousPersonaID: UUID?)
}

public struct BrowserEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// One more than the previous event's in this launch; outside programs resume after it.
    public var sequence: UInt64
    public var date: Date
    public var payload: BrowserEventPayload
    /// What made the change, when code made it (Causes).
    public var cause: BrowserEventCause?

    public init(id: UUID, sequence: UInt64, date: Date, payload: BrowserEventPayload, cause: BrowserEventCause?) {
        self.id = id
        self.sequence = sequence
        self.date = date
        self.payload = payload
        self.cause = cause
    }

    public var kind: BrowserEventKind {
        switch payload {
        case .tabOpened: return .tabOpened
        case .tabClosed: return .tabClosed
        case .pageLoaded: return .pageLoaded
        case .addressChanged: return .addressChanged
        case .titleChanged: return .titleChanged
        case .tabSelected: return .tabSelected
        case .downloadFinished: return .downloadFinished
        case .spaceSwitched: return .spaceSwitched
        }
    }

    /// The tab of a tab event; nil for downloads and space switches.
    public var tab: BrowserTabRef? {
        switch payload {
        case .tabOpened(let tab, _), .tabClosed(let tab, _), .pageLoaded(let tab, _, _), .addressChanged(let tab, _), .titleChanged(let tab, _), .tabSelected(let tab, _):
            return tab
        case .downloadFinished, .spaceSwitched:
            return nil
        }
    }

    /// The tab, download, or window the event is about.
    public var subject: UUID {
        switch payload {
        case .downloadFinished(let download): return download.id
        case .spaceSwitched(let windowID, _, _, _, _): return windowID
        case .tabOpened(let tab, _), .tabClosed(let tab, _), .pageLoaded(let tab, _, _), .addressChanged(let tab, _), .titleChanged(let tab, _), .tabSelected(let tab, _):
            return tab.id
        }
    }

    /// For `spaceSwitched`, the Persona of the space the window switched to.
    public var personaID: UUID {
        switch payload {
        case .downloadFinished(let download): return download.personaID
        case .spaceSwitched(_, _, let personaID, _, _): return personaID
        case .tabOpened(let tab, _), .tabClosed(let tab, _), .pageLoaded(let tab, _, _), .addressChanged(let tab, _), .titleChanged(let tab, _), .tabSelected(let tab, _):
            return tab.personaID
        }
    }

    /// The space the event belongs to: the tab's, or for `spaceSwitched` the one the window switched to. nil for a favorite's tab and for downloads, which belong to their Persona only.
    public var spaceID: UUID? {
        if case .spaceSwitched(_, let spaceID, _, _, _) = payload { return spaceID }
        return tab?.spaceID
    }

    /// The addresses that site filters and exclusions apply to: the tab's, or the download's source and page.
    public var urls: [URL] {
        if case .downloadFinished(let download) = payload { return [download.sourceURL, download.pageURL].compactMap { $0 } }
        return tab?.url.map { [$0] } ?? []
    }
}

/// What made a change, when code made it. Every event that code causes names the hooks whose runs led to it, so loop protection can stop a hook from running for its own effects (hook decision 9).
public struct BrowserEventCause: Codable, Hashable, Sendable {
    public enum Origin: Codable, Hashable, Sendable {
        case hookRun(hook: UUID, run: UUID)
        case agentSession(id: UUID)
        case outsideClient(grant: UUID)
        case plugin(id: String)
    }

    public var origin: Origin
    /// The hooks whose runs led to this change, oldest first, at most three.
    public var hookChain: [UUID]

    public init(origin: Origin, hookChain: [UUID] = []) {
        self.origin = origin
        self.hookChain = hookChain
    }
}
