// Hooks from outside programs (`docs/hooks.md`, Hooks from outside programs; Control methods and the registrar): the service checks a proposal's form against the caps of such hooks, and the hook registry, which `Hooks` holds and `Agent` cannot depend on, shows the proposal sheet, asks for Touch ID or the login password, and adds the hook through this protocol. A proposed hook reaches no more than the proposing grant can: the event's tab only, `tabs.rename` and `agent` without `tabs`, agent runs at tab access `title` with at least Keep Activity Only and no reply, and the grant's Persona; it pauses when the program's grant ends.
import AgentControl
import AI
import Events
import Foundation
import SwiftUI

/// A hook an outside program proposed, within the caps the service checked: a JavaScript script, its trigger's event, a filter within the grant's Persona that names no agent tabs, and an agent run at tab access `title` with at least Keep Activity Only.
public struct AgentHookProposal: Sendable {
    public var name: String
    public var event: BrowserEventKind
    /// For `pageLoaded`: `first`, `new`, or `every`.
    public var loads: String?
    public var filter: BrowserEventFilter
    public var delay: Duration?
    public var timeout: Duration?
    /// The script's checked bytes.
    public var script: Data
    /// `tabs.rename`.
    public var renamesTabs: Bool
    /// With `agent`, the run the script starts, at tab access `title`, and its tools.
    public var agent: AgentRunOptions?
    /// What the run log keeps, Keep Activity Only at least.
    public var record: AgentRunRecord

    public init(name: String, event: BrowserEventKind, loads: String? = nil, filter: BrowserEventFilter, delay: Duration? = nil, timeout: Duration? = nil, script: Data,
                renamesTabs: Bool, agent: AgentRunOptions? = nil, record: AgentRunRecord = .activity) {
        self.name = name
        self.event = event
        self.loads = loads
        self.filter = filter
        self.delay = delay
        self.timeout = timeout
        self.script = script
        self.renamesTabs = renamesTabs
        self.agent = agent
        self.record = record
    }

    /// The agent grant of a proposed hook: the options' tools at tab access `title`, Keep Activity Only to Keep the Session, the hooks' 200 runs a day, the options' limits as ceilings, and no reply, so that the script cannot write the model's words into tab names.
    public static func agentGrant(for options: AgentRunOptions) -> AgentRunGrant {
        AgentRunGrant(tools: Set(options.tools), tabAccess: .title, minimumRecord: .activity, maximumRecord: .session, runsPerDay: AgentGrant.defaultRunsPerDay,
                      limits: options.limits, returnsReply: false)
    }

