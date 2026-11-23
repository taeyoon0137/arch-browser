// Approval cards wait for the user (docs/agents.md, Permissions, approvals, and injection defenses).
// They cover steps a rule or mode asks about, `request_approval`, `ask_user`, `hand_to_user`, and `request_tab`.
// They also cover an outside client's first rename of a shared tab (P19), downloads, external links, and file choosers that agent pages start.
// Each card ends when the user answers, time runs out, its page moves on, or the client's work ends. No answer means denial.
// Several cards for a client can wait together, grouped by page. Allow on This Page, Allow on <site>, and Allow for This Tab also answer other cards that offer the same choice.
// A sensitive allowance for an outside client requires Touch ID or the login password.
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
    case requestTab([AgentTabInfo], acting: Bool)
    /// The app session may read the one document the user explicitly chooses.
    case shareSessionTab([AgentTabInfo])
    /// A download a page in an agent tab started (P6).
    case download
    /// A link to another app that a page in an agent tab opened (P11), with the app's name.
    case externalApp(String)
    /// A file chooser that a page in an agent tab opened (P7).
    case fileChooser
    /// An outside client's first rename of a tab the user shared with it (P19), with the name as the card's exact text.
    case renameSharedTab
}

/// How a card ended.
public enum AgentApprovalAnswer: Equatable, Sendable {
    case allowOnce
    case allowOnPage
    case allowOnSite
    case allowDownloadsFromSite
    /// P19's allowance: the client renames this shared tab from now on without asking.
    case allowOnTab
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
        case .allowOnce, .allowOnPage, .allowOnSite, .allowDownloadsFromSite, .allowOnTab: return true
        default: return false
        }
    }

    /// The button's title.
    public func title(site: String?) -> String {
        switch self {
        case .allowOnce: return localized("Allow Once")
        case .allowOnPage: return localized("Allow on This Page")
        case .allowOnSite: return site.map { localized("Allow on \($0) for This Session") } ?? localized("Allow on This Site for This Session")
        case .allowDownloadsFromSite: return localized("Allow Downloads from This Site for This Session")
        case .allowOnTab: return localized("Allow for This Tab")
        case .deny: return localized("Deny")
        case .denyAndStop: return localized("Deny and Stop")
        case .reply: return localized("Reply\u{2026}")
        case .takeOver: return localized("Take Over")
        case .answer: return localized("Answer")
        case .done: return localized("Done")
        case .cancel: return localized("Cancel")
        case .tab: return localized("Share")
        case .timedOut: return localized("Not answered")
        case .withdrawn: return localized("The page moved on")
        case .ended: return localized("Ended")
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
    /// The tab's document the card is about: a new document there withdraws it, as when a shared tab reloads at the same address.
    var documentID: UUID?
    /// The tab's handle for the agent, as t3.
    public var tabHandle: String?
    public var site: String?
    /// The exact text or address that would be sent.
    public var exactText: String?
    /// Arch's note under the exact text, as what an allowance for the page or site lets the site receive.
    public var exactTextNote: String?
    /// A P13 card's question: the address it would open, whose parts the session has not seen the card marks.
    var addressQuestion: AgentAddressQuestion?
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

    /// Whether an answer counts only after Touch ID or the login password: Allow on a sensitive card of an outside client, and Share on an outside client's `request_tab`, which hands it one of the user's own tabs.
    public func needsAuthentication(for answer: AgentApprovalAnswer) -> Bool {
        guard isOutsideClient else { return false }
        if case .tab = answer { return true }
        return answer.allows && isSensitive
    }

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

/// Holds pending approval cards and their recent outcomes until each card is answered or ends.
@MainActor public final class AgentApprovals: ObservableObject {
    /// The cards waiting, oldest first.
    @Published public private(set) var pending: [AgentApproval] = []
    /// How the latest cards that are no longer waiting ended, at most `keptOutcomes`, for a call that asks after its card ended.
    @Published public private(set) var outcomes: [UUID: AgentApprovalAnswer] = [:]
    static let keptOutcomes = 100
    /// Called with each new card, so that the service shows it.
    var didAdd: ((AgentApproval) -> Void)?
    /// An owner's last waiting card ended.
    var didEnd: ((UUID) -> Void)?
    /// Touch ID or the login password, for the sensitive cards of outside clients.
    var authenticator: any AgentAuthenticating = AgentDeviceOwnerAuthentication()

    @Published private var questionDrafts: [UUID: String] = [:]
    private var completions: [UUID: (AgentApprovalAnswer, NSWindow?) -> Void] = [:]
    /// The waiting cards by ID; a card leaves once it ends, with its capture.
    private var cards: [UUID: AgentApproval] = [:]
    private var waiting: Set<UUID> = []
    /// The ended cards whose outcomes are kept, oldest first.
    private var endedOrder: [UUID] = []

    public init() {}

    /// Shows a card and waits until it ends. A call whose task was cancelled, as when its client's work ended while it prepared the card, opens none.
    func request(_ approval: AgentApproval) async -> AgentApprovalAnswer {
        if Task.isCancelled { return .ended("The client's work in Arch ended.") }
        let id = approval.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                open(approval) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .ended("The call was cancelled.")) }
        }
    }

    /// Registers the answer before publishing the card, including when a page opens one synchronously.
    func open(_ approval: AgentApproval, onAnswer: @escaping (AgentApprovalAnswer) -> Void) {
        open(approval, onAnswerInWindow: { answer, _ in onAnswer(answer) })
    }

    /// As `open(_:onAnswer:)`, with the window of the card the user answered, or nil when the card ended without the user, for a card whose Allow opens a sheet there (P7).
    func open(_ approval: AgentApproval, onAnswerInWindow onAnswer: @escaping (AgentApprovalAnswer, NSWindow?) -> Void) {
        let id = approval.id
        completions[id] = onAnswer
        cards[id] = approval
        waiting.insert(id)
        pending.append(approval)
        let delay = max(0, approval.deadline.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.finish(id, .timedOut) }
        }
        didAdd?(approval)
    }

    func draftAnswer(to id: UUID) -> String { questionDrafts[id] ?? "" }

    /// Saves text only for a pending question card.
    func setDraftAnswer(_ text: String, to id: UUID) {
        guard case .question? = cards[id]?.kind, isPending(id) else { return }
        questionDrafts[id] = text.isEmpty ? nil : text
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

    /// The user's answer from a card, in the window that shows the card. Allow on a sensitive card of an outside client counts only after Touch ID or the login password; a failure leaves the card waiting. Allow on This Page, on <site>, Allow Downloads, and Allow for This Tab also answer the other waiting cards of that page, site, or tab that offer the same. Says whether the answer counted.
    @discardableResult
    public func answer(_ id: UUID, with answer: AgentApprovalAnswer, in window: NSWindow? = nil) async -> Bool {
        guard let approval = cards[id], isPending(id) else { return false }
        if approval.needsAuthentication(for: answer) {
            // The sentence's page names stand in quotes whose closing quote inside is doubled (`AgentToolHost.actionSentence`), so a name cannot end the quote and add words of its own.
            guard await authenticator.authenticate(reason: localized("allow \(approval.clientName) to \(approval.action.prefix(1).lowercased() + approval.action.dropFirst())")) else { return false }
            guard isPending(id) else { return false }
        }
        finish(id, answer, window: window)
        let grouped = pending.filter { other in
            guard other.ownerID == approval.ownerID, other.offers.contains(answer) else { return false }
            switch answer {
            case .allowOnPage: return other.tabID != nil && other.tabID == approval.tabID && other.document == approval.document
            case .allowOnSite, .allowDownloadsFromSite: return other.site != nil && other.site == approval.site
            case .allowOnTab: return other.tabID != nil && other.tabID == approval.tabID
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

    /// Withdraws one waiting card, as when the document or attachment it is about changed.
    func withdraw(_ id: UUID) {
        guard isPending(id) else { return }
        finish(id, .withdrawn)
    }

    /// Ends the waiting cards of one client, or of every client, as denied: at Stop All Agents, a revocation, and quit.
    func end(owner ownerID: UUID? = nil, because reason: String) {
        for approval in pending where ownerID == nil || approval.ownerID == ownerID {
            finish(approval.id, .ended(reason))
        }
    }

    /// Withdraws one card, as for a call that its client cancelled with `tools/cancel`.
    func end(_ id: UUID, because reason: String) {
        finish(id, .ended(reason))
    }

    /// Ends the cards of the calls that came on a connection that closed, as when `arch-cli` is interrupted.
    func end(connection connectionID: UUID, because reason: String) {
        for approval in pending where approval.connectionID == connectionID {
            finish(approval.id, .ended(reason))
        }
    }

    /// Removes a waiting card, keeps its outcome, and notifies its completion and owner.
    private func finish(_ id: UUID, _ answer: AgentApprovalAnswer, window: NSWindow? = nil) {
        guard waiting.remove(id) != nil else { return }
        pending.removeAll { $0.id == id }
        let ownerID = cards[id]?.ownerID
        cards[id] = nil
        if questionDrafts[id] != nil { questionDrafts[id] = nil }
        outcomes[id] = answer
        endedOrder.append(id)
        if endedOrder.count > Self.keptOutcomes { outcomes[endedOrder.removeFirst()] = nil }
        completions.removeValue(forKey: id)?(answer, window)
        if let ownerID, !pending.contains(where: { $0.ownerID == ownerID }) { didEnd?(ownerID) }
    }
}
