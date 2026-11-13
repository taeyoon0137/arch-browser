// The cards that wait for the user (docs/agents.md, Permissions, approvals, and injection defenses ▸ Approval interface): the steps a rule or the mode asks about, `request_approval`, `ask_user`, `hand_to_user`, `request_tab`, and the downloads and links to other apps that pages in agent tabs start. Each card waits until the user answers in Arch's own interface, its time runs out, its page moves on, or the client's work ends; an unanswered card is a denial. Several cards can wait per client, grouped by page: Allow on This Page and Allow on <site> answer the other cards of that page or site that offer them. A sensitive card of an outside client asks for Touch ID or the login password before Allow counts.
import AgentControl
import AppKit
import Foundation

/// What a card is about.
public enum AgentApprovalKind: Equatable, Sendable {
    /// An action or a navigation that a rule or the mode asks about.
    case step
    /// The agent's own `request_approval`, with its kind (`submit`, `purchase`, and so on).
    case requested(String)
    /// `ask_user`, with the answers to offer as buttons.
    case question([String])
    /// `hand_to_user`, with its reason.
    case handToUser(String)
    /// `request_tab`, with the tabs the user can pick and whether the agent asks to act in it.
    case requestTab([AgentTabChoice], acting: Bool)
    /// A download a page in an agent tab started (P6).
    case download
    /// A link to another app that a page in an agent tab opened (P11), with the app's name.
    case externalApp(String)
}

/// A tab `request_tab` offers.
public struct AgentTabChoice: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var host: String?

    public init(id: UUID, title: String, host: String?) {
        self.id = id
        self.title = title
        self.host = host
    }
}

/// How a card ended.
public enum AgentApprovalAnswer: Equatable, Sendable {
    case allowOnce
    case allowOnPage
    case allowOnSite
    case allowDownloadsFromSite
    case deny
    case denyAndStop
    /// An instruction in place of yes or no.
    case reply(String)
    /// The user does the step in the tab.
    case takeOver
    /// `ask_user`'s answer.
    case answer(String)
    /// `hand_to_user`'s Done or Cancel, with what the user wrote.
    case done(String)
    case cancel(String)
    /// `request_tab`'s pick.
    case tab(UUID)
    /// Nobody answered in time.
    case timedOut
    /// The page moved on before the user answered.
    case withdrawn
    /// The client's work ended first, for this reason: Stop All Agents, a revocation, the client leaving, or quit.
    case ended(String)

    /// Whether the answer lets the step go ahead.
    public var allows: Bool {
        switch self {
        case .allowOnce, .allowOnPage, .allowOnSite, .allowDownloadsFromSite: return true
        default: return false
        }
    }

    /// The button's title.
    public func title(site: String?) -> String {
        switch self {
        case .allowOnce: return "Allow Once"
        case .allowOnPage: return "Allow on This Page"
        case .allowOnSite: return "Allow on \(site ?? "This Site") for This Session"
        case .allowDownloadsFromSite: return "Allow Downloads from This Site for This Session"
        case .deny: return "Deny"
        case .denyAndStop: return "Deny and Stop"
        case .reply: return "Reply\u{2026}"
        case .takeOver: return "Take Over"
        case .answer: return "Answer"
        case .done: return "Done"
        case .cancel: return "Cancel"
        case .tab: return "Share"
        case .timedOut: return "Not answered"
        case .withdrawn: return "The page moved on"
        case .ended: return "Ended"
        }
    }
}

