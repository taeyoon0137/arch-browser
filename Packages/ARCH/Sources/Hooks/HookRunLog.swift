// `hooks-activity.json` (`docs/hooks.md`, Run log): the hooks' runs for 30 days, without content. An entry names the hook, the event's kind, the subject's kind, the page's site at most, the Persona, the outcome, the duration, the actions by kind, and an agent run's model and token counts: never page text, a title, a name a hook gave, a prompt, a reply, a script's output, or an address's path or query. Hooks at Keep Nothing log no entry.
import AI
import Agent
import Events
import Foundation

public struct HookRunEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case completed, failed, timedOut, cancelled, skipped
    }

    /// Why a matching event started no run.
    public enum SkipReason: String, Codable, Sendable {
        /// The event came from the hook's own runs, or from three hooks' (Loop protection).
        case loop
        /// More than 10 runs for one subject, or 60 in all, within a minute.
        case rateLimit
        case dailyLimit
        /// The AI interface's daily limit for automatic requests or monthly spending limit.
        case budget
        /// More runs waited for a slot than the registry keeps, or the run's time passed before it got one.
        case dropped
    }

    /// The model of the run's last agent run and the tokens of all of them.
    public struct AgentUse: Codable, Equatable, Sendable {
        public var provider: AIProviderID
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int

        public init(provider: AIProviderID, model: String, inputTokens: Int, outputTokens: Int) {
            self.provider = provider
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    public var id: UUID
    public var date: Date
    public var hook: UUID
    public var event: BrowserEventKind
    /// The tab's kind for a tab event, `download`, or `window` for a space switch.
    public var subject: String
    /// The page's site, a host and never an address.
    public var site: String?
    public var persona: UUID
    public var outcome: Outcome
    /// A failure's code.
    public var code: String?
    public var reason: SkipReason?
    /// In seconds, for a run that started.
    public var duration: Double?
    /// The actions applied, or proposed in a test, by kind, such as `{"renameTab": 1}`.
    public var actions: [String: Int]?
    public var agent: AgentUse?
    public var test: Bool

    public init(id: UUID = UUID(), date: Date, hook: UUID, event: BrowserEventKind, subject: String, site: String?, persona: UUID, outcome: Outcome,
                code: String? = nil, reason: SkipReason? = nil, duration: Double? = nil, actions: [String: Int]? = nil, agent: AgentUse? = nil, test: Bool = false) {
        self.id = id
        self.date = date
        self.hook = hook
        self.event = event
        self.subject = subject
        self.site = site
        self.persona = persona
        self.outcome = outcome
        self.code = code
        self.reason = reason
        self.duration = duration
        self.actions = actions
        self.agent = agent
        self.test = test
    }

    /// The subject's kind as an entry names it.
    static func subject(of event: BrowserEvent) -> String {
        switch event.payload {
        case .downloadFinished: return "download"
        case .spaceSwitched: return "window"
        default: return event.tab?.kind.rawValue ?? "tab"
        }
    }
}

@MainActor public final class HookRunLog: ObservableObject {
    public static let keptDays = 30

    private struct File: Codable {
        var version = 1
        var entries: [HookRunEntry]
    }

    /// Oldest first.
    @Published public private(set) var entries: [HookRunEntry] = []
    public let fileURL: URL
    private let now: () -> Date
    private var pendingSave: DispatchWorkItem?

    public init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        // The Hooks module does not link AppKit, so it names the notification; an entry made just before quitting still reaches the file.
        NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
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

    func record(_ entry: HookRunEntry) {
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

    /// Combines rapid changes into one file write, like the agents' activity log.
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
