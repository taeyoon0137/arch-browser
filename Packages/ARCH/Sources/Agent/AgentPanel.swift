// The agent panel shows an in-app session's conversation in the browser's trailing column (docs/agents.md, The agent panel).
// Its header shows the title, tool, model, site scope, and Stop. Lowering the mode acts at once; raising it asks first.
// The transcript shows replies as the page reader does, collapsed thinking, host tool steps with tab buttons, pending cards, errors, and each turn's model and tokens.
// Cards cover approvals, questions, tab sharing, downloads, and external links. Queued messages have Remove.
// Take Over and Hand Back control the session. The next-message field's Send becomes Stop while a turn runs.
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
            if !pendingCards.isEmpty {
                Divider()
                pendingDecisions
            }
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

    private var statusSentence: String {
        if !approvals.pending.filter({ $0.ownerID == session.id }).isEmpty { return "Waiting for your decision" }
        if session.isTakenOver && !session.hasEnded { return "You are in control" }
        if session.hasEnded { return "This task has ended" }
        if session.items.last.map({ if case .error = $0.kind { return true }; return false }) == true { return "This task needs attention" }
        return session.isTurnRunning ? "Working on your task" : "Ready for your next message"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentStateHeader(title: session.title, status: statusSentence) {
                if session.isTakenOver && !session.hasEnded {
                    AgentPrimaryAction(title: "Hand Back", action: session.handBack)
                } else if session.isTurnRunning {
                    AgentPrimaryAction(title: "Stop", action: session.stop)
                }
                Menu {
                    if !session.isTakenOver {
                        Button("Take Over") { service.takeOver(session, showTab: actions.showTab) }
                            .disabled(session.hasEnded)
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
                .help("Session")
                .accessibilityLabel("Session actions")
            }
            AgentTechnicalDetails(title: "Session details") {
                AgentSectionBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(details).help(details)
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
                        }
                        Text(scopeText).help(scopeText)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
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
            Menu("Share Tab") {
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

    private var pendingCards: [AgentApproval] { approvals.pending.filter { $0.ownerID == session.id } }

    private var pendingDecisions: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(pendingCards) { card in
                    AgentApprovalCard(approval: card, approvals: approvals) {
                        if let tabID = card.tabID { actions.showTab(tabID) }
                    }
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 280)
    }

    private var transcript: some View {
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
                }
                .padding(14)
            }
            // Row IDs become scroll targets after the transcript has a viewport.
            .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { ready in
                guard ready else { return }
                if let last = session.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: session.items.last) {
                if let last = session.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .reply(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(actions.formatReply(text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                sources
            }
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
            AgentTechnicalDetails(title: step.sentence) {
                HStack(spacing: 6) {
                    Text(step.tool + " · " + String(describing: step.status))
                    if let handle = step.tabHandle, let tabID = step.tabID {
                        Button(handle) { actions.showTab(tabID) }
                            .buttonStyle(.link)
                            .help("Show \(handle)")
                    }
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
                sources
            }
        }
    }

    private var sources: some View {
        let available = item.pagesRead.compactMap { page -> (page: AgentReadPage, label: String)? in
            guard let tab = readTab(page) else { return nil }
            let title = tab.title.isEmpty ? (page.url.host ?? "") : tab.title
            return (page, title)
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(available, id: \.page) { row in
                Button(row.label) {
                    if let current = readTab(row.page) { actions.showReadTab(current.id) }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.label)
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
