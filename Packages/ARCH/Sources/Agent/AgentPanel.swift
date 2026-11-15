// The agent panel's conversation (docs/agents.md, In the browser ▸ The agent panel): a header with the session's title, its tool and model, the mode menu that lowers the mode at once and raises it only after a confirmation, the site scope, and Stop; the transcript, with the agent's replies rendered as the page reader renders them, thinking collapsed, one row per tool step from Arch's host with a button that shows its tab, questions and tab-sharing requests for the user, errors with one action, and the model and tokens under each turn; the queued messages with Remove; Take Over and Hand Back; and the field for the next message, whose Send becomes Stop while a turn runs. The browser places it in the trailing column.
import AgentControl
import AI
import SwiftUI

public struct AgentSessionPanel: View {
    @ObservedObject var service: AgentService
    @ObservedObject var session: AgentSession
    @ObservedObject private var approvals: AgentApprovals
    @ObservedObject private var settings = AIService.shared.settings
    let actions: AgentPanelActions
    private let keepTabs: (() -> Void)?
    @State private var problem: String?
    @State private var showsResearchPages = false
    @State private var researchChoice: AgentResearchPage?
    @State private var showsSharedTabs = false
    @State private var sharingProblem: String?
    @State private var raisingTo: AgentAccessLevel?
    @State private var deleting: AgentSession?

