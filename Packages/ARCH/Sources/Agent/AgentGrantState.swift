// What the tool host keeps for one grant, or for one in-app session, for the launch (docs/agents.md, Tools; Page snapshots and refs; Approval interface): the handles its client uses, the events since its previous call, what each of its agent tabs reported, which waits read, its calls today, each tab's latest snapshot with the fingerprints of its refs, what the user allowed for the session, the calls that still run, which a Stop cancels, and the calls that wait for the user past the first answer.
import AgentControl
import Foundation

/// The handles a grant's client uses for the launch: `t1`, `t2`, and so on for tabs, `s1`, `s2` for spaces, and `a1`, `a2` for calls that wait for the user, never reused, and the tabs the user shared with it through `request_tab`.
struct AgentGrantHandles {
    var tabs = AgentHandleTable(prefix: "t")
    var spaces = AgentHandleTable(prefix: "s")
    var approvals = AgentHandleTable(prefix: "a")
    var sharedTabIDs: [UUID] = []
    /// The shared tabs the user let the client act in; the others it only reads.
    var actingSharedTabIDs: Set<UUID> = []
}

/// A tab's latest snapshot: the page it read, by address and by the tab's count of pages (`AgentTabActivity.pages`), its refs with their fingerprints and, for links, their full addresses, and its lines, which the next snapshot's diff compares.
struct AgentSnapshotRecord {
    struct Ref: Equatable {
        var fingerprint: String
        var href: URL?
    }

    var url: URL
    var documentID: UUID
    var ownerID: UUID?
    var document: Int
    var refs: [String: Ref]
    var lines: [String]
}

/// Snapshot memory for one grant or session. Ref fingerprints and diff lines belong to the captured document.
@MainActor final class AgentSnapshotStore {
    var records: [UUID: AgentSnapshotRecord] = [:]
    var counts: [UUID: Int] = [:]

    func current(_ tab: AgentTabInfo, pages: Int) -> AgentSnapshotRecord? {
        guard let record = records[tab.id], record.documentID == tab.documentID, record.ownerID == tab.agentOwnerID,
              record.url == tab.url, record.document == pages else { return nil }
        return record
    }

    func remove(_ id: UUID) {
        records[id] = nil
        counts[id] = nil
    }
}

/// A call that runs: its task, which Stop, Stop All Agents, revocation, expiry, and its connection's close cancel, and once it answered `approvalPending`, the outcome that `approval_wait` takes and the service records when it comes.
@MainActor final class AgentCallBox {
    /// The connection the call came on, and its request ID there, which a client's `tools/cancel` names.
    let connectionID: UUID?
    let callID: Int?
    var task: Task<Void, Never>?
    private(set) var outcome: AgentToolHost.Outcome?
    /// The card the call waits on.
    var approvalID: UUID?
    private var finished: [(AgentToolHost.Outcome) -> Void] = []

    init(connectionID: UUID?, callID: Int? = nil) {
        self.connectionID = connectionID
        self.callID = callID
    }

    func finish(_ outcome: AgentToolHost.Outcome) {
        self.outcome = outcome
        let handlers = finished
        finished = []
        handlers.forEach { $0(outcome) }
    }

    /// Calls `handler` with the call's outcome once it has one, at once if it has.
    func whenFinished(_ handler: @escaping (AgentToolHost.Outcome) -> Void) {
        if let outcome { handler(outcome) } else { finished.append(handler) }
    }
}

struct AgentHandleTable {
    let prefix: String
    private var next = 1
    private var handles: [UUID: String] = [:]
    private var ids: [String: UUID] = [:]

    init(prefix: String) {
        self.prefix = prefix
    }

    /// The handle of `id`, given on first use.
    mutating func handle(for id: UUID) -> String {
        if let handle = handles[id] { return handle }
        let handle = "\(prefix)\(next)"
        next += 1
        handles[id] = handle
        ids[handle] = id
        return handle
    }

    /// A removed handle stays invalid even if the same tab is shared again later.
    mutating func remove(_ id: UUID) {
        if let handle = handles.removeValue(forKey: id) { ids.removeValue(forKey: handle) }
    }

    /// The ID behind a handle this table gave; a handle from elsewhere reads as not found.
    func id(for handle: String) -> UUID? {
        ids[handle]
    }
}

