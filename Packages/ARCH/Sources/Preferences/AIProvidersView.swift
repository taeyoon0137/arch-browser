// Settings ▸ AI ▸ Providers: the list of connected providers, the sheet that adds or edits an HTTP provider with its format, base URL, key, headers, models, and limits, the Claude Code and Codex presets, and the parts that the command-line tool editor shares.
import AI
import LocalAuthentication
import SwiftUI

struct AIProvidersPage: View {
    @ObservedObject var service: AIService
    @ObservedObject var settings: AISettingsStore
    @State private var editing: AIProviderSheet?

    var body: some View {
        Section {
            if settings.providers.isEmpty {
                Text("No providers yet").foregroundStyle(.secondary)
            }
            ForEach(settings.providers) { provider in
                LabeledContent {
                    Button("Edit\u{2026}") { editing = AIProviderSheet(provider) }
                } label: {
                    Text(provider.name)
                    Text(Self.detail(of: provider))
                }
            }
            HStack {
                Spacer()
                if let openTerminal = PreferencesWindowController.openTerminal {
                    Button("Open Terminal", action: openTerminal)
                }
                Menu("Add Provider") {
                    Button("HTTP API\u{2026}") { editing = .http(AIProviderDraft()) }
                    Button("Command-Line Tool\u{2026}") { editing = .commandLine(AICommandLineDraft()) }
                    Divider()
                    Button("Claude Code (Claude Subscription)\u{2026}") { addPreset(.claudeCode) }
                    Button("Codex (ChatGPT Subscription)\u{2026}") { addPreset(.codex) }
                }
                .fixedSize()
            }
            .sheet(item: $editing) { sheet in
                switch sheet {
                case .http(let draft): AIProviderEditor(draft: draft, service: service, settings: settings)
                case .commandLine(let draft): AICommandLineEditor(draft: draft, service: service, settings: settings)
                }
            }
        } header: {
            Text("Providers")
        } footer: {
            formFootnote("Connect a service you subscribe to with its API key, a model server on this Mac, or a command-line tool you install and sign in to in the terminal. Keys stay in the Keychain and go only to their provider. Nothing is sent until a feature makes a request.")
        }
    }

    /// A preset finds its tool in the login shell's PATH before the editor opens; the editor then reads its version and sign-in.
    private func addPreset(_ kind: AIAgentKind) {
        Task { editing = .commandLine(await AICommandLineDraft.preset(kind)) }
    }

    private static func detail(of provider: AIProviderConfiguration) -> String {
        let models = provider.models.count == 1 ? "1 model" : "\(provider.models.count) models"
        switch provider.kind {
        case .http(let http):
            let key = http.hasKey ? "key saved" : "no key"
            return [http.format.title, http.baseURL.host ?? http.baseURL.absoluteString, key, models].joined(separator: " \u{00B7} ")
        case .commandLine(let tool) where tool.agent != nil:
            return ["\(tool.agent?.title ?? "") on your subscription", tool.executable.lastPathComponent, "agent sessions", models].joined(separator: " \u{00B7} ")
        case .commandLine(let tool):
            let data = tool.runsWithoutTools ? "may get page data" : "text only"
            return ["Command-line tool", tool.executable.lastPathComponent, data, models].joined(separator: " \u{00B7} ")
        }
    }
}

/// The provider being added or edited, in the editor for its kind.
private enum AIProviderSheet: Identifiable {
    case http(AIProviderDraft)
    case commandLine(AICommandLineDraft)

    init(_ provider: AIProviderConfiguration) {
        switch provider.kind {
        case .http(let http): self = .http(AIProviderDraft(provider, http: http))
        case .commandLine(let tool): self = .commandLine(AICommandLineDraft(provider, tool: tool))
        }
    }

    var id: AIProviderID {
        switch self {
        case .http(let draft): return draft.id
        case .commandLine(let draft): return draft.id
        }
    }
}

extension AIWireFormat {
    var title: String {
        switch self {
        case .chatCompletions: return "Chat Completions"
        case .messages: return "Messages"
        }
    }
}

/// An HTTP provider being added or edited. Nothing reaches `ai.json` or the Keychain until the user saves.
struct AIProviderDraft: Identifiable {
    let id: AIProviderID
    let isNew: Bool
    var name: String
    var format: AIWireFormat
    var baseURL: String
    var headers: [AINameValue]
    /// Whether the Keychain holds a key for the provider now.
    let hasKey: Bool
    var newKey = ""
    var removesKey = false
    var models: [AIModelConfiguration]
    var limits: AIProviderLimits

    init() {
        id = AIProviderID()
        isNew = true
        name = "New Provider"
        format = .chatCompletions
        baseURL = ""
        headers = []
        hasKey = false
        models = []
        limits = .http
    }