    public init(service: AgentService, session: AgentSession, actions: AgentPanelActions, keepTabs: (() -> Void)? = nil) {
        self.service = service
        self.session = session
        approvals = service.approvals
        self.actions = actions
        self.keepTabs = keepTabs
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            if !session.queuedMessages.isEmpty {
                Divider()
                queued
            }
            Divider()
            field
        }
        .environment(\.openURL, OpenURLAction { url in
            actions.openLink(url)
            return .handled
        })
        .confirmAgentSessionDeletion($deleting) { reviewed in
            Task { await service.deleteSession(reviewed.id) }
        }
        .confirmationDialog(raisingTo.map { "Raise this session to \($0.title)?" } ?? "", isPresented: Binding(get: { raisingTo != nil }, set: { if !$0 { raisingTo = nil } })) {
            if let raisingTo {
                Button("Raise to \(raisingTo.title)") { session.setMode(raisingTo) }
            }
            Button("Cancel", role: .cancel) { raisingTo = nil }
        } message: {
            Text(raisingTo == .actInAgentTabs
                 ? "The agent then acts in its agent tabs on sites in scope without asking. Sensitive steps still ask."
                 : "The agent then asks before each action instead of being refused.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if session.isTakenOver && !session.hasEnded {
                    Button("Hand Back", action: session.handBack).controlSize(.small)
                }
                if session.isTurnRunning {
                    Button("Stop", action: session.stop)
                        .controlSize(.small)
                }
                Menu {
                    if !session.isTakenOver {
                        Button("Take Over") { service.takeOver(session, showTab: actions.showTab) }
                            .disabled(session.hasEnded)
                    }
                    if service.canEditAttachments(of: session) {
                        Button("Open in Research Tab…") {
                            researchChoice = nil
                            showsResearchPages = true
                        }
                            .disabled(session.isTakenOver)
                    }
                    if let keepTabs { Button("Keep Tabs", action: keepTabs) }
                    Divider()
                    Button("Delete Session…", role: .destructive) { deleting = session }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .sheet(isPresented: $showsResearchPages) { researchPages }
                .help("Session")
                .accessibilityLabel("Session actions")
            }
            Text(details)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                modeMenu
                if service.canEditAttachments(of: session) {
                    Button("Shared Tabs (\(session.handles.sharedTabIDs.count))") {
                        sharingProblem = nil
                        showsSharedTabs.toggle()
                    }
                    .controlSize(.small)
                    .popover(isPresented: $showsSharedTabs) { sharedTabs }
                }
                Text(scopeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(scopeText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var researchPages: some View {
        AgentResearchSheet(pages: service.researchChoices(for: session) + service.manualOutlineLinks(for: session),
                           choice: $researchChoice, open: { await service.reviewManualResearchPage($0, in: session) },
                           close: { showsResearchPages = false })
    }

    private var sharedTabs: some View {
        let shared = session.handles.sharedTabIDs
        let visible = service.host.userTabs(in: session.personaID)
        let available = service.shareableTabs(for: session)
        let labels = AgentTabInfo.attachmentLabels(for: available)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Shared with this session").font(.headline)
            if shared.isEmpty { Text("No shared tabs.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shared, id: \.self) { id in
                        let tab = visible.first { $0.id == id }
                        HStack {
                            if let tab { AgentAttachmentLabel(tab: tab) }
                            else { Text("Unavailable tab") }
                            Spacer()
                            Button("Stop Sharing") { service.stopSharing(id, with: session) }
                        }
                    }
                }
            }.frame(maxHeight: shared.isEmpty ? 0 : min(160, CGFloat(shared.count) * 32))
            Menu("Share a Tab…") {
                ForEach(available) { tab in
                    Button(labels[tab.id] ?? tab.attachmentLabel) {
                        sharingProblem = service.share(tab, with: session) ? nil : "This tab changed or is no longer available."
                    }
                }
            }
            .disabled(available.isEmpty)
            if let sharingProblem { Text(sharingProblem).foregroundStyle(.secondary) }
        }
        .controlSize(.small)
        .padding(12)
        .frame(width: 320)
    }

    /// The tool and model, and the place as "Persona / Space".
    private var details: String {
        let model = session.model ?? session.requestedModel
        return [model.map(settings.title(of:)), service.place(of: session), session.statusText].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var scopeText: String {
        session.siteScope.isEmpty ? "No sites in scope yet" : "Scope: " + session.siteScope.joined(separator: ", ")
    }

    /// Lowering takes effect at once; raising asks first.
    private var modeMenu: some View {
        Menu(session.mode.title) {
            ForEach(AgentAccessLevel.allCases, id: \.self) { level in
                Button {
                    if level.rank > session.mode.rank { raisingTo = level } else { session.setMode(level) }
                } label: {
                    if level == session.mode { Label(level.title, systemImage: "checkmark") } else { Text(level.title) }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(session.hasEnded)
    }

    // MARK: Transcript

    private var transcript: some View {
        let cards = approvals.pending.filter { card in
            guard card.ownerID == session.id else { return false }
            switch card.kind {
            case .question, .shareSessionTab, .openSessionResearch: return true
            default: return false
            }
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.items) { item in
                        AgentTranscriptRow(item: item, actions: actions, settings: settings, readTab: { service.currentReadPage($0, in: session) },
                                           retry: item.id == session.transcript.retryableErrorID && !session.hasEnded ? { retry(item.id) } : nil)
                            .id(item.id)
                    }
                    if session.isTakenOver && !session.hasEnded {
                        note("You took over. The agent waits until you hand the session back.")
                    }
                    ForEach(cards) { card in
                        AgentApprovalCard(approval: card, approvals: approvals) {
                            if let tabID = card.tabID { actions.showTab(tabID) }
                        }
                        .id(card.id)
                    }
                }
                .padding(14)
            }
            // Row IDs become scroll targets after the transcript has a viewport.
            .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { ready in
                guard ready else { return }
                if let card = cards.first {
                    proxy.scrollTo(card.id, anchor: .top)
                } else if let last = session.items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: cards.first?.id) {
                if let card = cards.first { proxy.scrollTo(card.id, anchor: .top) }
            }
            .onChange(of: session.items.last) {
                if cards.isEmpty, let last = session.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func retry(_ errorID: UUID) {
        Task { await service.retry(session, errorID: errorID) }
    }

    private var queued: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Queued").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(Array(session.queuedMessages.enumerated()), id: \.offset) { index, message in
                HStack(alignment: .top) {
                    Text(message).font(.system(size: 12)).lineLimit(3)
                    Spacer()
                    Button("Remove") { session.removeQueuedMessage(at: index) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Field

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField(session.isTurnRunning ? "Queue a message" : "Message the agent", text: $session.messageDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                    .disabled(session.hasEnded)
                if session.isTurnRunning, session.messageDraft.isEmpty {
                    Button(action: session.stop) { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain)
                        .help("Stop")
                        .accessibilityLabel("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle") }
                        .buttonStyle(.plain)
                        .help("Send")
                        .accessibilityLabel("Send")
                        .disabled(session.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasEnded)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    /// A refused message, such as one that starts with `/` while Claude Code loads Arch's skills, stays in the field.
    private func send() {
        do {
            try session.sendDraft()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The user's research picker retains the selected source and exact address until they confirm.
struct AgentResearchSheet: View {
    let pages: [AgentResearchPage]
    @Binding var choice: AgentResearchPage?
    let open: (AgentResearchPage) async -> AgentManualResearchResult
    let close: () -> Void
    @State private var opening: Task<Void, Never>?
    @State private var problem: String?
    @State private var replacements: [AgentResearchPage: AgentResearchPage] = [:]

    private var presentedPages: [AgentResearchPage] {
        pages.map { replacements[$0] ?? $0 }
    }

    private var currentChoice: AgentResearchPage? {
        choice.flatMap { presentedPages.contains($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open in Research Tab").font(.headline)
            if pages.isEmpty {
                Text("Write an eligible web address in a message or share a tab to open it here.")
            } else {
                Picker("Address", selection: $choice) {
                    Text("Choose an address").tag(nil as AgentResearchPage?)
                    ForEach(presentedPages, id: \.self) { page in
                        let label = page.outlineLabel ?? page.url.absoluteString
                        Text(verbatim: page.originalOutlineChoice == nil ? label : "Updated · \(label)").tag(Optional(page))
                    }
                }
                .disabled(opening != nil)
            }
            if let choice = currentChoice {
                if let label = choice.outlineLabel {
                    Text(verbatim: label).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    Text(verbatim: choice.url.absoluteString)
                        .font(.body.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 64)
            }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") {
                    opening?.cancel()
                    close()
                }.keyboardShortcut(.cancelAction)
                Button("Open in Research Tab", action: confirm)
                    .disabled(currentChoice == nil || opening != nil)
            }
        }
        .padding(16).frame(width: 420)
        .onChange(of: pages) {
            replacements = replacements.filter { pages.contains($0.key) }
            if currentChoice == nil { choice = nil }
        }
        .onChange(of: choice) { if choice != nil { problem = nil } }
        .onDisappear { opening?.cancel() }
    }

    private func confirm() {
        guard opening == nil, let currentChoice else { return }
        opening = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let result = await open(currentChoice)
            guard !Task.isCancelled else { return }
            opening = nil
            switch result {
            case .opened:
                close()
            case .changed(let updated):
                if let original = updated.originalOutlineChoice { replacements[original] = updated }
                choice = nil
                problem = "This link’s address changed. Select the updated link to review its new address."
            case .staleLink:
                choice = nil
                problem = "This link is no longer available. Choose another address or ask the agent for a fresh page outline."
            case .unavailable:
                problem = "The address is unavailable or the session has reached its tab limit."
            }
        }
    }
}

/// One item of the transcript.
private struct AgentTranscriptRow: View {
    let item: AgentTranscriptItem
    let actions: AgentPanelActions
    let settings: AISettingsStore
    let readTab: (AgentReadPage) -> AgentTabInfo?
    let retry: (() -> Void)?

    var body: some View {
        switch item.kind {
        case .user(let text):
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .reply(let text):
            Text(actions.formatReply(text))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .thinking(let text):
            DisclosureGroup("Thinking") {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
        case .step(let step):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: step.status == .ok ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(step.status == .ok ? Color.secondary : Color.orange)
                Text(step.sentence)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let handle = step.tabHandle, let tabID = step.tabID {
                    Button(handle) { actions.showTab(tabID) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help("Show \(handle)")
                }
            }
        case .notice(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .error(let text, let action):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    button(for: action)
                        .controlSize(.small)
                }
            }
        case .turnFooter(let model, let usage):
            VStack(alignment: .leading, spacing: 4) {
                Text(footer(model: model, usage: usage))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                let available = item.pagesRead.compactMap { page -> (page: AgentReadPage, label: String)? in
                    guard let tab = readTab(page) else { return nil }
                    let title = tab.title.isEmpty ? (page.url.host ?? "") : tab.title
                    return (page, page.handle + " · " + title)
                }
                if !available.isEmpty {
                    DisclosureGroup("Pages read this turn") {
                        ForEach(available, id: \.page) { row in
                            Button(row.label) {
                                if let current = readTab(row.page) { actions.showReadTab(current.id) }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder private func button(for action: AgentErrorAction) -> some View {
        switch action {
        case .retry:
            if let retry { Button("Retry", action: retry) }
        case .signIn(let provider): Button("Sign In") { actions.signIn(provider) }
        case .openAISettings: Button("Open AI Settings", action: actions.openAISettings)
        }
    }

    /// The model and tokens; a subscription shows no cost (docs/agents.md, Usage and cost).
    private func footer(model: AIModelRef?, usage: AIUsage?) -> String {
        var parts = [model.map(settings.title(of:)) ?? "Done"]
        if let usage {
            parts.append("\((usage.inputTokens + usage.cachedInputTokens).formatted()) input and \(usage.outputTokens.formatted()) output tokens")
        }
        if let model, let provider = settings.providers.first(where: { $0.id == model.provider }) {
            if provider.commandLineAgent != nil {
                parts.append("Included in your subscription")
            } else if let usage, let cost = settings.estimatedCost(of: usage, on: model) {
                parts.append("about \(cost.amount.formatted(.currency(code: cost.currency).precision(.fractionLength(2...4))))")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension View {
    /// Both entry points name the conversation and explain which browser tabs will close.
    @MainActor public func confirmAgentSessionDeletion(_ selection: Binding<AgentSession?>, delete: @escaping (AgentSession) -> Void) -> some View {
        alert("Delete Session?", isPresented: Binding(get: { selection.wrappedValue != nil }, set: { if !$0 { selection.wrappedValue = nil } }),
              presenting: selection.wrappedValue) { session in
            Button("Delete Session", role: .destructive) { delete(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("This deletes “\(session.title)” and closes its remaining agent tabs. Tabs you kept stay open.")
        }
    }
}
