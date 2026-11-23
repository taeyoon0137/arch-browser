// A grant with Watch Browser Events sees its Persona's browser events (`docs/hooks.md`, Outside programs).
// Their own agent tabs and shared tabs use handles and addresses without queries. Other tabs use watch IDs and hosts; windows use handles, never identifiers.
// Each grant keeps its latest 500 events in memory for `--after` and `watch_events` to replay.
// Each connection has at most 4 subscriptions. Their queue holds 1,000 events before dropping the oldest. Nothing is stored on disk.
import AgentControl
import AI
import ARCHEngine
import Events
import Foundation

/// What the service keeps for outside programs while Arch runs: each grant's event buffer, each connection's subscriptions, and its subscription to the session's bus.
@MainActor final class AgentOutsidePrograms {
    /// Grants' buffers by grant ID, made at the first event after the grant has the scope.
    var buffers: [UUID: AgentEventBuffer] = [:]
    /// Each connection's subscriptions, by connection ID.
    var subscriptions: [UUID: AgentConnectionEvents] = [:]
    var busSubscription: BrowserEventSubscription?

    func buffer(for grantID: UUID) -> AgentEventBuffer {
        if let buffer = buffers[grantID] { return buffer }
        let buffer = AgentEventBuffer()
        buffers[grantID] = buffer
        return buffer
    }

    /// A grant ended: its buffer, watch IDs, and window handles go, and its connections' subscriptions with them.
    func grantDidEnd(_ grantID: UUID) {
        buffers[grantID]?.end()
        buffers[grantID] = nil
        subscriptions = subscriptions.filter { $0.value.grantID != grantID }
    }

    func connectionDidClose(_ id: UUID) {
        subscriptions[id] = nil
    }
}

/// One event as a grant sees it: the bus's event, which subscriptions filter, and its outside view as JSON, which they deliver.
struct AgentBufferedEvent {
    var event: BrowserEvent
    var view: AgentJSON
}

/// One grant's events in the outside view, the last 500, with the grant's watch IDs (`w1`, `w2`, …) and window handles (`win1`, `win2`, …), which last while Arch runs and are never reused.
@MainActor final class AgentEventBuffer {
    private(set) var events: [AgentBufferedEvent] = []
    var watches = AgentHandleTable(prefix: "w")
    var windows = AgentHandleTable(prefix: "win")
    /// The sequence of the last event the grant saw, or of the bus when it had none.
    private(set) var lastSequence: UInt64 = 0
    private(set) var hasEnded = false

    func append(_ event: AgentBufferedEvent) {
        events.append(event)
        if events.count > AgentLimits.eventBuffer { events.removeFirst(events.count - AgentLimits.eventBuffer) }
        lastSequence = max(lastSequence, event.event.sequence)
    }

    /// The bus moved on without an event for this grant; a later `watch_events` without `after` starts there.
    func passed(_ sequence: UInt64) {
        lastSequence = max(lastSequence, sequence)
    }

    func end() {
        hasEnded = true
    }

    /// The buffered events after `sequence` that `matches` takes, oldest first, at most `limit`.
    func events(after sequence: UInt64, limit: Int = .max, matching matches: (AgentBufferedEvent) -> Bool) -> [AgentBufferedEvent] {
        var found: [AgentBufferedEvent] = []
        for event in events where event.event.sequence > sequence && matches(event) {
            found.append(event)
            if found.count == limit { break }
        }
        return found
    }
}

/// A connection's subscriptions to its grant's events, and their queue, which the service flushes on the main queue after each event.
@MainActor final class AgentConnectionEvents {
    let grantID: UUID
    private(set) var filters: [Int: AgentEventMatch] = [:]
    private var nextID = 1
    /// Events waiting to be written, oldest first, and how many each subscription dropped since its last delivered event.
    var queue: [(subscription: Int, view: AgentJSON)] = []
    var dropped: [Int: Int] = [:]
    var flushScheduled = false

    init(grantID: UUID) {
        self.grantID = grantID
    }

    var isFull: Bool { filters.count >= AgentLimits.subscriptionsPerConnection }

    func add(_ filter: AgentEventMatch) -> Int {
        let id = nextID
        nextID += 1
        filters[id] = filter
        return id
    }

