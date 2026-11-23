// The agent panel shows an in-app session's conversation in the browser's trailing column (docs/agents.md, The agent panel).
// Its header shows the title, a plain status sentence, and Stop; Session details hold the model, place, mode, shared tabs, and sites. Lowering the mode acts at once; raising it asks first.
// The transcript shows the user's messages in bubbles at the trailing edge, replies as the page reader does, collapsed thinking, steps with a mark and plain words for a step that did not go through, errors, and each turn's model and tokens.
// The oldest waiting card is pinned above the message field and takes only the room it needs, up to a share of the panel; its buttons stay in view while its facts scroll.
// Cards cover approvals, questions, tab sharing, downloads, and external links. Queued messages have Remove.
// Take Over and Hand Back control the session. The next-message field's Send becomes Stop while a turn runs.
import AgentControl
import AI
import SwiftUI

/// Shows an in-app agent session, its decisions, transcript, and message field.
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
    @State private var panelHeight: CGFloat = 0

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
            if let card = pendingCards.first {
                Divider()
                // The decision takes the room it needs, up to its share of the panel; the transcript keeps the rest.
                AgentHeightCap(maxHeight: max(AgentPanelMetrics.pendingMinHeight, panelHeight * AgentPanelMetrics.pendingShare)) {
                    pendingDecision(card)
                }
                .layoutPriority(1)
            }
            if !session.queuedMessages.isEmpty {
                Divider()
                queued
            }
            Divider()
            field
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        .environment(\.openURL, OpenURLAction { url in
            actions.openLink(url)
            return .handled
        })
        .confirmAgentSessionDeletion($deleting) { reviewed in
            Task { await service.deleteSession(reviewed.id) }
        }
        .confirmationDialog(raisingTo.map { localized("Raise this session to \($0.localizedTitle)?") } ?? "", isPresented: Binding(get: { raisingTo != nil }, set: { if !$0 { raisingTo = nil } })) {
            if let raisingTo {
                Button(localized("Raise to \(raisingTo.title)")) { session.setMode(raisingTo) }
            }
            Button(localized("Cancel"), role: .cancel) { raisingTo = nil }
        } message: {
            Text(raisingTo == .actInAgentTabs
                 ? localized("The agent then acts in its agent tabs on sites in scope without asking. Sensitive steps still ask.")
                 : localized("The agent then asks before each action instead of being refused."))
        }
    }

    // MARK: Header

    /// The session state shown below its title, with pending decisions taking priority.
    private var statusSentence: String {
        if !approvals.pending.filter({ $0.ownerID == session.id }).isEmpty { return localized("Waiting for your decision") }
        if session.isTakenOver && !session.hasEnded { return localized("You are in control") }
        if session.hasEnded { return localized("This task has ended") }
        if session.items.last.map({ if case .error = $0.kind { return true }; return false }) == true { return localized("This task needs attention") }
        return session.isTurnRunning ? localized("Working on your task") : localized("Ready for your next message")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentStateHeader(title: session.title, status: statusSentence) {
                if session.isTakenOver && !session.hasEnded {
                    AgentPrimaryAction(title: localized("Hand Back"), action: session.handBack)
                } else if session.isTurnRunning {
                    AgentPrimaryAction(title: localized("Stop"), action: session.stop)
                }
                Menu {
                    if !session.isTakenOver {
                        Button(localized("Take Over")) { service.takeOver(session, showTab: actions.showTab) }
                            .disabled(session.hasEnded)
                    }
                    if let keepTabs { Button(localized("Keep Tabs"), action: keepTabs) }
                    Divider()
                    Button(localized("Delete Session…"), role: .destructive) { deleting = session }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(localized("Session"))
                .accessibilityLabel(localized("Session actions"))
            }
            AgentTechnicalDetails(title: localized("Session details")) {
                AgentSectionBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(details)
                            .font(.system(size: AgentPanelMetrics.detailSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            modeMenu
                            if service.canEditAttachments(of: session) {
                                Button(localized("Shared Tabs (\(session.handles.sharedTabIDs.count))")) {
                                    sharingProblem = nil
                                    showsSharedTabs.toggle()
                                }
                                .controlSize(.small)
                                .popover(isPresented: $showsSharedTabs) { sharedTabs }
                            }
                        }
                        Text(scopeText)
                            .font(.system(size: AgentPanelMetrics.detailSize))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, AgentPanelMetrics.inset)
            .padding(.bottom, 8)
        }
    }

    /// Lists tabs shared with the session and lets the user change that list.
    private var sharedTabs: some View {
        let shared = session.handles.sharedTabIDs
        let visible = service.host.userTabs(in: session.personaID)
        let available = service.shareableTabs(for: session)
        let labels = AgentTabInfo.attachmentLabels(for: available)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Shared with this session", bundle: .module).font(.headline)
            if shared.isEmpty { Text("No shared tabs.", bundle: .module).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shared, id: \.self) { id in
                        let tab = visible.first { $0.id == id }
                        HStack {
                            if let tab { AgentAttachmentLabel(tab: tab) }
                            else { Text("Unavailable tab", bundle: .module) }
                            Spacer()
                            Button(localized("Stop Sharing")) { service.stopSharing(id, with: session) }
                        }
                    }
                }
            }.frame(maxHeight: shared.isEmpty ? 0 : min(160, CGFloat(shared.count) * 32))
            Menu(localized("Share Tab")) {
                ForEach(available) { tab in
                    Button(labels[tab.id] ?? tab.attachmentLabel) {
                        sharingProblem = service.share(tab, with: session) ? nil : localized("This tab changed or is no longer available.")
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

    /// The tool and model, and the place as "Persona / Space". The header's sentence already says how the task stands.
    private var details: String {
        let model = session.model ?? session.requestedModel
        return [model.map(settings.title(of:)), service.place(of: session)].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var scopeText: String {
        session.siteScope.isEmpty ? localized("The agent has no sites to work on yet.") : localized("Sites the agent works on: \(session.siteScope.joined(separator: ", "))")
    }

    /// Lowering takes effect at once; raising asks first.
    private var modeMenu: some View {
        Menu(session.mode.localizedTitle) {
            ForEach(AgentAccessLevel.allCases, id: \.self) { level in
                Button {
                    if level.rank > session.mode.rank { raisingTo = level } else { session.setMode(level) }
                } label: {
                    if level == session.mode { Label(level.localizedTitle, systemImage: "checkmark") } else { Text(level.localizedTitle) }
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

    /// The decision to make now, the oldest waiting card, pinned above the message field. The card keeps its buttons in view and scrolls its own facts; the next card follows once it is answered.
    private func pendingDecision(_ card: AgentApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentApprovalCard(approval: card, approvals: approvals) {
                if let tabID = card.tabID { actions.showTab(tabID) }
            }
            // A card for each request, so each answer resets its own fields.
            .id(card.id)
            if pendingCards.count > 1 {
                Text(pendingCards.count == 2 ? localized("1 more request waits after this one.") : localized("\(pendingCards.count - 1) more requests wait after this one."))
                    .font(.system(size: AgentPanelMetrics.detailSize))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AgentPanelMetrics.inset)
        .padding(.vertical, 10)
    }

    /// Shows transcript items and scrolls to the newest one when they change.
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
                        note(localized("You took over. The agent waits until you hand the session back."))
                    }
                }
                .padding(AgentPanelMetrics.inset)
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
            Text("Queued", bundle: .module).font(.system(size: AgentPanelMetrics.detailSize, weight: .medium)).foregroundStyle(.secondary)
            ForEach(Array(session.queuedMessages.enumerated()), id: \.offset) { index, message in
                HStack(alignment: .top) {
                    Text(message).font(.system(size: AgentPanelMetrics.supportingSize)).lineLimit(3)
                    Spacer()
                    Button(localized("Remove")) { session.removeQueuedMessage(at: index) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, AgentPanelMetrics.inset)
        .padding(.vertical, 8)
    }

    // MARK: Field

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem {
                Text(problem)
                    .font(.system(size: AgentPanelMetrics.detailSize))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField(session.isTurnRunning ? localized("Queue a message") : localized("Message the agent"), text: $session.messageDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: AgentPanelMetrics.bodySize))
                    .lineLimit(1...5)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                    .disabled(session.hasEnded)
                if session.isTurnRunning, session.messageDraft.isEmpty {
                    Button(action: session.stop) { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain)
                        .help(localized("Stop"))
                        .accessibilityLabel(localized("Stop"))
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle") }
                        .buttonStyle(.plain)
                        .help(localized("Send"))
                        .accessibilityLabel(localized("Send"))
                        .disabled(session.messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasEnded)
                }
            }
        }
        .padding(.leading, AgentPanelMetrics.inset)
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
            .font(.system(size: AgentPanelMetrics.detailSize))
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
            // The user's own words sit in a bubble at the trailing edge; the agent's replies are plain text at the leading edge.
            HStack(spacing: 0) {
                Spacer(minLength: AgentPanelMetrics.bubbleLeadingRoom)
                Text(text)
                    .font(.system(size: AgentPanelMetrics.bodySize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AgentPanelMetrics.bubblePadding)
                    .background(RoundedRectangle(cornerRadius: AgentPanelMetrics.boxRadius, style: .continuous).fill(AgentPanelFill.user))
                    .accessibilityLabel(localized("You: \(text)"))
            }
        case .reply(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(actions.formatReply(text))
                    .font(.system(size: AgentPanelMetrics.bodySize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                sources
            }
        case .thinking(let text):
            AgentTechnicalDetails(title: localized("Thinking")) {
                Text(text)
                    .font(.system(size: AgentPanelMetrics.detailSize))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .step(let step):
            stepRow(step)
        case .notice(let text):
            Text(text)
                .font(.system(size: AgentPanelMetrics.detailSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .error(let text, let action):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: AgentPanelMetrics.supportingSize))
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
                    .font(.system(size: AgentPanelMetrics.detailSize))
                    .foregroundStyle(.secondary)
                sources
            }
        }
    }

    /// A step as one quiet line: its mark, the host's sentence, what went wrong in plain words, and the tab it acted in.
    private func stepRow(_ step: AgentStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: step.status.symbol)
                .foregroundStyle(step.status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.sentence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let words = step.status.plainWords {
                    Text(words).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            if step.tabHandle != nil, let tabID = step.tabID {
                Button(localized("Show Tab")) { actions.showTab(tabID) }
                    .buttonStyle(.link)
                    .help(localized("Show the tab this step used"))
            }
        }
        .font(.system(size: AgentPanelMetrics.detailSize))
    }

    /// Links to tabs read for this transcript item while they remain available.
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
                .font(.system(size: AgentPanelMetrics.detailSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.label)
            }
        }
    }

    /// Builds the available recovery action for a transcript error.
    @ViewBuilder private func button(for action: AgentErrorAction) -> some View {
        switch action {
        case .retry:
            if let retry { Button(localized("Retry"), action: retry) }
        case .signIn(let provider): Button(localized("Sign In")) { actions.signIn(provider) }
        case .openAISettings: Button(localized("Open AI Settings"), action: actions.openAISettings)
        }
    }

    /// The model and tokens; a subscription shows no cost (docs/agents.md, Usage and cost).
    private func footer(model: AIModelRef?, usage: AIUsage?) -> String {
        var parts = [model.map(settings.title(of:)) ?? localized("Done")]
        if let usage {
            parts.append(localized("\((usage.inputTokens + usage.cachedInputTokens).formatted()) input and \(usage.outputTokens.formatted()) output tokens"))
        }
        if let model, let provider = settings.providers.first(where: { $0.id == model.provider }) {
            if provider.commandLineAgent != nil {
                parts.append(localized("Included in your subscription"))
            } else if let usage, let cost = settings.estimatedCost(of: usage, on: model) {
                parts.append(localized("about \(cost.amount.formatted(.currency(code: cost.currency).precision(.fractionLength(2...4))))"))
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension View {
    /// Both entry points name the conversation and explain which browser tabs will close.
    @MainActor public func confirmAgentSessionDeletion(_ selection: Binding<AgentSession?>, delete: @escaping (AgentSession) -> Void) -> some View {
        alert(localized("Delete Session?"), isPresented: Binding(get: { selection.wrappedValue != nil }, set: { if !$0 { selection.wrappedValue = nil } }),
              presenting: selection.wrappedValue) { session in
            Button(localized("Delete Session"), role: .destructive) { delete(session) }
            Button(localized("Cancel"), role: .cancel) {}
        } message: { session in
            Text("This deletes “\(session.title)” and closes its remaining agent tabs. Tabs you kept stay open.", bundle: .module)
        }
    }
}
