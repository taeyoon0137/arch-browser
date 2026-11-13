// What the tool host keeps for one grant for the launch (docs/agents.md, Tools): the handles its client uses, the events since its previous call, what each of its agent tabs reported, which waits read, and its calls today.
import AgentControl
import Foundation

/// The handles a grant's client uses for the launch: `t1`, `t2`, and so on for tabs and `s1`, `s2` for spaces, never reused, and the tabs the user shared with it.
struct AgentGrantHandles {
    var tabs = AgentHandleTable(prefix: "t")
    var spaces = AgentHandleTable(prefix: "s")
    /// The tabs the user shared with the client; plan task VII.13 shares them through `request_tab`.
    var sharedTabIDs: [UUID] = []
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

    /// The ID behind a handle this table gave; a handle from elsewhere reads as not found.
    func id(for handle: String) -> UUID? {
        ids[handle]
    }
}

/// Something that happened in one of the client's agent tabs since its previous call.
struct AgentEvent: Equatable {
    enum Kind: Equatable {
        case report(AgentTabReport)
        /// Rule P16 stopped a navigation, redirect hop, or popup at this address.
        case refused(URL)
        /// A page opened a tab beyond the limit of agent tabs, which Arch closed.
        case closedOverLimit
    }

    /// Counts the grant's events, so that a call can tell those it caused.
    var sequence: Int
    var tabID: UUID
    var kind: Kind
}

/// What one agent tab has reported this launch, which waits compare before and after a step.
struct AgentTabActivity: Equatable {
    var documents = 0
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

    /// The events of one launch stop growing past this many until the client calls again; the oldest go first.
    static let keptEvents = 200

    func record(_ kind: AgentEvent.Kind, tab tabID: UUID) {
        var tab = activity[tabID] ?? AgentTabActivity()
        switch kind {
        case .report(.loaded): tab.documents += 1
        case .report(.stoppedLoading): tab.stops += 1
        case .report(.closed), .report(.takenOver): tab.isGone = true
        case .refused: tab.refusals += 1
        case .report, .closedOverLimit: break
        }
        activity[tabID] = tab
        if case .report(.stoppedLoading) = kind { return }
        sequence += 1
        events.append(AgentEvent(sequence: sequence, tabID: tabID, kind: kind))
        if events.count > Self.keptEvents { events.removeFirst(events.count - Self.keptEvents) }
    }

    func activity(of tabID: UUID) -> AgentTabActivity {
        activity[tabID] ?? AgentTabActivity()
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
