// The agent panel's conversation (docs/agents.md, In the browser ▸ The agent panel): a header with the session's title, its tool and model, the mode menu that lowers the mode at once and raises it only after a confirmation, the site scope, and Stop; the transcript, with the agent's replies rendered as the page reader renders them, thinking collapsed, one row per tool step from Arch's host with a button that shows its tab, questions for the user, errors with one action, and the model and tokens under each turn; the queued messages with Remove; Take Over and Hand Back; and the field for the next message, whose Send becomes Stop while a turn runs. The browser places it in the trailing column.
import AgentControl
import AI
import SwiftUI

public struct AgentSessionPanel: View {
    @ObservedObject var service: AgentService
    @ObservedObject var session: AgentSession
    @ObservedObject private var approvals: AgentApprovals
    @ObservedObject private var settings = AIService.shared.settings
    let actions: AgentPanelActions
    @State private var problem: String?
    @State private var showsResearchPages = false
    @State private var researchChoice: AgentResearchPage?
    @State private var researchProblem: String?
    @State private var showsSharedTabs = false
    @State private var sharingProblem: String?
    @State private var raisingTo: AgentAccessLevel?
    @State private var deleting: AgentSession?

    public init(service: AgentService, session: AgentSession, actions: AgentPanelActions) {
        self.service = service
        self.session = session
        approvals = service.approvals
        self.actions = actions
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
                if session.isTakenOver {
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
                            researchProblem = nil
                            showsResearchPages = true
                        }.disabled(session.isTakenOver)
                    }
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
        let choices = service.researchChoices(for: session)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Open in Research Tab").font(.headline)
            if choices.isEmpty {
                Text("Write an eligible web address in a message or share a tab to open it here.")
            } else {
                Picker("Address", selection: $researchChoice) {
                    Text("Choose an address").tag(nil as AgentResearchPage?)
                    ForEach(choices, id: \.self) { page in
                        Text(verbatim: page.url.absoluteString).tag(Optional(page))
                    }
                }
            }
            if let researchChoice {
                ScrollView {
                    Text(verbatim: researchChoice.url.absoluteString)
                        .font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            }
            if let researchProblem { Text(researchProblem).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { showsResearchPages = false }.keyboardShortcut(.cancelAction)
                Button("Open in Research Tab") {
                    guard let researchChoice else { return }
                    if service.openResearchPage(researchChoice, in: session) { showsResearchPages = false }
                    else { researchProblem = "The address is unavailable or the session has reached its tab limit." }
                }
                .disabled(researchChoice.map(choices.contains) != true)
            }
        }.padding(16).frame(width: 420)
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
        let questions = approvals.pending.filter {
            guard $0.ownerID == session.id, case .question = $0.kind else { return false }
            return true
        }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.items) { item in
                        AgentTranscriptRow(item: item, actions: actions, settings: settings,
                                           retry: item.id == session.transcript.retryableErrorID && !session.hasEnded ? { retry(item.id) } : nil)
                            .id(item.id)
                    }
                    if session.isTakenOver {
                        note("You took over. The agent waits until you hand the session back.")
                    }
                    ForEach(questions) { question in
                        AgentApprovalCard(approval: question, approvals: approvals) {
                            if let tabID = question.tabID { actions.showTab(tabID) }
                        }
                        .id(question.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: questions.first?.id, initial: true) {
                if let question = questions.first { proxy.scrollTo(question.id, anchor: .top) }
            }
            .onChange(of: session.items.last) {
                if questions.isEmpty, let last = session.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
            Text(footer(model: model, usage: usage))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