/// An in-app session's navigation by an address its agent wrote, in one tab (rule P13).
struct AgentWrittenLoad {
    let id = UUID()
    var url: URL
    /// The tab's document at the navigation's first check; once another document commits, the navigation's redirects are over and its checks end.
    var documentID: UUID?
    /// Whether a call waits for the navigation, to ask the user about a hop the scope stops; with none, such a hop is refused.
    var isAwaited = true
}

/// A redirect hop that the scope stopped in a written address's navigation, which ended there.
struct AgentHeldHop {
    var loadID: UUID
    var question: AgentAddressQuestion
}

/// Something that happened in one of the client's agent tabs since its previous call.
struct AgentEvent: Equatable {
    enum Kind: Equatable {
        case report(AgentTabReport)
        /// Rule P16 stopped a navigation, redirect hop, or popup at this address.
        case refused(URL)
        /// Rule P13 stopped a redirect hop of a written address's navigation to a site outside the session's scope, since no call waited to ask the user.
        case hopStopped
        /// A page opened a tab beyond the limit of agent tabs, which Arch closed.
        case closedOverLimit
        /// The user answered a card about a download or a link to another app that a page started, with the sentence to say.
        case decided(String)
    }

    /// Counts the grant's events, so that a call can tell those it caused.
    var sequence: Int
    var tabID: UUID
    var kind: Kind
}

/// What one agent tab has reported this launch, which waits compare before and after a step.
struct AgentTabActivity: Equatable {
    /// The documents the main frame finished loading, which navigations wait for.
    var documents = 0
    /// The pages the tab showed: one more at each change of the main frame's address other than in its fragment, which comes as a navigation starts or commits, before its document finishes loading, and at each finished document, as after a reload. Snapshots, Allow on This Page, cards, and the forms the client typed into belong to one page.
    var pages = 0
    /// The address the last page counted, without its fragment.
    var address: URL?
    var stops = 0
    var refusals = 0
    var isGone = false
}

@MainActor final class AgentGrantState {
    var handles = AgentGrantHandles()
    private(set) var events: [AgentEvent] = []
    private var sequence = 0
    private var activity: [UUID: AgentTabActivity] = [:]
    /// The day the count is for, as the start of the day, and the calls made in it.
    private var callsDay: Date?
    private var calls = 0
    /// Each tab's latest snapshot, and how many it had this launch. A session replaces the store at Stop and Take Over, so that no ref or diff outlives them.
    var snapshots = AgentSnapshotStore()
    /// An in-app session's navigations by an address the agent wrote, by tab: their redirect hops are checked against the site scope (P13) until the navigation commits a document, stops at a hop, or another navigation of the session replaces it, or its tab closes or leaves the session, whether or not a call still waits for it.
    var writtenLoads: [UUID: AgentWrittenLoad] = [:]
    /// A redirect hop of a written address's navigation that the scope stopped, by tab, which the call that waits for that navigation asks the user about.
    var heldHops: [UUID: AgentHeldHop] = [:]
    /// Allow on This Page: the tab's page count when the user allowed it, which lasts until the tab shows another page.
    var pageAllowances: [UUID: Int] = [:]
    /// Allow on <site> for This Session, and Allow Downloads from This Site for This Session, by host.
    var siteAllowances: Set<String> = []
    var downloadSites: Set<String> = []
    /// Downloads the user allowed once, by address, until they start.
    var allowedDownloads: Set<URL> = []
    /// The forms the client typed into, per tab, on the page of that count (P5).
    var typedForms: [UUID: (page: Int, keys: Set<String>)] = [:]
    /// Calls that answered `approvalPending`, by their handle.
    var pendingCalls: [String: AgentCallBox] = [:]
    /// The calls that still run.
    var runningCalls: [AgentCallBox] = []
    /// When the latest actions ran, for the limit of actions a second.
    var actionTimes: [Date] = []

    /// The events of one launch stop growing past this many until the client calls again; the oldest go first.
    static let keptEvents = 200

