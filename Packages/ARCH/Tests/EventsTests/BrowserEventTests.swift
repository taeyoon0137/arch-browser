// Browser events: each payload's JSON against fixed text, `kind`, `subject`, `personaID`, `spaceID`, and `urls` for every case, filters by kind, scope, sites, engines, and tab kinds with their JSON, and the bus's delivery order, sequence, causes, and subscriptions.
import AI
import ARCHEngine
import Foundation
import Testing
@testable import Events

// MARK: - Fixtures

enum IDs {
    static let persona = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let otherPersona = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let space = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let secondSpace = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
    static let otherPersonaSpace = UUID(uuidString: "00000000-0000-0000-0000-00000000000E")!
    static let window = UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!
    static let tab = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let opener = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let download = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    static let event = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    static let hook = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
    static let run = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
}

func tabRef(id: UUID = IDs.tab, persona: UUID = IDs.persona, space: UUID? = IDs.space, kind: BrowserTabKind = .open, engine: EngineKind = .chromium,
            url: String? = "https://example.org/pricing") -> BrowserTabRef {
    BrowserTabRef(id: id, personaID: persona, spaceID: space, kind: kind, engine: engine, url: url.map { URL(string: $0)! })
}

func downloadRef(tab: UUID? = IDs.tab, persona: UUID = IDs.persona, source: String = "https://files.example.net/a1b2.pdf", page: String = "https://example.org/files") -> BrowserDownloadRef {
    BrowserDownloadRef(id: IDs.download, personaID: persona, tabID: tab, filename: "a1b2.pdf", mediaType: "application/pdf", byteCount: 2_048,
                       sourceURL: URL(string: source)!, pageURL: URL(string: page)!, isNamedByUser: false)
}

func event(_ payload: BrowserEventPayload, sequence: UInt64 = 7, cause: BrowserEventCause? = nil) -> BrowserEvent {
    BrowserEvent(id: IDs.event, sequence: sequence, date: Date(timeIntervalSince1970: 1_794_648_612), payload: payload, cause: cause)
}

/// Compares the value's JSON with the text as parsed objects, so key order does not matter, and decodes the text back to the value.
func expectJSON<T: Codable & Equatable>(_ value: T, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoded = try JSONSerialization.jsonObject(with: encoder.encode(value)) as? NSObject
    let expected = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSObject
    #expect(encoded == expected, sourceLocation: sourceLocation)
    #expect(try decoder.decode(T.self, from: Data(text.utf8)) == value, sourceLocation: sourceLocation)
}

let tabJSON = #"{"id":"00000000-0000-0000-0000-000000000001","personaID":"00000000-0000-0000-0000-00000000000A","spaceID":"00000000-0000-0000-0000-00000000000C","kind":"open","engine":"chromium","url":"https:\/\/example.org\/pricing"}"#

// MARK: - Payloads