    init(_ provider: AIProviderConfiguration, http: AIHTTPConfiguration) {
        id = provider.id
        isNew = false
        name = provider.name
        format = http.format
        baseURL = http.baseURL.absoluteString
        headers = AINameValue.rows(http.headers)
        hasKey = http.hasKey
        models = provider.models
        limits = provider.limits
    }

    /// The typed key without the spaces and line breaks a copy can carry. Refresh sends it and Save stores it, so both use the same key.
    var enteredKey: String {
        newKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The base URL, if requests may go to it.
    var validBaseURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces)).flatMap { AIHTTPConfiguration.isAllowedBaseURL($0) ? $0 : nil }
    }

    /// The configuration as it stands, with the key state the Keychain has before saving.
    var configuration: AIProviderConfiguration? {
        guard let url = validBaseURL else { return nil }
        let http = AIHTTPConfiguration(format: format, baseURL: url, headers: AINameValue.dictionary(headers), hasKey: hasKey)
        return AIProviderConfiguration(id: id, name: name.trimmingCharacters(in: .whitespaces), kind: .http(http), models: models, limits: limits)
    }
}

/// The sheet that adds or edits a provider. Replacing or removing a saved key asks for Touch ID or the login password first.
private struct AIProviderEditor: View {
    @State var draft: AIProviderDraft
    let service: AIService
    @ObservedObject var settings: AISettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var isReplacingKey = false
    @State private var isRefreshing = false
    /// What the last Refresh added, or why it failed, under the model list.
    @State private var refreshResult: String?
    @State private var refreshFailed = false
    /// Why the last save or removal failed, over the buttons.
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.isNew ? "Add HTTP API Provider" : "Edit HTTP API Provider")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Format", selection: $draft.format) {
                        ForEach(AIWireFormat.allCases, id: \.self) { Text($0.title) }
                    }
                    TextField("Base URL", text: $draft.baseURL, prompt: Text("https://api.example.com/v1"))
                    if !draft.baseURL.isEmpty, draft.validBaseURL == nil {
                        Text("Use an https address, or http for a server on this Mac.").font(.callout).foregroundStyle(.red)
                    }
                } footer: {
                    formFootnote(draft.format == .chatCompletions
                                 ? "Requests go to the base URL followed by /chat/completions, with the key as a bearer token."
                                 : "Requests go to the base URL followed by /messages, with the key in an x-api-key header. Add the version header the server requires under Headers.")
                }
                keySection
                headersSection
                modelsSection
                AIProviderLimitsSection(limits: $draft.limits)
            }
            .formStyle(.grouped)
            Divider()
            AIProviderEditorButtons(name: draft.name, isNew: draft.isNew,
                                    canSave: draft.configuration != nil && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                                    failure: message,
                                    removalNote: "Its key leaves the Keychain, and features that used its models fall back to their other models.",
                                    remove: remove, save: save)
        }
        .frame(width: 480, height: 500)
    }

    // MARK: Key

    @ViewBuilder private var keySection: some View {
        Section {
            if draft.hasKey && !isReplacingKey {
                LabeledContent("Key") {
                    Text(draft.removesKey ? "Removed when you save" : "Saved in the Keychain").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if draft.removesKey {
                        Button("Keep Key") { draft.removesKey = false }
                    } else {
                        Button("Replace\u{2026}") { isReplacingKey = true }
                        Button("Remove") { draft.removesKey = true }
                    }
                }
            } else {
                SecureField("Key", text: $draft.newKey, prompt: Text(draft.hasKey ? "New API key" : "API key"))
            }
        } header: {
            Text("API Key")
        } footer: {
            formFootnote("A server on this Mac may need no key. The key is entered once and never shown again.")
        }
    }

    // MARK: Headers

    @ViewBuilder private var headersSection: some View {
        Section {
            AINameValueRows(rows: $draft.headers, addTitle: "Add Header", removeTitle: "Remove Header")
        } header: {
            Text("Headers")
        } footer: {
            formFootnote("Headers are saved in ai.json, so they must not hold secrets. The key goes under API Key.")
        }
    }

    // MARK: Models

    @ViewBuilder private var modelsSection: some View {
        Section {
            AIModelList(models: $draft.models, defaultCapabilities: draft.format.capabilities) {
                Button("Refresh") { Task { await refreshModels() } }
                    .disabled(isRefreshing || draft.configuration == nil)
                    .help("Add the models the provider lists")
            }
            // The button keeps its width while it runs, so the field beside it stays still.
            if isRefreshing {
                AIProgressRow(text: "Asking the provider for its models\u{2026}")
            } else if let refreshResult {
                Text(refreshResult).font(.callout).foregroundStyle(refreshFailed ? .red : .secondary)
            }
        } header: {
            Text("Models")
        } footer: {
            formFootnote("Refresh asks the provider for its models; it is the only request Settings sends on its own.")
        }
    }

    private func refreshModels() async {
        guard var configuration = draft.configuration else { return }
        if draft.removesKey, case .http(var http) = configuration.kind {
            http.hasKey = false
            configuration.kind = .http(http)
        }
        isRefreshing = true
        refreshResult = nil
        refreshFailed = false
        defer { isRefreshing = false }
        do {
            let names = try await service.listModels(of: configuration, key: draft.enteredKey)
            let added = names.filter { name in !draft.models.contains(where: { $0.name == name }) }
            draft.models += added.map { AIModelConfiguration(name: $0) }
            refreshResult = added.isEmpty ? "No new models." : "Added \(added.count) of \(names.count) models."
        } catch {
            refreshResult = settings.message(for: error)
            refreshFailed = true
        }
    }

    // MARK: Saving

    private func save() async {
        guard let configuration = draft.configuration else { return }
        let key = draft.enteredKey
        if draft.hasKey && (draft.removesKey || !key.isEmpty) {
            guard await Self.authorize("change the API key for \(configuration.name)") else {
                message = "The key was not changed."
                return
            }
        } else if draft.hasKey, let saved = settings.providers.first(where: { $0.id == configuration.id }), !saved.keepsItsKey(in: configuration) {
            // The saved key would go to the new base URL from now on, which asks as much as replacing the key does.
            guard await Self.authorize("send the API key for \(configuration.name) to a new base URL") else {
                message = "The provider was not changed."
                return
            }
        }
        settings.save(configuration)
        do {
            if !key.isEmpty {
                try await settings.setKey(key, for: configuration.id)
            } else if draft.removesKey {
                try await settings.removeKey(for: configuration.id)
            }
            dismiss()
        } catch {
            message = settings.message(for: error)
        }
    }

    private func remove() async {
        if draft.hasKey, !(await Self.authorize("remove the API key for \(draft.name.trimmingCharacters(in: .whitespaces))")) {
            message = "The provider was not removed."
            return
        }
        do {
            try await settings.removeProvider(draft.id)
            dismiss()
        } catch {
            message = settings.message(for: error)
        }
    }

    /// Touch ID or the login password through LocalAuthentication.
    private static func authorize(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

// MARK: - Shared editor parts

/// A provider's models, each with its input limit, price, and capability overrides, and a field that adds one by name. `accessory` follows the Add button.
struct AIModelList<Accessory: View>: View {
    @Binding var models: [AIModelConfiguration]
    /// The capabilities of the provider's kind, which a model has unless it overrides them.
    let defaultCapabilities: Set<AIModelCapability>
    @ViewBuilder let accessory: () -> Accessory
    @State private var newModel = ""

    var body: some View {
        ForEach(models.map(\.name), id: \.self) { name in
            AIModelRow(model: binding(name), defaultCapabilities: defaultCapabilities) {
                models.removeAll { $0.name == name }
            }
        }
        HStack {
            TextField("Model", text: $newModel, prompt: Text("Model name"))
                .labelsHidden()
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
            accessory()
        }
    }

    private func binding(_ name: String) -> Binding<AIModelConfiguration> {
        Binding(
            get: { models.first(where: { $0.name == name }) ?? AIModelConfiguration(name: name) },
            set: { model in
                guard let index = models.firstIndex(where: { $0.name == name }) else { return }
                models[index] = model
            })
    }

    private func add() {
        let name = newModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !models.contains(where: { $0.name == name }) { models.append(AIModelConfiguration(name: name)) }
        newModel = ""
    }
}

/// A name and a value the user enters, such as a header or an environment variable.
struct AINameValue: Identifiable {
    let id = UUID()
    var name: String
    var value: String

    /// Rows for stored values, sorted by name.
    static func rows(_ values: [String: String]) -> [AINameValue] {
        values.sorted { $0.key < $1.key }.map { AINameValue(name: $0.key, value: $0.value) }
    }

    /// The rows that have a name; a later row with the same name wins.
    static func dictionary(_ rows: [AINameValue]) -> [String: String] {
        Dictionary(rows.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) },
                   uniquingKeysWith: { _, last in last })
    }
}

