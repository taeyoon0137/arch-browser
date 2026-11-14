// Delivery views: a hook script's and a script plugin's view without titles or causes, with addresses only under `tabs` or a covering grant and none from sites excluded from AI for a hook with `agent`; an outside program's view with handles and reduced addresses for its own and shared tabs, watch IDs and hosts for the user's other tabs, `excluded: true`, downloads only from its own agent tabs, `byThisClient`, and window events with window handles, space handles, and `otherPersona` for the other side.
import AI
import Foundation
import Testing
@testable import Events

// MARK: - Hook scripts and script plugins

@Suite struct BrowserEventScriptViewTests {
    private let load = event(.pageLoaded(tab: tabRef(url: "https://example.org/pricing?plan=team#faq"), isRestore: false, isFirstLoadAfterOpen: true),
                             cause: BrowserEventCause(origin: .hookRun(hook: IDs.hook, run: IDs.run), hookChain: [IDs.hook]))

    @Test func aHookWithTabsSeesTheAddressAndNoCause() throws {
        let view = try #require(load.view(.hook(tabs: true, allowsAI: nil)))
        try expectJSON(view, #"{"id":"00000000-0000-0000-0000-000000000020","kind":"pageLoaded","date":"2026-11-14T09:30:12Z","tab":{"id":"00000000-0000-0000-0000-000000000001","personaId":"00000000-0000-0000-0000-00000000000A","spaceId":"00000000-0000-0000-0000-00000000000C","kind":"open","engine":"chromium","url":"https://example.org/pricing?plan=team#faq"},"isRestore":false,"isFirstLoadAfterOpen":true}"#)
    }

    @Test func aHookWithoutTabsSeesIdentifiersOnly() throws {
        let view = try #require(load.view(.hook(tabs: false, allowsAI: nil)))
        #expect(view.tab?.url == nil)
        #expect(view.tab?.id == IDs.tab)
        #expect(view.tab?.engine == "chromium")
        let moved = try #require(event(.addressChanged(tab: tabRef(engine: .webKit), previousURL: URL(string: "https://example.org/"))).view(.hook(tabs: false, allowsAI: nil)))
        #expect(moved.previousURL == nil)
        #expect(moved.tab?.engine == "webkit")
        let download = try #require(event(.downloadFinished(download: downloadRef())).view(.hook(tabs: false, allowsAI: nil))?.download)
        #expect(download == BrowserEventScriptView.Download(id: IDs.download, personaID: IDs.persona, tabID: IDs.tab))
        let withTabs = try #require(event(.downloadFinished(download: downloadRef())).view(.hook(tabs: true, allowsAI: nil))?.download)
        #expect(withTabs.name == "a1b2.pdf")
        #expect(withTabs.mediaType == "application/pdf")
        #expect(withTabs.byteCount == 2_048)
        #expect(withTabs.sourceURL == URL(string: "https://files.example.net/a1b2.pdf"))
        #expect(withTabs.pageURL == URL(string: "https://example.org/files"))
    }

    @Test func aHookWithAgentGetsNothingFromASiteExcludedFromAI() throws {
        let allowsAI: (URL) -> Bool = { !AISitePattern("example.org").matches($0) }
        #expect(load.view(.hook(tabs: true, allowsAI: allowsAI)) == nil)
        #expect(event(.downloadFinished(download: downloadRef())).view(.hook(tabs: true, allowsAI: allowsAI)) == nil)
        // An event without an address reaches it.
        #expect(event(.tabOpened(tab: tabRef(url: nil), openerTabID: nil)).view(.hook(tabs: true, allowsAI: allowsAI)) != nil)
        // An address that moved off an excluded site leaves the old address out.
        let moved = try #require(event(.addressChanged(tab: tabRef(url: "https://example.com/"), previousURL: URL(string: "https://mail.example.org/inbox"))).view(.hook(tabs: true, allowsAI: allowsAI)))
        #expect(moved.tab?.url == URL(string: "https://example.com/"))
        #expect(moved.previousURL == nil)
        // A hook without `agent` gets every site.
        #expect(load.view(.hook(tabs: true, allowsAI: nil)) != nil)
    }

    @Test func aPluginSeesAddressesWithTabsOrOnTheSitesItsGrantCovers() throws {
        let covers: (URL) -> Bool = { $0.host == "example.org" }
        #expect(load.view(.plugin(tabs: false, downloads: false, covers: covers))?.tab?.url == URL(string: "https://example.org/pricing?plan=team#faq"))
        let other = event(.pageLoaded(tab: tabRef(url: "https://example.com/"), isRestore: false, isFirstLoadAfterOpen: false))
        #expect(other.view(.plugin(tabs: false, downloads: false, covers: covers))?.tab?.url == nil)
        #expect(other.view(.plugin(tabs: true, downloads: false, covers: covers))?.tab?.url == URL(string: "https://example.com/"))
        let download = event(.downloadFinished(download: downloadRef()))
        #expect(download.view(.plugin(tabs: true, downloads: false, covers: covers))?.download?.name == nil)
        #expect(download.view(.plugin(tabs: false, downloads: true, covers: covers))?.download?.name == "a1b2.pdf")
    }

    @Test func eachKindCarriesItsOwnMembers() throws {
        let access = BrowserEventScriptAccess.hook(tabs: true, allowsAI: nil)
        let opened = try #require(event(.tabOpened(tab: tabRef(), openerTabID: IDs.opener)).view(access))
        #expect(opened.openerTabID == IDs.opener)
        #expect(opened.isRestore == nil)
        let closed = try #require(event(.tabClosed(tab: tabRef(), reason: .hook)).view(access))
        #expect(closed.reason == .hook)
        let titled = try #require(event(.titleChanged(tab: tabRef(), source: .suggested)).view(access))
        #expect(titled.source == .suggested)
        let selected = try #require(event(.tabSelected(tab: tabRef(), windowID: IDs.window)).view(access))
        #expect(selected.windowID == IDs.window)
        let switched = try #require(event(.spaceSwitched(windowID: IDs.window, spaceID: IDs.otherPersonaSpace, personaID: IDs.otherPersona, previousSpaceID: IDs.space, previousPersonaID: IDs.persona)).view(access))
        try expectJSON(switched, #"{"id":"00000000-0000-0000-0000-000000000020","kind":"spaceSwitched","date":"2026-11-14T09:30:12Z","windowId":"00000000-0000-0000-0000-00000000000F","spaceId":"00000000-0000-0000-0000-00000000000E","personaId":"00000000-0000-0000-0000-00000000000B","previousSpaceId":"00000000-0000-0000-0000-00000000000C","previousPersonaId":"00000000-0000-0000-0000-00000000000A"}"#)
    }
}

// MARK: - Outside programs

/// A grant in `IDs.persona` with its own agent tab and a shared tab, giving handles on first use as `Agent`'s tables do.
@MainActor
final class TestOutsideReader: BrowserEventOutsideReader {
    let grantID = UUID()
    let personaID = IDs.persona
    var ownTabs: Set<UUID> = []
    var sharedTabs: Set<UUID> = []
    var excludedSites: [AISitePattern] = []
    private var tabs: [UUID: String] = [:]
    private var watches: [UUID: String] = [:]
    private var spaces: [UUID: String] = [:]
    private var windows: [UUID: String] = [:]

    func name(ofTab id: UUID) -> BrowserEventOutsideTab {
        if ownTabs.contains(id) { return .own(Self.handle(id, "t", in: &tabs)) }
        if sharedTabs.contains(id) { return .shared(Self.handle(id, "t", in: &tabs)) }
        return .watched(Self.handle(id, "w", in: &watches))
    }

    func handle(ofSpace id: UUID) -> String { Self.handle(id, "s", in: &spaces) }
    func handle(ofWindow id: UUID) -> String { Self.handle(id, "win", in: &windows) }
    func allowsAI(on url: URL) -> Bool { !excludedSites.contains { $0.matches(url) } }

    private static func handle(_ id: UUID, _ prefix: String, in table: inout [UUID: String]) -> String {
        if let handle = table[id] { return handle }
        let handle = "\(prefix)\(table.count + 1)"
        table[id] = handle
        return handle
    }
}

@MainActor
@Suite struct BrowserEventOutsideViewTests {
    @Test func theUsersOtherTabsShowAWatchIDAndTheHostOnly() throws {
        let reader = TestOutsideReader()
        let view = try #require(event(.pageLoaded(tab: tabRef(url: "https://example.org/pricing?plan=team"), isRestore: false, isFirstLoadAfterOpen: true)).view(reader))
        try expectJSON(view, #"{"seq":7,"kind":"pageLoaded","date":"2026-11-14T09:30:12Z","tab":{"watch":"w1","space":"s1","kind":"open","engine":"chromium","site":"example.org"},"isRestore":false,"isFirstLoadAfterOpen":true}"#)
        // The same tab keeps its watch ID.
        #expect(event(.tabClosed(tab: tabRef(), reason: .user)).view(reader)?.tab?.watch == "w1")
        let moved = try #require(event(.addressChanged(tab: tabRef(url: "https://example.com/a"), previousURL: URL(string: "https://example.org/b?q=1"))).view(reader))
        #expect(moved.tab?.site == "example.com")
        #expect(moved.tab?.url == nil)
        #expect(moved.previousSite == "example.org")
        #expect(moved.previousURL == nil)
    }

    @Test func ownAndSharedTabsShowTheirHandleAndReducedAddress() throws {
        let reader = TestOutsideReader()
        reader.ownTabs = [IDs.tab]
        reader.sharedTabs = [IDs.opener]
        let opened = try #require(event(.tabOpened(tab: tabRef(kind: .agent, url: "https://me:pw@example.org/search?q=private#top"), openerTabID: IDs.opener)).view(reader))
        #expect(opened.tab?.handle == "t1")
        #expect(opened.tab?.watch == nil)
        #expect(opened.tab?.kind == .agent)
        #expect(opened.tab?.url == URL(string: "https://example.org/search"))
        #expect(opened.tab?.site == nil)
        #expect(opened.opener == "t2")
        let moved = try #require(event(.addressChanged(tab: tabRef(id: IDs.opener), previousURL: URL(string: "https://example.org/a?b=c"))).view(reader))
        #expect(moved.tab?.handle == "t2")
        #expect(moved.previousURL == URL(string: "https://example.org/a"))
    }

    @Test func excludedSitesShowNeitherHostNorAddress() throws {
        let reader = TestOutsideReader()
        reader.ownTabs = [IDs.tab]
        reader.excludedSites = [AISitePattern("example.org")]
        let own = try #require(event(.pageLoaded(tab: tabRef(), isRestore: false, isFirstLoadAfterOpen: false)).view(reader))
        #expect(own.tab?.excluded == true)
        #expect(own.tab?.url == nil)
        let watched = try #require(event(.addressChanged(tab: tabRef(id: IDs.opener, url: "https://mail.example.org/"), previousURL: URL(string: "https://example.org/x"))).view(reader))
        try expectJSON(watched, #"{"seq":7,"kind":"addressChanged","date":"2026-11-14T09:30:12Z","tab":{"watch":"w1","space":"s1","kind":"open","engine":"chromium","excluded":true}}"#)
    }

    @Test func otherPersonasTabsDoNotReachTheGrant() {
        let reader = TestOutsideReader()
        #expect(event(.pageLoaded(tab: tabRef(persona: IDs.otherPersona), isRestore: false, isFirstLoadAfterOpen: false)).view(reader) == nil)
        #expect(event(.tabSelected(tab: tabRef(persona: IDs.otherPersona), windowID: IDs.window)).view(reader) == nil)
    }

    @Test func downloadsReachTheGrantOnlyFromItsOwnAgentTabs() throws {
        let reader = TestOutsideReader()
        reader.sharedTabs = [IDs.tab]
        #expect(event(.downloadFinished(download: downloadRef())).view(reader) == nil)
        #expect(event(.downloadFinished(download: downloadRef(tab: nil))).view(reader) == nil)
        reader.ownTabs = [IDs.tab]
        let view = try #require(event(.downloadFinished(download: downloadRef())).view(reader))
        try expectJSON(view, #"{"seq":7,"kind":"downloadFinished","date":"2026-11-14T09:30:12Z","download":{"name":"<untrusted source=\"page\">a1b2.pdf</untrusted>","mediaType":"application/pdf","byteCount":2048,"site":"files.example.net","tab":"t1"}}"#)
        #expect(event(.downloadFinished(download: downloadRef(persona: IDs.otherPersona))).view(reader) == nil)
        reader.excludedSites = [AISitePattern("example.org")]
        let excluded = try #require(event(.downloadFinished(download: downloadRef())).view(reader)?.download)
        #expect(excluded == BrowserEventOutsideView.Download(mediaType: "application/pdf", byteCount: 2_048, tab: "t1", excluded: true))
    }

    @Test func theClientsOwnActionsAreMarked() throws {
        let reader = TestOutsideReader()
        let ownAction = event(.titleChanged(tab: tabRef(), source: .suggested), cause: BrowserEventCause(origin: .outsideClient(grant: reader.grantID)))
        #expect(try #require(ownAction.view(reader)).byThisClient == true)
        let otherClient = event(.titleChanged(tab: tabRef(), source: .suggested), cause: BrowserEventCause(origin: .outsideClient(grant: UUID())))
        #expect(try #require(otherClient.view(reader)).byThisClient == nil)
        #expect(try #require(event(.titleChanged(tab: tabRef(), source: .page)).view(reader)).byThisClient == nil)
    }

    @Test func aSelectionShowsTheWindowHandle() throws {
        let reader = TestOutsideReader()
        let view = try #require(event(.tabSelected(tab: tabRef(), windowID: IDs.window)).view(reader))
        try expectJSON(view, #"{"seq":7,"kind":"tabSelected","date":"2026-11-14T09:30:12Z","tab":{"watch":"w1","space":"s1","kind":"open","engine":"chromium","site":"example.org"},"window":"win1"}"#)
    }

    @Test func aSpaceSwitchReachesTheGrantOnlyWithItsPersonaOnOneSide() throws {
        let reader = TestOutsideReader()
        let within = try #require(event(.spaceSwitched(windowID: IDs.window, spaceID: IDs.secondSpace, personaID: IDs.persona, previousSpaceID: IDs.space, previousPersonaID: IDs.persona)).view(reader))
        try expectJSON(within, #"{"seq":7,"kind":"spaceSwitched","date":"2026-11-14T09:30:12Z","window":"win1","to":{"space":"s1"},"from":{"space":"s2"}}"#)
        let leaving = try #require(event(.spaceSwitched(windowID: IDs.window, spaceID: IDs.otherPersonaSpace, personaID: IDs.otherPersona, previousSpaceID: IDs.space, previousPersonaID: IDs.persona)).view(reader))
        #expect(leaving.to == BrowserEventOutsideView.Side(otherPersona: true))
        #expect(leaving.from == BrowserEventOutsideView.Side(space: "s2"))
        let entering = try #require(event(.spaceSwitched(windowID: UUID(), spaceID: IDs.space, personaID: IDs.persona, previousSpaceID: IDs.otherPersonaSpace, previousPersonaID: IDs.otherPersona)).view(reader))
        try expectJSON(entering, #"{"seq":7,"kind":"spaceSwitched","date":"2026-11-14T09:30:12Z","window":"win2","to":{"space":"s2"},"from":{"otherPersona":true}}"#)
        #expect(event(.spaceSwitched(windowID: IDs.window, spaceID: IDs.otherPersonaSpace, personaID: IDs.otherPersona, previousSpaceID: UUID(), previousPersonaID: IDs.otherPersona)).view(reader) == nil)
    }
}
