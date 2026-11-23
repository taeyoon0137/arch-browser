// The composer starts an in-app session (docs/agents.md, Starting a session; Model choice and fallbacks).
// It holds the task and the selected tab as a removable chip unless the site is excluded. It shows the Persona / Space and Use the Agents Persona choice.
// The mode starts from Settings. The model menu starts with the `agent` route's first model; an effort menu appears when the tool supports it.
// Without a usable model, it explains how to connect an API-key model, Claude Code, or Codex.
// A task starting with `/` is refused and left in the field when a Claude Code session loads Arch's skills.
import AgentControl
import AI
import SwiftUI

/// The settings page that can make a model available to a draft.
public enum AgentModelSettingsPage { case features, providers }

/// What the browser gives the panel: how replies render as the page reader renders them, and the actions that leave the panel.
public struct AgentPanelActions {
    /// Inline Markdown without images, each link showing its full address.
    public var formatReply: (String) -> AttributedString
    public var openLink: (URL) -> Void
    /// Selects a tab of the session's, as a step's button does.
    public var showTab: (UUID) -> Void
    public var showReadTab: (UUID) -> Void
    public var openAISettings: () -> Void
    public var openModelSettings: (AgentModelSettingsPage) -> Void
    /// Opens the built-in terminal with the tool's sign-in typed but not run.
    public var signIn: (AIProviderID) -> Void

    public init(formatReply: @escaping (String) -> AttributedString, openLink: @escaping (URL) -> Void, showTab: @escaping (UUID) -> Void,
                openAISettings: @escaping () -> Void, signIn: @escaping (AIProviderID) -> Void,
                openModelSettings: ((AgentModelSettingsPage) -> Void)? = nil, showReadTab: ((UUID) -> Void)? = nil) {
        self.formatReply = formatReply
        self.openLink = openLink
        self.showTab = showTab
        self.showReadTab = showReadTab ?? showTab
        self.openAISettings = openAISettings
        self.openModelSettings = openModelSettings ?? { _ in openAISettings() }
        self.signIn = signIn
    }
}

/// A bounded excerpt the user can attach from the page reader. The task field holds only their own instructions.
public struct AgentReaderExcerpt: Equatable {
    public let tabID: UUID
    public let documentID: UUID
    public let url: URL
    public let selection: String?
    public let reply: String?

    public init?(tabID: UUID, documentID: UUID, url: URL, selection: String?, reply: String?) {
        guard AgentSite.of(url) != nil else { return nil }
        self.tabID = tabID
        self.documentID = documentID
        self.url = url
        self.selection = Self.excerpt(selection)
        self.reply = Self.excerpt(reply)
        guard self.selection != nil || self.reply != nil else { return nil }
    }

    /// Keep previews and tool results small even for text with long combining sequences.
    private static func excerpt(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let byteLimit = 4096
        guard text.utf8.prefix(byteLimit + 1).count > byteLimit else { return text }
        let prefix = text.utf8.prefix(byteLimit - "…".utf8.count)
        // A UTF-8 scalar takes up to four bytes. Drop its unfinished tail before adding the ellipsis.
        for tail in 0...3 {
            if let complete = String(bytes: prefix.dropLast(tail), encoding: .utf8) { return complete + "…" }
        }
        return nil
    }

    /// Checks that the attached tab is still the same reviewed document and address.
    public func matches(_ tab: AgentTabInfo?) -> Bool {
        tab?.id == tabID && tab?.documentID == documentID && tab?.url == url
    }
}

/// Where a new session starts and what it starts with. Each one is a new draft.
@MainActor public final class AgentComposerContext: ObservableObject, Equatable, Identifiable {
    public let id = UUID()
    public var personaID: UUID
    public var spaceID: UUID
    /// The "Persona / Space" name when this draft was created.
    public var place: String
    /// The document reviewed when this draft opened.
    public var tab: AgentTabInfo?
    /// The reader's selection and answer, which Share reader excerpt shares from the start; the user can preview it or turn it off.
    public var readerExcerpt: AgentReaderExcerpt? {
        didSet { sharesExcerpt = readerExcerpt != nil }
    }
    @Published public var text: String
    @Published var attachesTab = true
    @Published var sharesExcerpt = false
    @Published var usesAgentsPersona = false
    @Published var mode: AgentAccessLevel?
    @Published var model: AIModelRef?
    @Published var effort: String?
    @Published public var problem: String?