/// Rows of names and values, each with a button that removes it, and a button that adds a row.
struct AINameValueRows: View {
    @Binding var rows: [AINameValue]
    let addTitle: String
    /// The tooltip and accessibility label of each row's minus button, such as "Remove Header".
    let removeTitle: String

    var body: some View {
        ForEach(rows) { row in
            HStack {
                TextField("Name", text: rowBinding($rows, id: row.id, field: \.name), prompt: Text("Name"))
                    .labelsHidden()
                TextField("Value", text: rowBinding($rows, id: row.id, field: \.value), prompt: Text("Value"))
                    .labelsHidden()
                Button {
                    rows.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(removeTitle)
                .accessibilityLabel(removeTitle)
            }
        }
        HStack {
            Spacer()
            Button(addTitle) { rows.append(AINameValue(name: "", value: "")) }
        }
    }
}

/// One field of the row with `id`, looked up on every read and write so that removing a row never reads a stale index.
func rowBinding<Row: Identifiable>(_ rows: Binding<[Row]>, id: Row.ID, field: WritableKeyPath<Row, String>) -> Binding<String> {
    Binding(
        get: { rows.wrappedValue.first(where: { $0.id == id })?[keyPath: field] ?? "" },
        set: { value in
            guard let index = rows.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            rows.wrappedValue[index][keyPath: field] = value
        })
}

struct AIProviderLimitsSection: View {
    @Binding var limits: AIProviderLimits

