// The agent panel's conversation (docs/agents.md, In the browser ▸ The agent panel): a header with the session's title, its tool and model, the mode menu that lowers the mode at once and raises it only after a confirmation, the site scope, and Stop; the transcript, with the agent's replies rendered as the page reader renders them, thinking collapsed, one row per tool step from Arch's host with a button that shows its tab, errors with one action, and the model and tokens under each turn; the queued messages with Remove; Take Over and Hand Back; and the field for the next message, whose Send becomes Stop while a turn runs. The browser places it in the trailing column.
import AgentControl
import AI
import SwiftUI

public struct AgentSessionPanel: View {
    @ObservedObject var service: AgentService
    @ObservedObject var session: AgentSession
    @ObservedObject private var settings = AIService.shared.settings
    let actions: AgentPanelActions
    @State private var draft = ""
    @State private var problem: String?
    @State private var showsSharedTabs = false
    @State private var sharingProblem: String?
    @State private var raisingTo: AgentAccessLevel?

    public init(service: AgentService, session: AgentSession, actions: AgentPanelActions) {
        self.service = service
        self.session = session
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
                    Divider()
                    Button("Delete Session", role: .destructive) { Task { await service.deleteSession(session.id) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
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

    private var sharedTabs: some View {
        let shared = session.handles.sharedTabIDs
        let visible = service.host.userTabs(in: session.personaID)
        let available = service.shareableTabs(for: session)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Shared with this session").font(.headline)
            if shared.isEmpty { Text("No shared tabs.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shared, id: \.self) { id in
                        let tab = visible.first { $0.id == id }
                        HStack {
                            Text(tab.map(tabLabel) ?? "Unavailable tab").lineLimit(1)
                            Spacer()
                            Button("Stop Sharing") { service.stopSharing(id, with: session) }
                        }
                    }
                }
            }.frame(maxHeight: shared.isEmpty ? 0 : min(160, CGFloat(shared.count) * 32))
            Menu("Share a Tab…") {
                ForEach(available) { tab in
                    Button(tabLabel(tab)) {
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

    private func tabLabel(_ tab: AgentTabInfo) -> String {
        let host = tab.url?.host ?? ""
        if tab.title.isEmpty { return host.isEmpty ? "Tab" : host }
        return host.isEmpty || host == tab.title ? tab.title : "\(tab.title) · \(host)"
    }

    /// The tool and model, and the place as "Persona / Space".
    private var details: String {
        let model = session.model ?? session.requestedModel
        return [model.map(settings.title(of:)), service.place(of: session), stateText].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private var stateText: String? {
        if session.isTakenOver { return "You have control" }
        switch session.state {
        case .starting: return "Starting"
        case .running: return "Working"
        case .waitingForUser: return "Waiting for you"
        case .done: return nil
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
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
        ScrollViewReader { proxy in
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
                }
                .padding(14)
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
                TextField(session.isTurnRunning ? "Queue a message" : "Message the agent", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                    .disabled(session.hasEnded)
                if session.isTurnRunning, draft.isEmpty {
                    Button(action: session.stop) { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain)
                        .help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle") }
                        .buttonStyle(.plain)
                        .help("Send")
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasEnded)
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
            try session.send(draft)
            draft = ""
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