    public nonisolated static func == (lhs: AgentComposerContext, rhs: AgentComposerContext) -> Bool { lhs === rhs }

    public init(personaID: UUID, spaceID: UUID, place: String, tab: AgentTabInfo?, text: String = "", problem: String? = nil) {
        self.personaID = personaID
        self.spaceID = spaceID
        self.place = place
        self.tab = tab
        self.text = text
        self.problem = problem
    }

    /// The selected tab when it has a document the user can share with this session.
    public func attachableTab(allowsAI: (URL) -> Bool) -> AgentTabInfo? {
        guard let tab, tab.canShareWithAgent(allowsAI: allowsAI) else { return nil }
        return tab
    }

    /// A session that starts here at once with `task`, without the composer's choices, as the palette's Ask Agent starts one: the attachable tab, `mode`, and the `agent` route's model.
    public func sessionStart(task: String, mode: AgentAccessLevel, allowsAI: (URL) -> Bool) -> AgentService.SessionStart {
        let tab = attachableTab(allowsAI: allowsAI)
        var start = AgentService.SessionStart(task: task, personaID: personaID, spaceID: spaceID, attachedTabIDs: tab.map { [$0.id] } ?? [],
                                              mode: mode, model: nil, effort: nil)
        start.reviewedDocument = tab
        return start
    }
}

/// Collects a task, destination, model, mode, and optional page context before starting a session.
public struct AgentComposer: View {
    @ObservedObject var service: AgentService
    @ObservedObject private var settings = AIService.shared.settings
    @ObservedObject private var context: AgentComposerContext
    let actions: AgentPanelActions
    private let permissionNote: String?
    let didStart: (AgentSession) -> Void
    @FocusState private var isTaskFocused: Bool
    @State private var optionsExpanded = false
    @State private var loadedEffort: (source: EffortSource, levels: [String])?

    public init(service: AgentService, context: AgentComposerContext, actions: AgentPanelActions, permissionNote: String? = nil, didStart: @escaping (AgentSession) -> Void) {
        self.service = service
        self.context = context
        self.actions = actions
        self.permissionNote = permissionNote
        self.didStart = didStart
    }

    private var selectedPermissionNote: String? { context.usesAgentsPersona ? nil : permissionNote }

    private var models: [AIModelRef] { service.agentModels() }

