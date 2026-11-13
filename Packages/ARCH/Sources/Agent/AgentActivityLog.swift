// `agent-activity.json`: what agents did and what the user decided, for 90 days, without content (docs/agents.md, Storage). An entry names a tool call or a grant event, the client, the Persona, and the page's site at most: never page text, typed text, an address's path or query, or a screenshot. Settings ▸ AI ▸ Agents ▸ Activity lists it.
import Foundation

public struct AgentActivityEntry: Codable, Identifiable, Equatable, Sendable {
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
    }

    /// How a call was decided.
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

    public init(id: UUID = UUID(), date: Date, event: Event, grantID: UUID? = nil, sessionID: UUID? = nil, clientName: String, personaID: UUID? = nil, tool: String? = nil, toolClass: String? = nil,
                site: String? = nil, decision: Decision? = nil, rule: String? = nil, outcome: String? = nil) {
        self.id = id
        self.date = date
        self.event = event
        self.grantID = grantID
        self.sessionID = sessionID
        self.clientName = clientName
        self.personaID = personaID
        self.tool = tool
        self.toolClass = toolClass
        self.site = site
        self.decision = decision
        self.rule = rule
        self.outcome = outcome
    }

    /// The site an entry may name for an address: its host, without scheme, port, path, query, fragment, or credentials.
    public static func site(of url: URL) -> String? {
        url.host?.lowercased()
    }
}

@MainActor public final class AgentActivityLog: ObservableObject {
    public static let keptDays = 90

    private struct File: Codable {
        var version = 1
        var entries: [AgentActivityEntry]
    }

    /// Oldest first.
    @Published public private(set) var entries: [AgentActivityEntry] = []
    let fileURL: URL
    private let now: () -> Date
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL, now: @escaping () -> Date) {
        self.fileURL = fileURL
        self.now = now
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? Self.decoder.decode(File.self, from: data) {
            entries = file.entries
            dropOldEntries()
        } else {
            // As in the other stores, a file that does not decode is set aside, so that the first save does not overwrite it.
            let unreadable = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: unreadable)
            try? FileManager.default.moveItem(at: fileURL, to: unreadable)
        }
    }

    func record(_ entry: AgentActivityEntry) {
        entries.append(entry)
        dropOldEntries()
        scheduleSave()
    }

    /// Settings' Clear Activity.
    public func clear() {
        entries = []
        saveNow()
    }

    private func dropOldEntries() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keptDays, to: now()), entries.contains(where: { $0.date < cutoff }) else { return }
        entries.removeAll { $0.date < cutoff }
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