    var body: some View {
        Section("Limits") {
            Stepper("Concurrent requests: \(limits.concurrentRequests)", value: $limits.concurrentRequests, in: 1...16)
            TextField("Requests per minute", value: $limits.requestsPerMinute, format: .number, prompt: Text("No limit"))
        }
    }
}

/// A spinner with what is under way, in the row where its result shows next, so that the button that started it keeps its title and width.
struct AIProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The bar under a provider editor: why the last save or removal failed, in red over the buttons as the plugin sheets show a failure, then Remove Provider… for a saved provider, which asks first, Cancel, and Add or Save.
struct AIProviderEditorButtons: View {
    let name: String
    let isNew: Bool
    let canSave: Bool
    /// Why the last save or removal failed.
    let failure: String?
    /// What removing the provider changes, under the confirmation's title.
    let removalNote: String
    let remove: () async -> Void
    let save: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !isNew {
                    Button("Remove Provider\u{2026}", role: .destructive) { confirmsRemoval = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .confirmationDialog("Remove \u{201C}\(name.trimmingCharacters(in: .whitespaces))\u{201D}?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text(removalNote)
        }
    }
}

/// One model with its input limit, optional price, and capability overrides. A command-line tool's model without a name is the tool's own default model.
private struct AIModelRow: View {
    @Binding var model: AIModelConfiguration
    let defaultCapabilities: Set<AIModelCapability>
    let remove: () -> Void

    var body: some View {
        DisclosureGroup(model.name.isEmpty ? "Default model" : model.name) {
            TextField("Input limit (characters)", value: $model.inputCharacterLimit, format: .number)
            Toggle("Price per million tokens", isOn: Binding(
                get: { model.price != nil },
                set: { model.price = $0 ? AIPrice(currency: Locale.current.currency?.identifier ?? "USD", inputPerMillion: 0, outputPerMillion: 0) : nil }))
            if model.price != nil {
                TextField("Currency", text: Binding(get: { model.price?.currency ?? "" }, set: { model.price?.currency = $0.uppercased() }))
                TextField("Input", value: priceBinding(\.inputPerMillion, fallback: 0), format: .number)
                TextField("Output", value: priceBinding(\.outputPerMillion, fallback: 0), format: .number)
                TextField("Cached input", value: priceBinding(\.cachedInputPerMillion, fallback: nil), format: .number, prompt: Text("Same as input"))
            }
            Toggle("Use the provider\u{2019}s capabilities", isOn: Binding(
                get: { model.capabilities == nil },
                set: { model.capabilities = $0 ? nil : defaultCapabilities }))
            if let capabilities = model.capabilities {
                ForEach(AIModelCapability.overridable, id: \.self) { capability in
                    Toggle(capability.title, isOn: Binding(
                        get: { capabilities.contains(capability) },
                        set: { isOn in
                            if isOn { model.capabilities?.insert(capability) } else { model.capabilities?.remove(capability) }
                        }))
                }
            }
            HStack {
                Spacer()
                Button("Remove Model", role: .destructive, action: remove)
            }
        }
    }

    private func priceBinding<Value>(_ field: WritableKeyPath<AIPrice, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { model.price?[keyPath: field] ?? fallback },
            set: { model.price?[keyPath: field] = $0 })
    }
}

extension AIModelCapability {
    var title: String {
        switch self {
        case .tools: return "Tool calls"
        case .jsonOutput: return "JSON replies"
        case .images: return "Images"
        case .files: return "PDF files"
        case .agent: return "Agent sessions"
        }
    }
}
