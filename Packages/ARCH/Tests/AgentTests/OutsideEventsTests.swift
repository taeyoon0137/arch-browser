// Tests outside programs' events (`docs/hooks.md`, Outside programs ▸ Grants; arch-cli events; arch-mcp).
// A grant with Watch Browser Events reads its Persona's events in the outside view.
// The user's tabs appear by watch IDs and hosts.
// Its own agent tabs appear by handles and reduced addresses.
// This includes a new tab's `tabOpened` before the host lists it.
// Excluded sites show neither hosts nor addresses.
// Other agents' tabs and other Personas never appear.
// A grant whose time is up reads nothing more before the expiry check ends it.
// `events/subscribe` needs the scope.
// It checks its filter.
// It replays the grant's buffer of the last 500 events after `after`.
// `watch_events` reads the same buffer with its cursor and timeout.
// It refuses kinds Arch does not know.
// The listed tools follow the scope.
import AgentControl
import ARCHEngine
import Events
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct OutsideEventsTests {
    nonisolated private static let persona = FakeHost.defaultPersona.id

    /// A service with outside access on, attached to a bus, and a client whose grant in the default Persona has Watch Browser Events.
    private func watching(_ harness: Harness, scopes: AgentGrantScopes = AgentGrantScopes(watchEvents: true)) async throws -> (AgentService, BrowserEventBus, TestClient) {
        let service = try await harness.makeOpenService()
        let bus = BrowserEventBus()
        service.attach(events: bus)
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(Self.persona), scopes: scopes)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        return (service, bus, client)
    }

    private func tab(_ id: UUID = UUID(), _ address: String?, persona: UUID = persona, kind: BrowserTabKind = .open, space: UUID? = nil) -> BrowserTabRef {
        BrowserTabRef(id: id, personaID: persona, spaceID: space, kind: kind, engine: .chromium, url: address.flatMap(URL.init(string:)))
    }

    private func names(_ value: AgentJSON?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }

    /// The next `events/event` of the connection.
    private func nextEvent(_ client: TestClient) async throws -> AgentJSON {
        while true {
            guard case .notification(let method, let params) = try await client.receive() else { continue }
            if method == AgentControlMethod.eventNotification, let event = params?["event"] { return event }
        }
    }

    @Test func aGrantWithTheScopeReadsItsPersonasEventsInTheOutsideView() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, bus, client) = try await watching(harness)
        let subscription = try await client.call(AgentControlMethod.eventsSubscribe, params: try AgentJSON(encoding: AgentEventSubscribe()))
        #expect(subscription["subscription"] == .number(1))
        let grant = try #require(service.grants.first)
        #expect(grant.scopes.watchEvents)
        #expect(harness.authenticator.count == 1)
        // The client's own agent tab, by its handle and its address without the query.
        let own = AgentTabInfo(id: UUID(), spaceID: nil, title: "", url: URL(string: "https://example.org/a?q=1"), isLoading: false, engine: .webKit, agentOwnerID: grant.id)
        harness.host.tabs.append(own)
        bus.post(.pageLoaded(tab: tab(own.id, "https://example.org/a?q=1", kind: .agent), isRestore: false, isFirstLoadAfterOpen: true))
        let first = try await nextEvent(client)
        #expect(first["tab"]?["handle"] == .string("t1"))
        #expect(first["tab"]?["url"] == .string("https://example.org/a"))
        #expect(first["tab"]?["watch"] == nil)
        // Another Persona's tab and another agent's tab never reach the grant.
        // The user's tab shows only a watch ID and its host.
        bus.post(.pageLoaded(tab: tab(UUID(), "https://work.example/x", persona: FakeHost.workPersona.id), isRestore: false, isFirstLoadAfterOpen: false))
        bus.post(.pageLoaded(tab: tab(UUID(), "https://other.example/", kind: .agent), isRestore: false, isFirstLoadAfterOpen: false))
        let users = UUID()
        bus.post(.titleChanged(tab: tab(users, "https://news.example/story/12?id=4"), source: .page))
        let watched = try await nextEvent(client)
        #expect(watched["kind"] == .string("titleChanged"))
        #expect(watched["tab"]?["watch"] == .string("w1"))
        #expect(watched["tab"]?["site"] == .string("news.example"))
        #expect(watched["tab"]?["url"] == nil)
        #expect(watched["date"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) } != nil)
        // An excluded site shows neither its host nor its address.
        // The same tab keeps its watch ID.
        bus.post(.addressChanged(tab: tab(users, "https://excluded.example/inbox"), previousURL: URL(string: "https://news.example/story/12")))
        let excluded = try await nextEvent(client)
        #expect(excluded["tab"]?["watch"] == .string("w1"))
        #expect(excluded["tab"]?["excluded"] == .bool(true))
        #expect(excluded["tab"]?["site"] == nil)
        #expect(excluded["previousSite"] == .string("news.example"))
        #expect(AgentEventLine.text(for: excluded).contains("addressChanged w1 (excluded site) (chromium, open)"))
        // A switch into another Persona names neither side's identifier.
        let space = try #require(harness.host.spaces(in: Self.persona).first)
        bus.post(.spaceSwitched(windowID: UUID(), spaceID: UUID(), personaID: FakeHost.workPersona.id, previousSpaceID: space.id, previousPersonaID: Self.persona))
        let switched = try await nextEvent(client)
        #expect(switched["window"] == .string("win1"))
        #expect(switched["to"] == ["otherPersona": true])
        #expect(switched["from"]?["space"]?.stringValue?.hasPrefix("s") == true)
    }

    /// The session posts a tab's `tabOpened` before it lists the tab.
    /// The host therefore does not list the client's new agent tab yet.
    @Test func theClientsNewAgentTabOpensBeforeTheHostListsIt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, bus, client) = try await watching(harness)
        _ = try await client.call(AgentControlMethod.eventsSubscribe, params: try AgentJSON(encoding: AgentEventSubscribe()))
        let grant = try #require(service.grants.first)
        let id = UUID()
        bus.post(.tabOpened(tab: BrowserTabRef(id: id, personaID: Self.persona, spaceID: nil, kind: .agent, engine: .webKit, url: nil, agentOwnerID: grant.id), openerTabID: nil),
                 cause: BrowserEventCause(origin: .outsideClient(grant: grant.id)))
        // Another grant's new agent tab still does not reach it.
        bus.post(.tabOpened(tab: BrowserTabRef(id: UUID(), personaID: Self.persona, spaceID: nil, kind: .agent, engine: .webKit, url: nil, agentOwnerID: UUID()), openerTabID: nil))
        bus.post(.tabClosed(tab: tab(UUID(), "https://a.example/"), reason: .user))
        let opened = try await nextEvent(client)
        #expect(opened["kind"] == .string("tabOpened"))
        #expect(opened["tab"]?["handle"] == .string("t1"))
        #expect(opened["byThisClient"] == .bool(true))
        let next = try await nextEvent(client)
        #expect(next["kind"] == .string("tabClosed"))
    }

    @Test func aGrantWhoseTimeIsUpReadsNoMoreEvents() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let bus = BrowserEventBus()
        service.attach(events: bus)
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(Self.persona), scopes: AgentGrantScopes(watchEvents: true), duration: .day)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("list_spaces")
        let grant = try #require(service.grants.first)
        bus.post(.tabOpened(tab: tab(UUID(), "https://a.example/"), openerTabID: nil))
        let buffer = try #require(service.outsidePrograms.buffers[grant.id])
        #expect(buffer.events.count == 1)
        // A day later, before the expiry check runs, the grant gets nothing more.
        harness.now = harness.now.addingTimeInterval(24 * 60 * 60 + 1)
        bus.post(.tabOpened(tab: tab(UUID(), "https://b.example/"), openerTabID: nil))
        #expect(buffer.events.count == 1)
    }

    @Test func subscribingNeedsTheScopeAndAFilterOfTheGrantsPersona() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (_, _, client) = try await watching(harness, scopes: AgentGrantScopes())
        await #expect(throws: AgentClientError.self) {
            _ = try await client.call(AgentControlMethod.eventsSubscribe, params: try AgentJSON(encoding: AgentEventSubscribe()))
        }
        let scoped = try Harness()
        defer { scoped.cleanUp() }
        let (_, _, watcher) = try await watching(scoped)
        for filter in [AgentEventFilter(spaces: ["Nowhere"]), AgentEventFilter(kinds: ["tabMoved"]), AgentEventFilter(tabKinds: ["window"])] {
            await #expect(throws: AgentClientError.self) {
                _ = try await watcher.call(AgentControlMethod.eventsSubscribe, params: try AgentJSON(encoding: AgentEventSubscribe(filter: filter)))
            }
        }
        for _ in 0 ..< AgentLimits.subscriptionsPerConnection {
            _ = try await watcher.call(AgentControlMethod.eventsSubscribe, params: try AgentJSON(encoding: AgentEventSubscribe(filter: AgentEventFilter(spaces: ["home"]))))
        }
        await #expect(throws: AgentClientError.self) {
            _ = try await watcher.call(AgentControlMethod.eventsSubscribe, params: try AgentJSON(encoding: AgentEventSubscribe()))
        }
    }

    @Test func afterReplaysTheBufferAndAFilterTakesItsKindsAndSites() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, bus, client) = try await watching(harness)
        // The grant records once it takes effect.
        // The first call made it take effect.
        _ = try await client.callTool("list_spaces")
        for index in 0 ..< AgentLimits.eventBuffer + 10 {
            bus.post(.pageLoaded(tab: tab(UUID(), "https://site\(index % 3).example/"), isRestore: false, isFirstLoadAfterOpen: false))
        }
        let grant = try #require(service.grants.first)
        let buffer = try #require(service.outsidePrograms.buffers[grant.id])
        #expect(buffer.events.count == AgentLimits.eventBuffer)
        let filter = AgentEventFilter(kinds: ["pageLoaded"], sites: ["site1.example"])
        _ = try await client.call(AgentControlMethod.eventsSubscribe, params: try AgentJSON(encoding: AgentEventSubscribe(filter: filter, after: 0)))
        let replayed = try await nextEvent(client)
        #expect(replayed["tab"]?["site"] == .string("site1.example"))
        #expect(replayed["seq"] == .number(Double(try #require(buffer.events.first { $0.view["tab"]?["site"] == .string("site1.example") }).event.sequence)))
    }

    @Test func watchEventsReadsTheBufferWithItsCursorAndTimeout() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (_, bus, client) = try await watching(harness)
        #expect(names(try await client.call(AgentControlMethod.toolsList)["tools"]).contains("watch_events"))
        let empty = try await client.callTool("watch_events", ["timeout_ms": 50])
        #expect(empty.status == .ok)
        #expect(empty.structured?["events"] == .array([]))
        bus.post(.tabOpened(tab: tab(UUID(), "https://a.example/"), openerTabID: nil))
        bus.post(.tabClosed(tab: tab(UUID(), "https://b.example/"), reason: .user))
        let all = try await client.callTool("watch_events", ["after": 0, "timeout_ms": 50])
        guard case .array(let events)? = all.structured?["events"], case .number(let last)? = all.structured?["last"] else { Issue.record("No events."); return }
        #expect(events.map { $0["kind"] } == [.string("tabOpened"), .string("tabClosed")])
        #expect(all.text.contains("tabClosed w2 b.example (chromium, open)"))
        let closes = try await client.callTool("watch_events", ["after": 0, "kinds": ["tabClosed"], "timeout_ms": 50])
        guard case .array(let closed)? = closes.structured?["events"] else { Issue.record("No events."); return }
        #expect(closed.map { $0["kind"] } == [.string("tabClosed")])
        // This refuses a kind Arch does not know, as events/subscribe does.
        #expect(try await client.callTool("watch_events", ["after": 0, "kinds": ["tabClosd"], "timeout_ms": 50]).code == "invalidArguments")
        // A later call waits for the next event after its cursor.
        let waiting = Task { try await client.callTool("watch_events", ["after": .number(last), "timeout_ms": 5_000]) }
        try await Task.sleep(for: .milliseconds(200))
        bus.post(.tabSelected(tab: tab(UUID(), "https://c.example/"), windowID: UUID()))
        let next = try await waiting.value
        guard case .array(let followed)? = next.structured?["events"] else { Issue.record("No events."); return }
        #expect(followed.map { $0["kind"] } == [.string("tabSelected")])
    }

    @Test func toolsListedFollowTheScope() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (_, _, client) = try await watching(harness, scopes: AgentGrantScopes())
        #expect(names(try await client.call(AgentControlMethod.toolsList)["tools"]).contains("watch_events"))
        _ = try await client.callTool("list_spaces")
        #expect(!names(try await client.call(AgentControlMethod.toolsList)["tools"]).contains("watch_events"))
        let refused = try await client.callTool("watch_events", ["timeout_ms": 0])
        #expect(refused.status == .refused)
    }
}
