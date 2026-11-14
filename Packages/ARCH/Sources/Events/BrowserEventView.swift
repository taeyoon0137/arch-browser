// Delivery views (`docs/hooks.md`, Delivery views): each consumer sees an event through the view its access allows, and `BrowserEvent.view(_:)` makes every view, so the rules have one implementation. Arch's own code (`BrowserHooks`, the hook registry, the agent service) reads the event itself. A view never carries a title, which events do not hold, or a cause, except an outside program's `byThisClient`.
import AgentControl
import ARCHEngine
import Foundation

extension EngineKind {
    /// The engine as views name it: `webkit` or `chromium`, as `arch-cli` and the agent tools do.
    var viewName: String { rawValue.lowercased() }
}

// MARK: - Hook scripts and script plugins

/// What a hook script or a script plugin may see of an event.
public struct BrowserEventScriptAccess {
    /// Whether a tab's address shows.
    public var showsAddress: (URL) -> Bool
    /// Whether a download shows its name, type, size, and addresses; otherwise it shows its identifiers only.
    public var showsDownloadDetails: Bool
    /// For a consumer that can reach a model, a hook with `agent`: whether AI may receive data from an address. An event with an address it refuses never reaches the consumer, and a refused previous address stays out (hook decision 14). nil for every other consumer.
    public var allowsAI: ((URL) -> Bool)?

    public init(showsAddress: @escaping (URL) -> Bool, showsDownloadDetails: Bool, allowsAI: ((URL) -> Bool)?) {
        self.showsAddress = showsAddress
        self.showsDownloadDetails = showsDownloadDetails
        self.allowsAI = allowsAI
    }

    /// A hook script: addresses and download details with `tabs`. A hook with `agent` passes the AI interface's site check as `allowsAI`.
    public static func hook(tabs: Bool, allowsAI: ((URL) -> Bool)?) -> Self {
        Self(showsAddress: { _ in tabs }, showsDownloadDetails: tabs, allowsAI: allowsAI)
    }

    /// A script plugin: addresses with `tabs` or on the pages its granted sites cover, as with plugin tabs, and download details with `downloads`.
    public static func plugin(tabs: Bool, downloads: Bool, covers: @escaping (URL) -> Bool) -> Self {
        Self(showsAddress: { tabs || covers($0) }, showsDownloadDetails: downloads, allowsAI: nil)
    }
}

/// An event as a hook script or a script plugin receives it, as JSON with camel-case keys such as `personaId`. Members that do not apply to the event's kind are absent.
public struct BrowserEventScriptView: Codable, Hashable, Sendable {
    public struct Tab: Codable, Hashable, Sendable {
        public var id: UUID
        public var personaID: UUID
        public var spaceID: UUID?
        public var kind: BrowserTabKind
        public var engine: String
        public var url: URL?

        enum CodingKeys: String, CodingKey {
            case id, personaID = "personaId", spaceID = "spaceId", kind, engine, url
        }
    }

    public struct Download: Codable, Hashable, Sendable {
        public var id: UUID
        public var personaID: UUID
        public var tabID: UUID?
        public var name: String?
        public var mediaType: String?
        public var byteCount: Int64?
        public var sourceURL: URL?
        public var pageURL: URL?

        enum CodingKeys: String, CodingKey {
            case id, personaID = "personaId", tabID = "tabId", name, mediaType, byteCount, sourceURL = "sourceUrl", pageURL = "pageUrl"
        }
    }

    public var id: UUID
    public var kind: BrowserEventKind
    public var date: Date
    public var tab: Tab?
    public var download: Download?
    public var openerTabID: UUID?
    public var reason: BrowserTabCloseReason?
    public var isRestore: Bool?
    public var isFirstLoadAfterOpen: Bool?
    public var previousURL: URL?
    public var source: BrowserTitleSource?
    public var windowID: UUID?
    /// For `spaceSwitched`: the space the window switched to, its Persona, and the space and Persona before.
    public var spaceID: UUID?
    public var personaID: UUID?
    public var previousSpaceID: UUID?
    public var previousPersonaID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, kind, date, tab, download, openerTabID = "openerTabId", reason, isRestore, isFirstLoadAfterOpen, previousURL = "previousUrl", source,
             windowID = "windowId", spaceID = "spaceId", personaID = "personaId", previousSpaceID = "previousSpaceId", previousPersonaID = "previousPersonaId"
    }

    init(id: UUID, kind: BrowserEventKind, date: Date) {
        self.id = id
        self.kind = kind
        self.date = date
    }
}