/// One card. Its first lines are facts the host computed; the agent's own words follow under "The agent says:".
public struct AgentApproval: Identifiable {
    public let id: UUID
    /// The grant or session whose client asks.
    public var ownerID: UUID
    public var clientName: String
    public var isOutsideClient: Bool
    public var kind: AgentApprovalKind
    /// The rules that ask, none when the mode alone asks.
    public var rules: [AgentRule]
    public var isSensitive: Bool
    /// The buttons, in order. A sensitive card offers only Allow Once, Deny, Deny and Stop, Reply, and Take Over.
    public var offers: [AgentApprovalAnswer]
    /// The step in a sentence, as "Click “Place order” on shop.example".
    public var action: String
    public var tabID: UUID?
    /// The tab's handle for the agent, as t3.
    public var tabHandle: String?
    public var site: String?
    /// The exact text or address that would be sent.
    public var exactText: String?
    /// The agent's explanation, its question, or its message.
    public var agentSays: String?
    /// A viewport capture with the element's box marked, which only the user sees, so it is not painted over.
    public var capture: NSImage?
    /// The agent's text names a secret, so the card leads with `AgentPolicy.secretWarning`.
    public var namesSecret: Bool
    /// The connection of the call that asks, so that the card ends when the client leaves; nil for a card a page's download or link opened.
    public var connectionID: UUID?
    /// The tab's document count when the card opened; the card is withdrawn once the tab loads another. Nil for cards that the page moving on does not end.
    public var document: Int?
    public var createdAt: Date
    public var deadline: Date

    public init(id: UUID = UUID(), ownerID: UUID, clientName: String, isOutsideClient: Bool, kind: AgentApprovalKind, rules: [AgentRule] = [], isSensitive: Bool,
                offers: [AgentApprovalAnswer], action: String, tabID: UUID? = nil, tabHandle: String? = nil, site: String? = nil, exactText: String? = nil, agentSays: String? = nil,
                capture: NSImage? = nil, connectionID: UUID? = nil, document: Int? = nil, createdAt: Date, deadline: Date) {
        self.id = id
        self.ownerID = ownerID
        self.clientName = clientName
        self.isOutsideClient = isOutsideClient
        self.kind = kind
        self.rules = rules
        self.isSensitive = isSensitive
        self.offers = offers
        self.action = action
        self.tabID = tabID
        self.tabHandle = tabHandle
        self.site = site
        self.exactText = exactText
        self.agentSays = agentSays
        self.capture = capture
        namesSecret = agentSays.map(AgentPolicy.cardTextNamesSecret) ?? false
        self.connectionID = connectionID
        self.document = document
        self.createdAt = createdAt
        self.deadline = deadline
    }

    /// Whether Allow on this card asks for Touch ID or the login password first: a sensitive card of an outside client, so that a program driving the interface cannot approve.
    public var needsAuthentication: Bool { isSensitive && isOutsideClient }

    /// The buttons of a step card: a sensitive one's, or with the allowances the policy offers.
    static func offers(for ask: AgentAsk) -> [AgentApprovalAnswer] {
        if ask.isSensitive { return [.allowOnce, .deny, .denyAndStop, .reply(""), .takeOver] }
        var offers: [AgentApprovalAnswer] = [.allowOnce]
        if ask.offersPage { offers.append(.allowOnPage) }
        if ask.offersSite { offers.append(.allowOnSite) }
        if ask.offersDownloads { offers.append(.allowDownloadsFromSite) }
        return offers + [.deny, .denyAndStop, .reply("")]
    }
}

@MainActor public final class AgentApprovals: ObservableObject {
    /// The cards waiting, oldest first.
    @Published public private(set) var pending: [AgentApproval] = []
    /// How each card that is no longer waiting ended, for the panel.
    @Published public private(set) var outcomes: [UUID: AgentApprovalAnswer] = [:]
    /// Called with each new card, so that the service shows it.
    var didAdd: ((AgentApproval) -> Void)?
    /// Touch ID or the login password, for the sensitive cards of outside clients.
    var authenticator: any AgentAuthenticating = AgentDeviceOwnerAuthentication()

    private var waiters: [UUID: CheckedContinuation<AgentApprovalAnswer, Never>] = [:]
    private var cards: [UUID: AgentApproval] = [:]
    private var waiting: Set<UUID> = []

    public init() {}

    /// Shows a card and waits until it ends.
    func request(_ approval: AgentApproval) async -> AgentApprovalAnswer {
        show(approval)
        return await answer(of: approval.id)
    }