    /// Queues a buffered event for one subscription, as `after` replays them.
    func enqueue(_ view: AgentJSON, for id: Int) {
        queue.append((id, view))
        while queue.count > AgentLimits.eventQueue {
            let oldest = queue.removeFirst()
            dropped[oldest.subscription, default: 0] += 1
        }
    }

    @discardableResult func remove(_ id: Int) -> Bool {
        dropped[id] = nil
        queue.removeAll { $0.subscription == id }
        return filters.removeValue(forKey: id) != nil
    }

    /// Queues the event for each subscription that takes it; past the queue's 1,000 events the oldest drops and counts.
    func enqueue(_ event: AgentBufferedEvent, allowsAI: (URL) -> Bool) {
        for (id, filter) in filters.sorted(by: { $0.key < $1.key }) where filter.matches(event.event, allowsAI: allowsAI) {
            queue.append((id, event.view))
        }
        while queue.count > AgentLimits.eventQueue {
            let oldest = queue.removeFirst()
            dropped[oldest.subscription, default: 0] += 1
        }
    }
}

/// An `AgentEventFilter` resolved for one grant: the kinds, the spaces of its Persona, the sites, the engines, and the tab kinds. An empty set matches every value, the client's own agent tabs included, since the outside view shows no other agent's tabs. Site lists match only addresses AI may read, so that a filter cannot tell an excluded site's host.
struct AgentEventMatch: Equatable {
    var kinds: Set<BrowserEventKind> = []
    /// nil: the grant's whole Persona.
    var spaceIDs: Set<UUID>?
    var sites: [AISitePattern] = []
    var exceptSites: [AISitePattern] = []
    var engines: Set<EngineKind> = []
    var tabKinds: Set<BrowserTabKind> = []

    /// The filter's names checked against the grant's Persona's spaces, or the sentence of the first name Arch does not know.
    static func make(_ filter: AgentEventFilter, spaces: [AgentSpaceInfo]) -> Result<AgentEventMatch, AgentRPCError> {
        var match = AgentEventMatch()
        for name in filter.kinds {
            guard let kind = BrowserEventKind(rawValue: name) else { return .failure(.invalidParams("Arch has no event kind named \(name).")) }
            match.kinds.insert(kind)
        }
        if !filter.spaces.isEmpty {
            var ids = Set<UUID>()
            for name in filter.spaces {
                guard let space = spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                    return .failure(.invalidParams("This client's Persona has no space named \(name)."))
                }
                ids.insert(space.id)
            }
            match.spaceIDs = ids
        }
        for (names, keyPath) in [(filter.sites, \AgentEventMatch.sites), (filter.exceptSites, \AgentEventMatch.exceptSites)] {
            for name in names {
                guard let pattern = AISitePattern(parsing: name) else { return .failure(.invalidParams("\(name) names no site.")) }
                match[keyPath: keyPath].append(pattern)
            }
        }
        for name in filter.engines {
            switch name {
            case "webkit": match.engines.insert(.webKit)
            case "chromium": match.engines.insert(.chromium)
            default: return .failure(.invalidParams("Arch has no engine named \(name)."))
            }
        }
        for name in filter.tabKinds {
            let kind: BrowserTabKind? = name == "small-window" ? .smallWindow : BrowserTabKind(rawValue: name)
            guard let kind else { return .failure(.invalidParams("Arch has no tab kind named \(name).")) }
            match.tabKinds.insert(kind)
        }
        return .success(match)
    }

    func matches(_ event: BrowserEvent, allowsAI: (URL) -> Bool) -> Bool {
        guard kinds.isEmpty || kinds.contains(event.kind) else { return false }
        if let spaceIDs, !(event.spaceID.map(spaceIDs.contains) ?? false) { return false }
        let readable = event.urls.filter(allowsAI)
        guard sites.isEmpty || readable.contains(where: { url in sites.contains { $0.matches(url) } }),
              !readable.contains(where: { url in exceptSites.contains { $0.matches(url) } }) else { return false }
        if let tab = event.tab {
            guard engines.isEmpty || engines.contains(tab.engine) else { return false }
            return tabKinds.isEmpty || tabKinds.contains(tab.kind)
        }
        if case .downloadFinished = event.payload { return tabKinds.isEmpty || tabKinds.contains(.agent) }
        return true
    }
}