extension BrowserEvent {
    /// The event as a hook script or a script plugin sees it, or nil when it does not reach that consumer: a consumer with `allowsAI` gets no event from an address it refuses.
    public func view(_ access: BrowserEventScriptAccess) -> BrowserEventScriptView? {
        if let allowsAI = access.allowsAI, !urls.allSatisfy(allowsAI) { return nil }
        func address(_ url: URL?) -> URL? {
            guard let url, access.showsAddress(url), access.allowsAI?(url) ?? true else { return nil }
            return url
        }
        func tabView(_ tab: BrowserTabRef) -> BrowserEventScriptView.Tab {
            BrowserEventScriptView.Tab(id: tab.id, personaID: tab.personaID, spaceID: tab.spaceID, kind: tab.kind, engine: tab.engine.viewName, url: address(tab.url))
        }
        var view = BrowserEventScriptView(id: id, kind: kind, date: date)
        switch payload {
        case .tabOpened(let tab, let openerTabID):
            view.tab = tabView(tab)
            view.openerTabID = openerTabID
        case .tabClosed(let tab, let reason):
            view.tab = tabView(tab)
            view.reason = reason
        case .pageLoaded(let tab, let isRestore, let isFirstLoadAfterOpen):
            view.tab = tabView(tab)
            view.isRestore = isRestore
            view.isFirstLoadAfterOpen = isFirstLoadAfterOpen
        case .addressChanged(let tab, let previousURL):
            view.tab = tabView(tab)
            view.previousURL = address(previousURL)
        case .titleChanged(let tab, let source):
            view.tab = tabView(tab)
            view.source = source
        case .tabSelected(let tab, let windowID):
            view.tab = tabView(tab)
            view.windowID = windowID
        case .downloadFinished(let download):
            var shown = BrowserEventScriptView.Download(id: download.id, personaID: download.personaID, tabID: download.tabID)
            if access.showsDownloadDetails {
                shown.name = download.filename
                shown.mediaType = download.mediaType
                shown.byteCount = download.byteCount
                shown.sourceURL = download.sourceURL
                shown.pageURL = download.pageURL
            }
            view.download = shown
        case .spaceSwitched(let windowID, let spaceID, let personaID, let previousSpaceID, let previousPersonaID):
            view.windowID = windowID
            view.spaceID = spaceID
            view.personaID = personaID
            view.previousSpaceID = previousSpaceID
            view.previousPersonaID = previousPersonaID
        }
        return view
    }
}

// MARK: - Outside programs

/// How an outside program's grant names a tab (`docs/hooks.md`, Delivery views).
public enum BrowserEventOutsideTab: Hashable, Sendable {
    /// One of the client's own agent tabs, by its handle, such as `t1`.
    case own(String)
    /// A tab shared with the client, by its handle.
    case shared(String)
    /// One of the user's other tabs in the grant's Persona, by its watch ID, such as `w4`, which no tool accepts.
    case watched(String)
}

/// What an outside program's view needs from the grant it is for. `Agent` implements it over the grant's handle tables, which give each handle and watch ID on first use and never reuse one while Arch runs.
@MainActor
public protocol BrowserEventOutsideReader: AnyObject {
    var grantID: UUID { get }
    /// The grant's Persona, the only one whose events reach it.
    var personaID: UUID { get }
    func name(ofTab id: UUID) -> BrowserEventOutsideTab
    /// `s1`, `s2`, and so on, as the agent tools name spaces.
    func handle(ofSpace id: UUID) -> String
    /// `win1`, `win2`, and so on.
    func handle(ofWindow id: UUID) -> String
    /// The AI interface's site check: an address it refuses shows neither its host nor its path.
    func allowsAI(on url: URL) -> Bool
}

/// An event as an outside program with the events scope receives it: one JSON line of `arch-cli events --json`, or one entry of `watch_events`.
public struct BrowserEventOutsideView: Codable, Hashable, Sendable {
    public struct Tab: Codable, Hashable, Sendable {
        /// The handle of the client's own agent tab or a tab shared with it.
        public var handle: String?
        /// The watch ID of one of the user's other tabs.
        public var watch: String?
        public var space: String?
        public var kind: BrowserTabKind
        public var engine: String
        /// A handled tab's address without its query, fragment, user name, and password.
        public var url: URL?
        /// A watched tab's host.
        public var site: String?
        /// The tab's address is on a site excluded from AI, so neither its host nor its address shows.
        public var excluded: Bool?
    }

    /// A download started by one of the client's own agent tabs.
    public struct Download: Codable, Hashable, Sendable {
        /// The file's name as an untrusted block, since the server or the page chose it.
        public var name: String?
        public var mediaType: String?
        public var byteCount: Int64?
        /// The source's host.
        public var site: String?
        /// The handle of the agent tab it started from.
        public var tab: String
        public var excluded: Bool?
    }

    /// One side of a space switch: a space of the grant's Persona by its handle, or another Persona without an identifier.
    public struct Side: Codable, Hashable, Sendable {
        public var space: String?
        public var otherPersona: Bool?
    }