    /// Shows a card now and returns the task that waits until it ends, for cards that a page's report opens while the engine waits for its answer.
    func open(_ approval: AgentApproval) -> Task<AgentApprovalAnswer, Never> {
        show(approval)
        return Task { await answer(of: approval.id) }
    }

    private func show(_ approval: AgentApproval) {
        cards[approval.id] = approval
        waiting.insert(approval.id)
        pending.append(approval)
        let delay = max(0, approval.deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.finish(approval.id, .timedOut) }
        }
        didAdd?(approval)
    }

    /// How a card ended, once it has.
    private func answer(of id: UUID) async -> AgentApprovalAnswer {
        if let outcome = outcomes[id] { return outcome }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    public func isPending(_ id: UUID) -> Bool {
        waiting.contains(id)
    }

    public func approval(_ id: UUID) -> AgentApproval? {
        cards[id]
    }

    /// The waiting cards of one client, grouped by page: one group per tab and document, in the order their first cards came, then the cards about no tab.
    public func groups(of ownerID: UUID) -> [[AgentApproval]] {
        var groups: [[AgentApproval]] = []
        for approval in pending where approval.ownerID == ownerID {
            if let index = groups.firstIndex(where: { $0[0].tabID != nil && $0[0].tabID == approval.tabID && $0[0].document == approval.document }) {
                groups[index].append(approval)
            } else {
                groups.append([approval])
            }
        }
        return groups
    }

    /// The user's answer from a card. Allow on a sensitive card of an outside client counts only after Touch ID or the login password; a failure leaves the card waiting. Allow on This Page, on <site>, and Allow Downloads also answer the other waiting cards of that page or site that offer the same. Says whether the answer counted.
    @discardableResult
    public func answer(_ id: UUID, with answer: AgentApprovalAnswer) async -> Bool {
        guard let approval = cards[id], isPending(id) else { return false }
        if answer.allows, approval.needsAuthentication {
            guard await authenticator.authenticate(reason: "allow \(approval.clientName) to \(approval.action.prefix(1).lowercased() + approval.action.dropFirst())") else { return false }
            guard isPending(id) else { return false }
        }
        finish(id, answer)
        let grouped = pending.filter { other in
            guard other.ownerID == approval.ownerID, other.offers.contains(answer) else { return false }
            switch answer {
            case .allowOnPage: return other.tabID != nil && other.tabID == approval.tabID && other.document == approval.document
            case .allowOnSite, .allowDownloadsFromSite: return other.site != nil && other.site == approval.site
            default: return false
            }
        }
        for other in grouped { finish(other.id, answer) }
        return true
    }

    /// Withdraws the cards about a tab's earlier document, or every card about the tab when it closed or left the client: their calls fail as stale.
    func withdraw(tab tabID: UUID, owner ownerID: UUID, document: Int?) {
        for approval in pending where approval.ownerID == ownerID && approval.tabID == tabID {
            if let document, let asked = approval.document, asked >= document { continue }
            if document != nil, approval.document == nil { continue }
            finish(approval.id, .withdrawn)
        }
    }

    /// Ends the waiting cards of one client, or of every client, as denied: at Stop All Agents, a revocation, and quit.
    func end(owner ownerID: UUID? = nil, because reason: String) {
        for approval in pending where ownerID == nil || approval.ownerID == ownerID {
            finish(approval.id, .ended(reason))
        }
    }

    /// Ends the cards of the calls that came on a connection that closed, as when `arch-cli` is interrupted.
    func end(connection connectionID: UUID, because reason: String) {
        for approval in pending where approval.connectionID == connectionID {
            finish(approval.id, .ended(reason))
        }
    }

    private func finish(_ id: UUID, _ answer: AgentApprovalAnswer) {
        guard waiting.remove(id) != nil else { return }
        pending.removeAll { $0.id == id }
        outcomes[id] = answer
        waiters.removeValue(forKey: id)?.resume(returning: answer)
    }
}
