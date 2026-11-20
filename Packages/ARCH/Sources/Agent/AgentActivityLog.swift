// `agent-activity.json`: what agents did and what the user decided, for 90 days, without content (docs/agents.md, Storage). An entry names a tool call or a grant event, the client, the Persona, and the page's site at most: never page text, typed text, an address's path or query, or a screenshot. Settings ▸ AI ▸ Agents ▸ Activity lists it.
import AgentControl
import Foundation

/// A content-free record of an agent tool call or grant event.
public struct AgentActivityEntry: Codable, Identifiable, Equatable, Sendable {
    /// The activity or grant event recorded by an entry.
    public enum Event: String, Codable, Sendable {
        /// A tool call, with its tool, class, decision, and outcome.
        case toolCall
        case granted
        /// The grant's first call in a launch.
        case firstUse
        case revoked
        /// The client gave up its own grant.
        case released
        case expired
        /// The user chose Don't Allow on the grant sheet, or let it time out.
        case declined
        /// A connection failed the peer checks; `outcome` holds the reason.
        case refusedPeer
        /// An outside client's agent run (`docs/hooks.md`, arch-cli agent run and rename), with its model, outcome, and the refusal's rule; each of its tool calls has an entry of its own.
        case agentRun
    }

    /// How a call was decided.
    /// How Arch or the user decided a tool call.
    public enum Decision: String, Codable, Sendable {
        case auto
        case approved
        case approvedWithTouchID
        case denied
        case refused
        case timedOut
        /// The call answered `approvalPending` and went on; its own entry follows when it ends.
        case pending
    }

    public var id: UUID
    public var date: Date
    public var event: Event
    /// The grant the entry belongs to, also for a session an outside client started.
    public var grantID: UUID?
    /// The in-app session the entry belongs to.
    public var sessionID: UUID?
    /// A user-authored hook whose bounded run called a tool.
    public var hookID: UUID?
    public var hookRunID: UUID?
    public var clientName: String
    public var personaID: UUID?
    public var tool: String?
    /// The tool's class, `R`, `N`, `I`, or `S`.
    public var toolClass: String?
    /// The page's site, a host and never an address.
    public var site: String?
    public var decision: Decision?
    /// The rule that refused, such as `P16`.
    public var rule: String?
    /// The result's status, or the refusal's reason.
    public var outcome: String?
    /// An agent run's model, as "provider/model".
    public var model: String?
    /// The outside client's agent run the entry belongs to: the run's own entry and each of its tool calls, which count toward the run's limits rather than the client's 2,000 calls a day.
    public var runID: UUID?

    public init(id: UUID = UUID(), date: Date, event: Event, grantID: UUID? = nil, sessionID: UUID? = nil, hookID: UUID? = nil, hookRunID: UUID? = nil, clientName: String, personaID: UUID? = nil, tool: String? = nil, toolClass: String? = nil,
                site: String? = nil, decision: Decision? = nil, rule: String? = nil, outcome: String? = nil, model: String? = nil, runID: UUID? = nil) {
        self.id = id
        self.date = date
        self.event = event
        self.grantID = grantID
        self.sessionID = sessionID
        self.hookID = hookID
        self.hookRunID = hookRunID
        self.clientName = clientName
        self.personaID = personaID
        self.tool = tool
        self.toolClass = toolClass
        self.site = site
        self.decision = decision
        self.rule = rule
        self.outcome = outcome
        self.model = model
        self.runID = runID
    }

    /// The site an entry may name for an address: its host, without scheme, port, path, query, fragment, or credentials.
    public static func site(of url: URL) -> String? {
        url.host?.lowercased()
    }
}

/// Keeps up to 90 days and 10,000 content-free activity entries in `agent-activity.json`.
@MainActor public final class AgentActivityLog: ObservableObject {
    public static let keptDays = 90
    /// At most this many entries stay, oldest dropped first, so that each save and the launch read stay small.
    nonisolated public static let keptEntries = 10_000

    private struct File: Codable {
        var version = 1
        var entries: [AgentActivityEntry]
    }

    /// Oldest first.
    @Published public private(set) var entries: [AgentActivityEntry] = []
    let fileURL: URL
    private let now: () -> Date
    private let entryLimit: Int
    private var pendingSave: DispatchWorkItem?

