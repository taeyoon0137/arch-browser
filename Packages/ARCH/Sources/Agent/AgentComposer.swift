// The composer that starts an in-app session (docs/agents.md, In the browser ▸ Starting a session; Model choice and fallbacks): the task, the selected tab attached as a removable chip unless its site is excluded, the place as "Persona / Space" with Use the Agents Persona, the mode from Settings, the model menu with the `agent` route's first model, and the effort menu where the tool takes one. Without a model that can run a session, it says how to add Claude Code or Codex. A task that starts with `/` in a Claude Code session with Arch's skills is refused and stays in the field.
import AgentControl
import AI
import SwiftUI

/// What the browser gives the panel: how replies render as the page reader renders them, and the actions that leave the panel.
public struct AgentPanelActions {
    /// Inline Markdown without images, each link showing its full address.
    public var formatReply: (String) -> AttributedString
    public var openLink: (URL) -> Void
    /// Selects a tab of the session's, as a step's button does.
    public var showTab: (UUID) -> Void
    public var openAISettings: () -> Void
    /// Opens the built-in terminal with the tool's sign-in typed but not run.
    public var signIn: (AIProviderID) -> Void

    public init(formatReply: @escaping (String) -> AttributedString, openLink: @escaping (URL) -> Void, showTab: @escaping (UUID) -> Void,
                openAISettings: @escaping () -> Void, signIn: @escaping (AIProviderID) -> Void) {
        self.formatReply = formatReply
        self.openLink = openLink
        self.showTab = showTab
        self.openAISettings = openAISettings
        self.signIn = signIn
    }
}

/// Where a new session starts and what it starts with. Each one is a new draft.
public struct AgentComposerContext: Equatable, Identifiable {
    public let id = UUID()
    public var personaID: UUID
    public var spaceID: UUID
    /// "Persona / Space".
    public var place: String
    /// The selected tab, which the composer attaches unless its site is excluded from AI.
    public var tab: AgentTabInfo?
    public var text: String

    public init(personaID: UUID, spaceID: UUID, place: String, tab: AgentTabInfo?, text: String = "") {
        self.personaID = personaID
        self.spaceID = spaceID
        self.place = place
        self.tab = tab
        self.text = text
    }
}

public struct AgentComposer: View {
    @ObservedObject var service: AgentService
    @ObservedObject private var settings = AIService.shared.settings
    let context: AgentComposerContext
    let actions: AgentPanelActions
    let didStart: (AgentSession) -> Void
    @State private var text: String
    @State private var attachesTab = true
    @State private var usesAgentsPersona = false
    @State private var mode: AgentAccessLevel?
    @State private var model: AIModelRef?
    @State private var effort: String?
    @State private var effortLevels: [String] = []
    @State private var problem: String?

    public init(service: AgentService, context: AgentComposerContext, actions: AgentPanelActions, didStart: @escaping (AgentSession) -> Void) {
        self.service = service
        self.context = context
        self.actions = actions
        self.didStart = didStart
        _text = State(initialValue: context.text)
    }

    private var models: [AIModelRef] { service.agentModels() }

    private var attachableTab: AgentTabInfo? {
        guard let tab = context.tab, let url = tab.url, AgentSite.of(url) != nil, settings.allowsAI(on: url) else { return nil }
        return tab
    }

    public var body: some View {
        if models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Claude Code or Codex in Settings \u{25B8} AI")
                    .font(.system(size: 13, weight: .medium))
                Text("Agent tasks run on your own Claude or ChatGPT subscription through its command-line tool, signed in in Arch\u{2019}s terminal.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Open AI Settings", action: actions.openAISettings)
                    .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TextField("What should the agent do?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...10)
                    .onSubmit(start)
                if let tab = attachableTab, attachesTab, !usesAgentsPersona {
                    AgentTabChip(title: tab.title.isEmpty ? (tab.url?.host ?? "Tab") : tab.title) { attachesTab = false }
                }
                Divider()
                options
                if let warning = codexInstructionsWarning {
                    note(warning)
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Start", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: selectedModel) { await loadEffortLevels() }
        }
    }

    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                label("In")
                VStack(alignment: .leading, spacing: 2) {
                    Text(usesAgentsPersona ? service.agentsPersonaPlace : context.place).font(.system(size: 12))
                    Toggle("Use the Agents Persona", isOn: $usesAgentsPersona)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
            }
            GridRow {
                label("Mode")
                Picker("Mode", selection: Binding(get: { mode ?? service.settings.newSessionMode }, set: { mode = $0 })) {
                    ForEach(AgentAccessLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            GridRow {
                label("Model")
                Picker("Model", selection: Binding(get: { selectedModel }, set: { model = $0; effort = nil })) {
                    ForEach(models, id: \.self) { Text(settings.title(of: $0)).tag(Optional($0)) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            if !effortLevels.isEmpty {
                GridRow {
                    label("Effort")
                    Picker("Effort", selection: $effort) {
                        Text("Tool\u{2019}s default").tag(String?.none)
                        ForEach(effortLevels, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The route's first model until the user picks another.
    private var selectedModel: AIModelRef? {
        model ?? models.first
    }

    private func loadEffortLevels() async {
        guard let selectedModel else { return effortLevels = [] }
        effortLevels = await AIService.shared.agentEffortLevels(for: selectedModel)
        if let effort, !effortLevels.contains(effort) { self.effort = nil }
    }

    /// Codex adds a non-empty `AGENTS.md` (or `AGENTS.override.md`) in its home folder to every turn, which no argument keeps out.
    private var codexInstructionsWarning: String? {
        guard let selectedModel, let provider = settings.providers.first(where: { $0.id == selectedModel.provider }),
              case .commandLine(let tool) = provider.kind, tool.agent == .codex else { return nil }
        let home = tool.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        for name in ["AGENTS.override.md", "AGENTS.md"] {
            let file = home.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.intValue > 0 {
                return "Codex adds your own instructions from \(file.path) to Arch\u{2019}s sessions. Arch\u{2019}s rules apply whatever the model was told."
            }
        }
        return nil
    }

    private func start() {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        let attached = attachesTab && !usesAgentsPersona ? attachableTab.map { [$0.id] } ?? [] : []
        let start = AgentService.SessionStart(task: task, personaID: context.personaID, spaceID: context.spaceID, attachedTabIDs: attached,
                                              mode: mode ?? service.settings.newSessionMode, model: selectedModel, effort: effort, usesAgentsPersona: usesAgentsPersona)
        do {
            let session = try service.startSession(start)
            problem = nil
            didStart(session)
        } catch {
            // The task stays in the field.
            problem = error.localizedDescription
        }
    }
}

/// The attached tab, with a button that removes it.
struct AgentTabChip: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Don\u{2019}t Attach This Tab")
            .accessibilityLabel("Don\u{2019}t Attach This Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}