/// How one grant names what its events show: its own agent tabs and the tabs shared with it by their tool handles, the user's other tabs by watch IDs, spaces by their handles, and windows by handles of their own.
@MainActor final class AgentEventReader: BrowserEventOutsideReader {
    let grantID: UUID
    let personaID: UUID
    private let state: AgentGrantState
    private let buffer: AgentEventBuffer
    /// The grant's agent tabs as the host lists them, and the event's own tab when its folder is the grant's, since a tab's `tabOpened` comes before the host lists it.
    private var ownTabs: Set<UUID>
    private let check: (URL) -> Bool

    init(grant: AgentGrant, state: AgentGrantState, buffer: AgentEventBuffer, ownTabs: Set<UUID>, allowsAI: @escaping (URL) -> Bool) {
        grantID = grant.id
        personaID = grant.personaID
        self.state = state
        self.buffer = buffer
        self.ownTabs = ownTabs
        check = allowsAI
    }

    func name(ofTab id: UUID) -> BrowserEventOutsideTab {
        if ownTabs.contains(id) { return .own(state.handles.tabs.handle(for: id)) }
        if state.handles.sharedTabIDs.contains(id) { return .shared(state.handles.tabs.handle(for: id)) }
        return .watched(buffer.watches.handle(for: id))
    }

    func handle(ofSpace id: UUID) -> String { state.handles.spaces.handle(for: id) }

    func handle(ofWindow id: UUID) -> String { buffer.windows.handle(for: id) }

    func allowsAI(on url: URL) -> Bool { check(url) }

    /// The event as this grant sees it, as JSON with ISO 8601 dates, or nil when it does not reach the grant, as another agent's tab's events do not.
    func view(of event: BrowserEvent) -> AgentJSON? {
        if let tab = event.tab, tab.agentOwnerID == grantID { ownTabs.insert(tab.id) }
        if let tab = event.tab, tab.kind == .agent, !ownTabs.contains(tab.id) { return nil }
        guard let view = event.view(self) else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(view)).flatMap { try? AgentJSON.decode($0) }
    }
}

extension AgentToolHost {
    /// `watch_events`: the grant's buffered events after `after`, of the kinds named, at most 100, or, when there are none yet, the first that arrive within `timeout_ms`. Without `after` it starts after the last event the grant saw, so it returns only new ones. A kind Arch does not know is refused, as `events/subscribe` refuses it. Its text has one line per event, as `arch-cli events` prints them, with download names as untrusted blocks.
    static func watchEvents(_ arguments: [String: AgentJSON], buffer: AgentEventBuffer) async -> Outcome {
        var kinds = Set<BrowserEventKind>()
        if case .array(let items)? = arguments["kinds"] {
            for item in items {
                guard let name = item.stringValue, let kind = BrowserEventKind(rawValue: name) else {
                    return error("invalidArguments", "Arch has no event kind named \(item.stringValue ?? "that").")
                }
                kinds.insert(kind)
            }
        }
        let after = arguments["after"].flatMap(integer).map { UInt64(max($0, 0)) } ?? buffer.lastSequence
        let timeout = TimeInterval(arguments["timeout_ms"].flatMap(integer) ?? AgentLimits.toolWaitSeconds * 1000) / 1000
        func found() -> [AgentBufferedEvent] {
            buffer.events(after: after, limit: AgentLimits.watchEventsPerCall) { kinds.isEmpty || kinds.contains($0.event.kind) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var events = found()
        while events.isEmpty, Date() < deadline, !Task.isCancelled, !buffer.hasEnded {
            try? await Task.sleep(for: .milliseconds(50))
            events = found()
        }
        let last = events.last?.event.sequence ?? max(after, buffer.lastSequence)
        let lines = events.map { AgentEventLine.text(for: $0.view) }
        let summary = events.isEmpty ? "No browser events came after event \(after) within \(seconds(timeout)) seconds." : "\(events.count) browser \(events.count == 1 ? "event" : "events") after event \(after):"
        return Outcome(result: AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"),
                                               structured: ["events": .array(events.map(\.view)), "last": .number(Double(last))]))
    }
}