    /// Tests give a smaller `keptEntries`.
    init(fileURL: URL, now: @escaping () -> Date, keptEntries: Int = AgentActivityLog.keptEntries) {
        self.fileURL = fileURL
        self.now = now
        entryLimit = keptEntries
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? Self.decoder.decode(File.self, from: data) {
            entries = file.entries
            dropOldEntries()
            dropOverflowingEntries()
        } else {
            // As in the other stores, a file that does not decode is set aside, so that the first save does not overwrite it.
            let unreadable = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: unreadable)
            try? FileManager.default.moveItem(at: fileURL, to: unreadable)
        }
    }

    /// Appends an entry, removes expired or excess entries, and schedules a save.
    func record(_ entry: AgentActivityEntry) {
        entries.append(entry)
        dropOldEntries()
        dropOverflowingEntries()
        scheduleSave()
    }

    /// Keeps only Arch's identifiers, catalog metadata, and a fixed outcome. The caller supplies no model or page strings.
    func recordTool(of hook: UUID, run: UUID?, persona: UUID, tool: AgentTool?, status: AgentResultStatus, cancelled: Bool, dryRun: Bool) {
        record(AgentActivityEntry(date: now(), event: .toolCall, hookID: hook, hookRunID: run, clientName: "Agent Hook", personaID: persona,
                                  tool: tool?.name, toolClass: tool?.toolClass.rawValue, decision: cancelled ? nil : Self.decision(for: status),
                                  outcome: Self.outcome(of: status, tool: tool, cancelled: cancelled, dryRun: dryRun)))
    }

    /// A tool call of an outside client's run, under the grant as the client's own calls are, with the run tab's site and the refusal's code, and with the outcomes of a hook run's calls.
    func recordTool(ofRun run: UUID, grant: UUID, client: String, persona: UUID, tool: AgentTool?, status: AgentResultStatus, code: String?, site: String?, cancelled: Bool, dryRun: Bool) {
        let decision = cancelled ? nil : Self.decision(for: status)
        record(AgentActivityEntry(date: now(), event: .toolCall, grantID: grant, clientName: client, personaID: persona, tool: tool?.name, toolClass: tool?.toolClass.rawValue,
                                  site: site, decision: decision, rule: decision == .refused ? code : nil, outcome: Self.outcome(of: status, tool: tool, cancelled: cancelled, dryRun: dryRun),
                                  runID: run))
    }

    /// Uses a fixed outcome for a cancelled or previewed tool call, or its status otherwise.
    private static func outcome(of status: AgentResultStatus, tool: AgentTool?, cancelled: Bool, dryRun: Bool) -> String {
        if cancelled { return "cancelled" }
        if dryRun && status == .ok && tool?.name == "rename_tab" { return "previewed" }
        return status.rawValue
    }

    /// Maps a tool result status to the decision recorded in activity.
    private static func decision(for status: AgentResultStatus) -> AgentActivityEntry.Decision {
        switch status {
        case .refused: return .refused
        case .denied: return .denied
        case .timeout: return .timedOut
        default: return .auto
        }
    }

    /// The tool calls under the grant today that its 2,000 calls a day count after a relaunch: all but its agent runs' calls, which count toward the runs' limits instead.
    func callsToday(of grantID: UUID, at date: Date) -> Int {
        entries.filter { $0.grantID == grantID && $0.event == .toolCall && $0.runID == nil && Calendar.current.isDate($0.date, inSameDayAs: date) }.count
    }

    /// Settings' Clear Activity.
    public func clear() {
        entries = []
        saveNow()
    }

    /// Removes entries older than the 90-day retention window.
    private func dropOldEntries() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keptDays, to: now()), entries.contains(where: { $0.date < cutoff }) else { return }
        entries.removeAll { $0.date < cutoff }
    }

    /// Drops the oldest entries above the configured count limit.
    private func dropOverflowingEntries() {
        guard entries.count > entryLimit else { return }
        entries.removeFirst(entries.count - entryLimit)
    }

    /// Combines rapid changes into one file write, like the AI usage store.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Cancels the pending save and writes the activity file atomically.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = try? Self.encoder.encode(File(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