    func record(_ kind: AgentEvent.Kind, tab tabID: UUID) {
        var tab = activity[tabID] ?? AgentTabActivity()
        switch kind {
        case .report(.addressChanged(let url)):
            let address = url.map(Self.withoutFragment)
            if address != tab.address {
                tab.pages += 1
                tab.address = address
            }
        case .report(.loaded(let url, _)):
            tab.documents += 1
            tab.pages += 1
            tab.address = url.map(Self.withoutFragment)
        case .report(.stoppedLoading): tab.stops += 1
        case .report(.closed), .report(.takenOver): tab.isGone = true
        case .refused: tab.refusals += 1
        case .report, .closedOverLimit, .decided, .hopStopped: break
        }
        activity[tabID] = tab
        switch kind {
        case .report(.stoppedLoading), .report(.addressChanged): return
        default: break
        }
        sequence += 1
        events.append(AgentEvent(sequence: sequence, tabID: tabID, kind: kind))
        if events.count > Self.keptEvents { events.removeFirst(events.count - Self.keptEvents) }
    }

    func activity(of tabID: UUID) -> AgentTabActivity {
        activity[tabID] ?? AgentTabActivity()
    }

    private static func withoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.fragment != nil else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    /// Starts the checks of a written address's navigation in `tabID`, which replaces the navigation there before, with a call that waits for it.
    func beginWrittenLoad(_ url: URL, in tabID: UUID) -> UUID {
        let load = AgentWrittenLoad(url: url)
        writtenLoads[tabID] = load
        heldHops[tabID] = nil
        return load.id
    }

    /// The call that waited for the navigation ended: from then on, a hop the scope stops is refused without asking.
    func stopAwaiting(_ loadID: UUID, in tabID: UUID) {
        if writtenLoads[tabID]?.id == loadID { writtenLoads[tabID]?.isAwaited = false }
        if heldHops[tabID]?.loadID == loadID { heldHops[tabID] = nil }
    }

    /// Every written address's navigation goes on with no call that waits for it, as at the end of a turn, at Stop, and at the session's end.
    func stopAwaitingLoads() {
        for tabID in writtenLoads.keys { writtenLoads[tabID]?.isAwaited = false }
        heldHops = [:]
    }

    /// The hop the scope stopped in the navigation `loadID`, which ended there; the call that waits for it asks the user.
    func takeHeldHop(of loadID: UUID, in tabID: UUID) -> AgentAddressQuestion? {
        guard let hop = heldHops[tabID], hop.loadID == loadID else { return nil }
        heldHops[tabID] = nil
        if writtenLoads[tabID]?.id == loadID { writtenLoads[tabID] = nil }
        return hop.question
    }

    /// The tab's navigations are no longer the agent's to check: it closed, left the client, or another navigation of the client replaced the written one.
    func endWrittenLoad(in tabID: UUID) {
        writtenLoads[tabID] = nil
        heldHops[tabID] = nil
    }

    /// Cancels the calls that still run, or those of one connection: each answers that the client's work ended at its next step, and opens no card.
    func cancelCalls(onConnection connectionID: UUID? = nil) {
        for call in runningCalls where connectionID == nil || call.connectionID == connectionID { call.task?.cancel() }
    }

    /// A client's `tools/cancel`: cancels the call with that request ID on the connection, which then runs no further step and opens no card, and returns the card it waits on, for the service to withdraw.
    func cancelCall(_ callID: Int, onConnection connectionID: UUID) -> [UUID] {
        var cards: [UUID] = []
        for call in runningCalls where call.connectionID == connectionID && call.callID == callID {
            call.task?.cancel()
            if let approvalID = call.approvalID { cards.append(approvalID) }
        }
        return cards
    }

    /// A client's `tools/cancel` of an `approval_wait`: cancels the call that waits for the user under `handle`, which then runs no further step, and returns the card it waits on, for the service to withdraw. A call that has ended is left alone.
    func cancelPendingCall(_ handle: String) -> UUID? {
        guard let call = pendingCalls[handle], call.outcome == nil else { return nil }
        call.task?.cancel()
        return call.approvalID
    }

    /// The last event's sequence number, from which a call tells the events it caused.
    var lastSequence: Int { sequence }

    /// The events since the previous call, which this call's result carries, and none after it.
    func takeEvents() -> [AgentEvent] {
        defer { events = [] }
        return events
    }

    /// Starts today's count from the calls the activity log already holds for the grant, as after a relaunch.
    func seedCalls(_ count: Int, at date: Date, calendar: Calendar = .current) {
        callsDay = calendar.startOfDay(for: date)
        calls = count
    }

    /// Counts a call against the grant's calls today, and says whether it is within the limit.
    func countCall(at date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        if callsDay != day {
            callsDay = day
            calls = 0
        }
        guard calls < AgentLimits.toolCallsPerGrantPerDay else { return false }
        calls += 1
        return true
    }
}