    private var attachableTab: AgentTabInfo? {
        context.attachableTab(allowsAI: settings.allowsAI(on:))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView { form }
                .scrollBounceBehavior(.basedOnSize)
            if !models.isEmpty {
                HStack {
                    Spacer()
                    AgentPrimaryAction(title: "Start", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedModel == nil || context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding([.horizontal, .bottom], AgentPanelMetrics.inset)
            }
        }
        .task(id: effortSource) { await loadEffortLevels() }
        .onAppear { optionsExpanded = context.problem != nil || selectedModel == nil }
        .onChange(of: context.problem) { if context.problem != nil { optionsExpanded = true } }
        // A model that goes away while the draft is open leaves Start off; Options opens on the model menu.
        .onChange(of: selectedModel == nil) { _, isGone in if isGone { optionsExpanded = true } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What should the agent do?", text: $context.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: AgentPanelMetrics.bodySize))
                .lineLimit(3...10)
                .focused($isTaskFocused)
                .onAppear { isTaskFocused = true }
                .onSubmit(start)
            if let tab = attachableTab, context.attachesTab, !context.usesAgentsPersona {
                AgentTabChip(tab: tab) {
                    context.attachesTab = false
                    context.sharesExcerpt = false
                }
            } else if !context.attachesTab, !context.usesAgentsPersona, let tab = attachableTab, service.canReattach(tab, in: context.personaID) {
                HStack {
                    Button("Reattach Reviewed Tab") {
                        guard service.canReattach(tab, in: context.personaID) else {
                            context.problem = "The reviewed page changed or is no longer available."
                            return
                        }
                        context.attachesTab = true
                    }
                    AgentAttachmentLabel(tab: tab)
                }
                .controlSize(.small)
            }
            // The page context that goes with the task stays beside its chip.
            if let tab = attachableTab, context.attachesTab,
               let excerpt = context.readerExcerpt, excerpt.matches(tab), !context.usesAgentsPersona {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Share reader excerpt", isOn: $context.sharesExcerpt)
                        .toggleStyle(.checkbox)
                        .font(.system(size: AgentPanelMetrics.supportingSize))
                    AgentTechnicalDetails(title: "Preview excerpt") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if let selection = excerpt.selection { Text("Selected text").fontWeight(.medium); Text(verbatim: selection) }
                                if let reply = excerpt.reply { Text("Reader answer").fontWeight(.medium); Text(verbatim: reply) }
                            }
                            .font(.system(size: AgentPanelMetrics.detailSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }
                }
            }
            Text(service.place(of: context))
                .font(.system(size: AgentPanelMetrics.supportingSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(service.place(of: context))
            // What the destination permits, beside it, where the user decides to start.
            if let selectedPermissionNote { note(selectedPermissionNote) }
            if models.isEmpty {
                modelSetup
            } else {
                DisclosureGroup("Options", isExpanded: $optionsExpanded) {
                    AgentSectionBox { options }
                }
                .font(.system(size: AgentPanelMetrics.supportingSize))
                // Why Start is off, and what the chosen tool adds, stay in view while Options is closed.
                if selectedModel == nil { note("The selected model is no longer available. Choose another model in Options to continue.") }
                if let warning = codexInstructionsWarning { note(warning) }
            }
            if let problem = context.problem {
                Text(problem)
                    .font(.system(size: AgentPanelMetrics.supportingSize))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AgentPanelMetrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelSetup: some View {
        let isEnabled = settings.route(for: .agent).isEnabled
        return VStack(alignment: .leading, spacing: 8) {
            Text(isEnabled ? "Connect an agent model in Settings ▸ AI" : "Agent Tasks is turned off")
                .font(.system(size: AgentPanelMetrics.bodySize, weight: .medium))
            Text(isEnabled ? "Choose an API-key model with tool calling, or sign in to Claude Code or Codex in Arch’s terminal." : "Turn on Agent Tasks in Settings ▸ AI ▸ Features to continue.")
                .font(.system(size: AgentPanelMetrics.supportingSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(isEnabled ? "Open Providers" : "Open Features") {
                actions.openModelSettings(isEnabled ? .providers : .features)
            }
            .controlSize(.small)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The place line above names where the task runs; this only changes it.
            Toggle("Use the Agents Persona", isOn: $context.usesAgentsPersona)
                .toggleStyle(.checkbox)
                .font(.system(size: AgentPanelMetrics.supportingSize))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    label("Mode")
                    // Settings' mode is the highest a new session starts in; the panel's mode menu raises it after a confirmation.
                    Picker("Mode", selection: Binding(get: { chosenMode }, set: { context.mode = $0 })) {
                        ForEach(AgentAccessLevel.allCases.filter { $0.rank <= service.newSessionMode.rank }, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Mode")
                    .controlSize(.small)
                }
                GridRow {
                    label("Model")
                    Picker("Model", selection: Binding(get: { selectedModel }, set: { context.model = $0; context.effort = nil })) {
                        if selectedModel == nil { Text("Choose a model…").tag(nil as AIModelRef?).disabled(true) }
                        ForEach(models, id: \.self) { Text(settings.title(of: $0)).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Model")
                    .controlSize(.small)
                }
                if !effortLevels.isEmpty {
                    GridRow {
                        label("Effort")
                        Picker("Effort", selection: $context.effort) {
                            Text("Tool\u{2019}s default").tag(String?.none)
                            ForEach(effortLevels, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Effort")
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AgentPanelMetrics.supportingSize))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AgentPanelMetrics.detailSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The mode the user picked, at most Settings' mode.
    private var chosenMode: AgentAccessLevel {
        let limit = service.newSessionMode
        guard let mode = context.mode, mode.rank <= limit.rank else { return limit }
        return mode
    }

    /// The route's first model until the user picks another.
    private var selectedModel: AIModelRef? {
        if let model = context.model { return models.contains(model) ? model : nil }
        return models.first
    }

    /// A CLI preset can change executable or environment without changing its model reference.
    struct EffortSource: Equatable {
        let model: AIModelRef
        let tool: AICommandLineConfiguration

        init?(_ model: AIModelRef?, providers: [AIProviderConfiguration]) {
            guard let model, let provider = providers.first(where: { $0.id == model.provider }),
                  case .commandLine(let tool) = provider.kind, tool.agent != nil else { return nil }
            self.model = model
            self.tool = tool
        }
    }

    private var effortSource: EffortSource? { EffortSource(selectedModel, providers: settings.providers) }

    private var effortLevels: [String] {
        guard let loadedEffort, loadedEffort.source == effortSource else { return [] }
        return loadedEffort.levels
    }

    /// Loads effort choices for the selected command-line model and clears a stale choice.
    private func loadEffortLevels() async {
        guard let source = effortSource else {
            loadedEffort = nil
            context.effort = nil
            return
        }
        let levels = await AIService.shared.agentEffortLevels(for: source.model)
        guard !Task.isCancelled, source == effortSource else { return }
        loadedEffort = (source, levels)
        if let effort = context.effort, !levels.contains(effort) { context.effort = nil }
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

    /// Starts a session with the selected task and attachments, leaving errors in the draft.
    private func start() {
        let task = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, selectedModel != nil else { return }
        let attached = context.attachesTab && !context.usesAgentsPersona ? attachableTab.map { [$0.id] } ?? [] : []
        var start = AgentService.SessionStart(task: task, personaID: context.personaID, spaceID: context.spaceID, attachedTabIDs: attached,
                                              mode: chosenMode, model: context.model, effort: context.effort.flatMap { effortLevels.contains($0) ? $0 : nil },
                                              usesAgentsPersona: context.usesAgentsPersona)
        if !attached.isEmpty { start.reviewedDocument = attachableTab }
        if context.sharesExcerpt, let excerpt = context.readerExcerpt, attached.contains(excerpt.tabID) { start.readerExcerpt = excerpt }
        do {
            let session = try service.startSession(start)
            context.problem = nil
            didStart(session)
        } catch {
            // The task stays in the field.
            context.problem = error.localizedDescription
        }
    }
}

extension AgentTabInfo {
    /// For local review only. The model's tool results continue to use AgentAddress.reduced.
    var attachmentAddress: String? {
        guard let url, var address = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        address.user = nil
        address.password = nil
        return address.string
    }

    var attachmentLabel: String {
        attachmentLabel(address: url.map { AgentAddress.reduced($0).absoluteString })
    }

    /// Uses a reduced address when the title is empty or duplicates the address.
    private func attachmentLabel(address: String?) -> String {
        guard let address else { return title.isEmpty ? "Tab" : title }
        if title.isEmpty || title == url?.host || url.map({ AgentAddress.isOwnAddress(title, of: $0) }) == true { return address }
        return "\(title) · \(address)"
    }

    /// Use the full local address to distinguish matching labels. For identical choices, keep their order in the picker.
    static func attachmentLabels(for tabs: [Self]) -> [UUID: String] {
        var labels = [UUID: String]()
        for (label, group) in Dictionary(grouping: tabs, by: \.attachmentLabel) {
            let needsFullAddress = group.count > 1 && Set(group.compactMap(\.attachmentAddress)).count > 1
            let byAddress = Dictionary(grouping: group) { needsFullAddress ? $0.attachmentLabel(address: $0.attachmentAddress) : label }
            for (addressLabel, matches) in byAddress {
                for (index, tab) in matches.enumerated() {
                    labels[tab.id] = matches.count > 1 ? "Tab \(index + 1) · \(addressLabel)" : addressLabel
                }
            }
        }
        return labels
    }
}

/// A compact attachment label opens the complete local address for visual or keyboard review.
struct AgentAttachmentLabel: View {
    let tab: AgentTabInfo
    @State private var showsAddress = false

    var body: some View {
        Button { showsAddress = true } label: {
            Text(verbatim: tab.attachmentLabel).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Review tab address")
        .accessibilityLabel("Review tab: \(tab.attachmentLabel)")
        .popover(isPresented: $showsAddress) {
            Text(verbatim: tab.attachmentAddress ?? tab.attachmentLabel)
                .textSelection(.enabled)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
    }
}

/// The attached tab, with a button that removes it.
struct AgentTabChip: View {
    let tab: AgentTabInfo
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .accessibilityHidden(true)
            AgentAttachmentLabel(tab: tab)
                .font(.system(size: 11))
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