@Suite struct BrowserEventPayloadTests {
    @Test func eachPayloadHasFixedJSON() throws {
        try expectJSON(BrowserEventPayload.tabOpened(tab: tabRef(), openerTabID: IDs.opener),
                       #"{"tabOpened":{"tab":\#(tabJSON),"openerTabID":"00000000-0000-0000-0000-000000000002"}}"#)
        try expectJSON(BrowserEventPayload.tabOpened(tab: tabRef(url: nil), openerTabID: nil),
                       #"{"tabOpened":{"tab":{"id":"00000000-0000-0000-0000-000000000001","personaID":"00000000-0000-0000-0000-00000000000A","spaceID":"00000000-0000-0000-0000-00000000000C","kind":"open","engine":"chromium"}}}"#)
        try expectJSON(BrowserEventPayload.tabClosed(tab: tabRef(), reason: .spaceDeleted), #"{"tabClosed":{"tab":\#(tabJSON),"reason":"spaceDeleted"}}"#)
        try expectJSON(BrowserEventPayload.pageLoaded(tab: tabRef(), isRestore: false, isFirstLoadAfterOpen: true),
                       #"{"pageLoaded":{"tab":\#(tabJSON),"isRestore":false,"isFirstLoadAfterOpen":true}}"#)
        try expectJSON(BrowserEventPayload.addressChanged(tab: tabRef(), previousURL: URL(string: "https://example.org/")),
                       #"{"addressChanged":{"tab":\#(tabJSON),"previousURL":"https:\/\/example.org\/"}}"#)
        try expectJSON(BrowserEventPayload.titleChanged(tab: tabRef(), source: .suggested), #"{"titleChanged":{"tab":\#(tabJSON),"source":"suggested"}}"#)
        try expectJSON(BrowserEventPayload.tabSelected(tab: tabRef(), windowID: IDs.window),
                       #"{"tabSelected":{"tab":\#(tabJSON),"windowID":"00000000-0000-0000-0000-00000000000F"}}"#)
        try expectJSON(BrowserEventPayload.downloadFinished(download: downloadRef()),
                       #"{"downloadFinished":{"download":{"id":"00000000-0000-0000-0000-000000000010","personaID":"00000000-0000-0000-0000-00000000000A","tabID":"00000000-0000-0000-0000-000000000001","filename":"a1b2.pdf","mediaType":"application\/pdf","byteCount":2048,"sourceURL":"https:\/\/files.example.net\/a1b2.pdf","pageURL":"https:\/\/example.org\/files","isNamedByUser":false}}}"#)
        try expectJSON(BrowserEventPayload.spaceSwitched(windowID: IDs.window, spaceID: IDs.otherPersonaSpace, personaID: IDs.otherPersona, previousSpaceID: IDs.space, previousPersonaID: IDs.persona),
                       #"{"spaceSwitched":{"windowID":"00000000-0000-0000-0000-00000000000F","spaceID":"00000000-0000-0000-0000-00000000000E","personaID":"00000000-0000-0000-0000-00000000000B","previousSpaceID":"00000000-0000-0000-0000-00000000000C","previousPersonaID":"00000000-0000-0000-0000-00000000000A"}}"#)
    }

    @Test func anEventHasFixedJSONWithItsCause() throws {
        let cause = BrowserEventCause(origin: .hookRun(hook: IDs.hook, run: IDs.run), hookChain: [IDs.hook])
        try expectJSON(event(.titleChanged(tab: tabRef(), source: .page), cause: cause),
                       #"{"id":"00000000-0000-0000-0000-000000000020","sequence":7,"date":"2026-11-14T09:30:12Z","payload":{"titleChanged":{"tab":\#(tabJSON),"source":"page"}},"cause":{"origin":{"hookRun":{"hook":"00000000-0000-0000-0000-000000000030","run":"00000000-0000-0000-0000-000000000031"}},"hookChain":["00000000-0000-0000-0000-000000000030"]}}"#)
        try expectJSON(BrowserEventCause(origin: .agentSession(id: IDs.run)), #"{"origin":{"agentSession":{"id":"00000000-0000-0000-0000-000000000031"}},"hookChain":[]}"#)
        try expectJSON(BrowserEventCause(origin: .outsideClient(grant: IDs.run)), #"{"origin":{"outsideClient":{"grant":"00000000-0000-0000-0000-000000000031"}},"hookChain":[]}"#)
        try expectJSON(BrowserEventCause(origin: .plugin(id: "org.example.sample")), #"{"origin":{"plugin":{"id":"org.example.sample"}},"hookChain":[]}"#)
    }

    @Test func eachCaseNamesItsKindSubjectPersonaSpaceAndAddresses() {
        let page = URL(string: "https://example.org/pricing")!
        let tabCases: [(BrowserEventPayload, BrowserEventKind)] = [
            (.tabOpened(tab: tabRef(), openerTabID: nil), .tabOpened),
            (.tabClosed(tab: tabRef(), reason: .user), .tabClosed),
            (.pageLoaded(tab: tabRef(), isRestore: true, isFirstLoadAfterOpen: false), .pageLoaded),
            (.addressChanged(tab: tabRef(), previousURL: URL(string: "https://example.com/")), .addressChanged),
            (.titleChanged(tab: tabRef(), source: .user), .titleChanged),
            (.tabSelected(tab: tabRef(), windowID: IDs.window), .tabSelected),
        ]
        for (payload, kind) in tabCases {
            let tabEvent = event(payload)
            #expect(tabEvent.kind == kind)
            #expect(tabEvent.subject == IDs.tab)
            #expect(tabEvent.personaID == IDs.persona)
            #expect(tabEvent.spaceID == IDs.space)
            // A previous address is no address of the event.
            #expect(tabEvent.urls == [page])
            #expect(tabEvent.tab == tabRef())
        }
        #expect(event(.tabOpened(tab: tabRef(url: nil), openerTabID: nil)).urls.isEmpty)
        #expect(event(.tabOpened(tab: tabRef(space: nil, kind: .favorite), openerTabID: nil)).spaceID == nil)

        let download = event(.downloadFinished(download: downloadRef()))
        #expect(download.kind == .downloadFinished)
        #expect(download.subject == IDs.download)
        #expect(download.personaID == IDs.persona)
        #expect(download.spaceID == nil)
        #expect(download.tab == nil)
        #expect(download.urls == [URL(string: "https://files.example.net/a1b2.pdf")!, URL(string: "https://example.org/files")!])

        let switched = event(.spaceSwitched(windowID: IDs.window, spaceID: IDs.otherPersonaSpace, personaID: IDs.otherPersona, previousSpaceID: IDs.space, previousPersonaID: IDs.persona))
        #expect(switched.kind == .spaceSwitched)
        #expect(switched.subject == IDs.window)
        #expect(switched.personaID == IDs.otherPersona)
        #expect(switched.spaceID == IDs.otherPersonaSpace)
        #expect(switched.urls.isEmpty)
        #expect(switched.tab == nil)
    }
}

// MARK: - Filters

@Suite struct BrowserEventFilterTests {
    private let load = event(.pageLoaded(tab: tabRef(), isRestore: false, isFirstLoadAfterOpen: true))

    @Test func kindsMatchListedKindsOrAllWhenEmpty() {
        #expect(BrowserEventFilter.everything.matches(load))
        #expect(BrowserEventFilter(kinds: [.pageLoaded, .tabClosed]).matches(load))
        #expect(!BrowserEventFilter(kinds: [.tabOpened]).matches(load))
    }

    @Test func scopesMatchWholePersonasAndSingleSpaces() {
        #expect(BrowserEventFilter(scope: .places([.persona(IDs.persona)])).matches(load))
        #expect(BrowserEventFilter(scope: .places([.space(IDs.space)])).matches(load))
        #expect(BrowserEventFilter(scope: .places([.space(IDs.secondSpace), .persona(IDs.persona)])).matches(load))
        #expect(!BrowserEventFilter(scope: .places([.space(IDs.secondSpace)])).matches(load))
        #expect(!BrowserEventFilter(scope: .places([.persona(IDs.otherPersona)])).matches(load))
        // A favorite's tab and a download belong to their Persona only.
        let favorite = event(.pageLoaded(tab: tabRef(space: nil, kind: .favorite), isRestore: false, isFirstLoadAfterOpen: false))
        #expect(BrowserEventFilter(scope: .places([.persona(IDs.persona)])).matches(favorite))
        #expect(!BrowserEventFilter(scope: .places([.space(IDs.space)])).matches(favorite))
        let download = event(.downloadFinished(download: downloadRef()))
        #expect(BrowserEventFilter(scope: .places([.persona(IDs.persona)])).matches(download))
        #expect(!BrowserEventFilter(scope: .places([.space(IDs.space)])).matches(download))
        // A space switch is an event of the space the window switched to.
        let switched = event(.spaceSwitched(windowID: IDs.window, spaceID: IDs.otherPersonaSpace, personaID: IDs.otherPersona, previousSpaceID: IDs.space, previousPersonaID: IDs.persona))
        #expect(BrowserEventFilter(scope: .places([.space(IDs.otherPersonaSpace)])).matches(switched))
        #expect(BrowserEventFilter(scope: .places([.persona(IDs.otherPersona)])).matches(switched))
        #expect(!BrowserEventFilter(scope: .places([.space(IDs.space)])).matches(switched))
        #expect(!BrowserEventFilter(scope: .places([.persona(IDs.persona)])).matches(switched))
    }

    @Test func sitesAndExceptionsMatchThroughSitePatterns() {
        #expect(BrowserEventFilter(sites: [AISitePattern("example.org")]).matches(load))
        #expect(BrowserEventFilter(sites: [AISitePattern("example.com"), AISitePattern("org")]).matches(load))
        #expect(!BrowserEventFilter(sites: [AISitePattern("example.com")]).matches(load))
        #expect(!BrowserEventFilter(exceptSites: [AISitePattern("example.org")]).matches(load))
        #expect(BrowserEventFilter(exceptSites: [AISitePattern("example.com")]).matches(load))
        // An event without an address never matches a site list, and an exception does not exclude it.
        let opened = event(.tabOpened(tab: tabRef(url: nil), openerTabID: nil))
        #expect(!BrowserEventFilter(sites: [AISitePattern("example.org")]).matches(opened))
        #expect(BrowserEventFilter(exceptSites: [AISitePattern("example.org")]).matches(opened))
        // A download matches by either address, and an exception for either excludes it.
        let download = event(.downloadFinished(download: downloadRef()))
        #expect(BrowserEventFilter(sites: [AISitePattern("example.net")]).matches(download))
        #expect(!BrowserEventFilter(sites: [AISitePattern("example.org")], exceptSites: [AISitePattern("files.example.net")]).matches(download))
    }

    @Test func enginesAndTabKindsApplyToTabEventsOnly() {
        #expect(BrowserEventFilter(engines: [.chromium]).matches(load))
        #expect(!BrowserEventFilter(engines: [.webKit]).matches(load))
        #expect(BrowserEventFilter(tabKinds: [.open, .pinned]).matches(load))
        #expect(!BrowserEventFilter(tabKinds: [.favorite]).matches(load))
        let download = event(.downloadFinished(download: downloadRef()))
        #expect(BrowserEventFilter(engines: [.webKit], tabKinds: [.favorite]).matches(download))
        let switched = event(.spaceSwitched(windowID: IDs.window, spaceID: IDs.space, personaID: IDs.persona, previousSpaceID: IDs.secondSpace, previousPersonaID: IDs.persona))
        #expect(BrowserEventFilter(engines: [.webKit], tabKinds: [.favorite]).matches(switched))
    }

    @Test func agentTabsMatchOnlyAFilterThatNamesThem() {
        let agent = event(.pageLoaded(tab: tabRef(kind: .agent), isRestore: false, isFirstLoadAfterOpen: true))
        #expect(!BrowserEventFilter.everything.matches(agent))
        #expect(!BrowserEventFilter(tabKinds: [.open, .pinned, .favorite, .smallWindow]).matches(agent))
        #expect(BrowserEventFilter(tabKinds: [.agent]).matches(agent))
    }

    @Test func filtersHaveFixedJSON() throws {
        try expectJSON(BrowserEventFilter.everything, #"{"kinds":[],"scope":"everywhere","sites":[],"exceptSites":[],"engines":[],"tabKinds":[]}"#)
        try expectJSON(BrowserEventFilter(kinds: [.pageLoaded], scope: .places([.persona(IDs.persona), .space(IDs.space)]), sites: [AISitePattern("example.org")], exceptSites: [AISitePattern("local-network")],
                                          engines: [.webKit], tabKinds: [.pinned]),
                       #"{"kinds":["pageLoaded"],"scope":[{"persona":"00000000-0000-0000-0000-00000000000A"},{"space":"00000000-0000-0000-0000-00000000000C"}],"sites":["example.org"],"exceptSites":["local-network"],"engines":["webKit"],"tabKinds":["pinned"]}"#)
    }
}

// MARK: - Bus

@MainActor
@Suite struct BrowserEventBusTests {
    @Test func subscribersGetMatchingEventsInSubscriptionOrderWithRisingSequences() {
        let bus = BrowserEventBus()
        var log: [String] = []
        bus.subscribe(.everything) { log.append("all \($0.sequence) \($0.kind.rawValue)") }
        bus.subscribe(BrowserEventFilter(kinds: [.tabClosed])) { log.append("closes \($0.sequence)") }
        bus.post(.pageLoaded(tab: tabRef(), isRestore: false, isFirstLoadAfterOpen: true))
        bus.post(.tabClosed(tab: tabRef(), reason: .user))
        #expect(log == ["all 1 pageLoaded", "all 2 tabClosed", "closes 2"])
    }

    @Test func aPostFromAHandlerWaitsUntilTheCurrentEventReachedEverySubscriber() {
        let bus = BrowserEventBus()
        var log: [String] = []
        bus.subscribe(.everything) { event in
            log.append("first \(event.sequence)")
            if event.kind == .addressChanged { bus.post(.titleChanged(tab: tabRef(), source: .page)) }
        }
        bus.subscribe(.everything) { log.append("second \($0.sequence)") }
        bus.post(.addressChanged(tab: tabRef(), previousURL: nil))
        #expect(log == ["first 1", "second 1", "first 2", "second 2"])
    }

    @Test func withCauseAttachesItsCauseUnlessThePostNamesOne() {
        let bus = BrowserEventBus()
        var causes: [BrowserEventCause?] = []
        bus.subscribe(.everything) { causes.append($0.cause) }
        let run = BrowserEventCause(origin: .hookRun(hook: IDs.hook, run: IDs.run), hookChain: [IDs.hook])
        let agent = BrowserEventCause(origin: .agentSession(id: IDs.run))
        let plugin = BrowserEventCause(origin: .plugin(id: "org.example.sample"))
        bus.post(.titleChanged(tab: tabRef(), source: .user))
        let value = bus.withCause(run) {
            #expect(bus.currentCause == run)
            bus.post(.titleChanged(tab: tabRef(), source: .suggested))
            bus.withCause(agent) { bus.post(.titleChanged(tab: tabRef(), source: .suggested)) }
            bus.post(.titleChanged(tab: tabRef(), source: .suggested), cause: plugin)
            return 42
        }
        #expect(value == 42)
        #expect(bus.currentCause == nil)
        bus.post(.titleChanged(tab: tabRef(), source: .page))
        #expect(causes == [nil, run, agent, plugin, nil])
    }

    @Test func aCanceledSubscriptionGetsNoMoreEventsEvenDuringADelivery() {
        let bus = BrowserEventBus()
        var log: [String] = []
        var second: BrowserEventSubscription?
        let first = bus.subscribe(.everything) { event in
            log.append("first \(event.sequence)")
            second?.cancel()
        }
        second = bus.subscribe(.everything) { log.append("second \($0.sequence)") }
        bus.post(.tabClosed(tab: tabRef(), reason: .user))
        first.cancel()
        bus.post(.tabClosed(tab: tabRef(), reason: .user))
        #expect(log == ["first 1"])
    }
}