    /// The proposal that `hooks/add`'s params describe, or the sentence of the first part outside the caps: an unknown event, loads, permission, or tool, the permission `tabs`, a filter naming agent tabs or a space outside the grant's Persona, a script that is not UTF-8 or passes 256 KB, agent options without `agent` or the reverse, tab access `page`, and Keep Nothing.
    static func make(_ add: AgentHookAdd, grant: AgentGrant, spaces: [AgentSpaceInfo]) throws(AgentHookRefusal) -> AgentHookProposal {
        let name = add.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw AgentHookRefusal("A hook's name must contain 1 to 100 characters.") }
        guard let event = BrowserEventKind(rawValue: add.event) else { throw AgentHookRefusal("Arch has no event named \(add.event).") }
        if let loads = add.loads {
            guard event == .pageLoaded else { throw AgentHookRefusal("Only pageLoaded hooks take loads.") }
            guard AgentHookAdd.loads.contains(loads) else { throw AgentHookRefusal("loads takes first, new, or every.") }
        }
        if add.permissions.contains("tabs") { throw AgentHookRefusal("Hooks from programs cannot read tab titles and addresses, so Arch refuses the tabs permission.") }
        for permission in add.permissions where !AgentHookAdd.permissions.contains(permission) { throw AgentHookRefusal("Arch has no hook permission named \(permission).") }
        guard !add.filter.tabKinds.contains("agent") else { throw AgentHookRefusal("Hooks never run for agent tabs.") }
        var match: AgentEventMatch
        switch AgentEventMatch.make(AgentEventFilter(spaces: add.filter.spaces, sites: add.filter.sites, exceptSites: add.filter.exceptSites, engines: add.filter.engines, tabKinds: add.filter.tabKinds), spaces: spaces) {
        case .success(let made): match = made
        case .failure(let error): throw AgentHookRefusal(error.message)
        }
        match.kinds = [event]
        let scope: BrowserEventScope = match.spaceIDs.map { ids in .places(spaces.filter { ids.contains($0.id) }.map { .space($0.id) }) } ?? .places([.persona(grant.personaID)])
        let filter = BrowserEventFilter(kinds: [event], scope: scope, sites: match.sites, exceptSites: match.exceptSites, engines: match.engines, tabKinds: match.tabKinds)
        let script = Data(add.script.utf8)
        guard script.count <= AgentHookAdd.scriptBytes else { throw AgentHookRefusal("A hook's script may hold at most 256 KB.") }
        let recordName = add.record ?? AgentRunRecord.activity.rawValue
        guard AgentHookAdd.records.contains(recordName), let record = AgentRunRecord(rawValue: recordName) else {
            throw AgentHookRefusal("Hooks from programs keep at least their activity, so record takes activity or session.")
        }
        if let delay = add.delay, !(0...60_000).contains(delay) { throw AgentHookRefusal("delay takes 0 to 60,000 milliseconds.") }
        if let timeout = add.timeout, !(1...600).contains(timeout) { throw AgentHookRefusal("timeout takes 1 to 600 seconds.") }
        var proposal = AgentHookProposal(name: name, event: event, loads: add.loads, filter: filter, delay: add.delay.map { .milliseconds($0) }, timeout: add.timeout.map { .seconds($0) },
                                         script: script, renamesTabs: add.permissions.contains("tabs.rename"), record: record)
        let usesAgent = add.permissions.contains("agent")
        guard usesAgent == (add.agent != nil) else { throw AgentHookRefusal(usesAgent ? "The agent permission needs agent options." : "Agent options need the agent permission.") }
        guard usesAgent, case .object(var fields)? = add.agent else { return proposal }
        if fields["tabAccess"] == .string(AgentRunTabAccess.page.rawValue) { throw AgentHookRefusal("Hooks from programs give their agent runs titles and addresses only, so Arch refuses tab access page.") }
        if fields["record"] == .string(AgentRunRecord.none.rawValue) { throw AgentHookRefusal("Hooks from programs keep at least their activity, so Arch refuses record none.") }
        fields["tabAccess"] = fields["tabAccess"] ?? .string(AgentRunTabAccess.title.rawValue)
        fields["tools"] = fields["tools"] ?? .array([.string(AgentToolCatalog.renameTab.name)])
        fields["record"] = fields["record"] ?? .string(record.rawValue)
        guard let options = try? AgentJSON.object(fields).decode(as: AgentRunOptions.self) else { throw AgentHookRefusal("The agent options need prompt and model, as arch.agent.run takes them.") }
        for tool in options.tools where AgentToolCatalog.tool(named: tool) == nil { throw AgentHookRefusal("Arch has no tool named \(tool).") }
        if let reason = agentGrant(for: options).refusal(for: options) { throw AgentHookRefusal(reason) }
        proposal.agent = options
        return proposal
    }
}

/// Why a proposal is outside the caps, as one sentence.
public struct AgentHookRefusal: Error, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// How the user answered a proposal.
public enum AgentHookDecision: Equatable, Sendable {
    /// The user allowed the hook with Touch ID or the login password, and the registry added it with this ID.
    case added(UUID)
    /// Don't Allow, a sheet that closed unanswered, Touch ID refused, or a proposal within a minute of a decline, with its sentence.
    case declined(String)
    /// A rule refused the hook, with its sentence.
    case refused(String)
}

/// The hook registry as the agents' service reaches it. `HookRegistry` conforms, and the app shell sets `AgentService.hookRegistrar` once both exist.
@MainActor
public protocol AgentHookRegistrar: AnyObject {
    /// The hooks this identity added, in list order.
    func hooks(addedBy client: AgentClientIdentity.Key) -> [AgentHookSummary]
    /// Shows the proposal sheet and returns once the user answers or the approval window closes.
    func propose(_ proposal: AgentHookProposal, from client: AgentClientIdentity, grant: AgentGrant) async -> AgentHookDecision
    /// Removes a hook this identity added; false for any other.
    func remove(_ id: UUID, addedBy client: AgentClientIdentity.Key) -> Bool
    /// The identities with a grant in force now: a hook whose program's grant ended pauses with `grantEnded`.
    func grantsDidChange(inForce clients: Set<AgentClientIdentity.Key>)
}

/// The approval sheets' button for sheets of other modules, such as the hook proposal sheet: no keyboard focus and no key equivalent unless given one, and with `requiresPointer`, only a pointer click that no other program posted.
public struct AgentApprovalButton: View {
    private let title: String
    private let keyEquivalent: String
    private let requiresPointer: Bool
    private let action: () -> Void

    public init(title: String, keyEquivalent: String = "", requiresPointer: Bool, action: @escaping () -> Void) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.requiresPointer = requiresPointer
        self.action = action
    }

    public var body: some View {
        AgentPointerButton(title: title, keyEquivalent: keyEquivalent, requiresPointer: requiresPointer, action: action)
    }
}