    public var sequence: UInt64
    public var kind: BrowserEventKind
    public var date: Date
    public var tab: Tab?
    public var download: Download?
    /// The opening tab's handle or watch ID.
    public var opener: String?
    public var reason: BrowserTabCloseReason?
    public var isRestore: Bool?
    public var isFirstLoadAfterOpen: Bool?
    /// A handled tab's previous address, reduced.
    public var previousURL: URL?
    /// A watched tab's previous host.
    public var previousSite: String?
    public var source: BrowserTitleSource?
    public var window: String?
    /// For `spaceSwitched`: where the window went, and where it was.
    public var to: Side?
    public var from: Side?
    /// The client's own action caused the event.
    public var byThisClient: Bool?

    enum CodingKeys: String, CodingKey {
        case sequence = "seq", kind, date, tab, download, opener, reason, isRestore, isFirstLoadAfterOpen, previousURL = "previousUrl", previousSite, source, window, to, from, byThisClient
    }

    init(sequence: UInt64, kind: BrowserEventKind, date: Date) {
        self.sequence = sequence
        self.kind = kind
        self.date = date
    }
}

extension BrowserEvent {
    /// The event as the outside program with `reader`'s grant sees it, or nil when it does not reach the grant: tab events of its Persona, `spaceSwitched` with its Persona on one side, and downloads its own agent tabs started.
    @MainActor
    public func view(_ reader: some BrowserEventOutsideReader) -> BrowserEventOutsideView? {
        var view = BrowserEventOutsideView(sequence: sequence, kind: kind, date: date)
        if case .outsideClient(let grant) = cause?.origin, grant == reader.grantID { view.byThisClient = true }
        if let tab {
            guard tab.personaID == reader.personaID else { return nil }
            let name = reader.name(ofTab: tab.id)
            view.tab = Self.outsideTab(tab, named: name, reader: reader)
            switch payload {
            case .tabOpened(_, let openerTabID):
                view.opener = openerTabID.map { Self.label(reader.name(ofTab: $0)) }
            case .tabClosed(_, let reason):
                view.reason = reason
            case .pageLoaded(_, let isRestore, let isFirstLoadAfterOpen):
                view.isRestore = isRestore
                view.isFirstLoadAfterOpen = isFirstLoadAfterOpen
            case .addressChanged(_, let previousURL):
                guard let previousURL, reader.allowsAI(on: previousURL) else { break }
                if case .watched = name {
                    view.previousSite = previousURL.host
                } else {
                    view.previousURL = AgentAddress.reduced(previousURL)
                }
            case .titleChanged(_, let source):
                view.source = source
            case .tabSelected(_, let windowID):
                view.window = reader.handle(ofWindow: windowID)
            case .downloadFinished, .spaceSwitched:
                break
            }
            return view
        }
        switch payload {
        case .downloadFinished(let download):
            guard download.personaID == reader.personaID, let tabID = download.tabID, case .own(let handle) = reader.name(ofTab: tabID) else { return nil }
            var shown = BrowserEventOutsideView.Download(mediaType: download.mediaType, byteCount: download.byteCount, tab: handle)
            if urls.allSatisfy(reader.allowsAI(on:)) {
                shown.name = AgentUntrusted.wrap(download.filename, url: nil)
                shown.site = download.sourceURL?.host
            } else {
                shown.excluded = true
            }
            view.download = shown
        case .spaceSwitched(let windowID, let spaceID, let personaID, let previousSpaceID, let previousPersonaID):
            guard personaID == reader.personaID || previousPersonaID == reader.personaID else { return nil }
            view.window = reader.handle(ofWindow: windowID)
            view.to = Self.side(spaceID, in: personaID, reader: reader)
            view.from = previousSpaceID.map { Self.side($0, in: previousPersonaID, reader: reader) }
        default:
            return nil
        }
        return view
    }

    @MainActor
    private static func outsideTab(_ tab: BrowserTabRef, named name: BrowserEventOutsideTab, reader: some BrowserEventOutsideReader) -> BrowserEventOutsideView.Tab {
        var shown = BrowserEventOutsideView.Tab(space: tab.spaceID.map(reader.handle(ofSpace:)), kind: tab.kind, engine: tab.engine.viewName)
        switch name {
        case .own(let handle), .shared(let handle): shown.handle = handle
        case .watched(let watch): shown.watch = watch
        }
        guard let url = tab.url else { return shown }
        guard reader.allowsAI(on: url) else {
            shown.excluded = true
            return shown
        }
        if case .watched = name {
            shown.site = url.host
        } else {
            shown.url = AgentAddress.reduced(url)
        }
        return shown
    }

    private static func label(_ name: BrowserEventOutsideTab) -> String {
        switch name {
        case .own(let handle), .shared(let handle), .watched(let handle): return handle
        }
    }

    @MainActor
    private static func side(_ spaceID: UUID, in personaID: UUID?, reader: some BrowserEventOutsideReader) -> BrowserEventOutsideView.Side {
        personaID == reader.personaID ? BrowserEventOutsideView.Side(space: reader.handle(ofSpace: spaceID)) : BrowserEventOutsideView.Side(otherPersona: true)
    }
}
