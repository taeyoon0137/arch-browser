// Settings ▸ AI ▸ Providers: the list of connected providers and the sheet that adds or edits one, with its format, base URL, key, headers, models, and limits.
import AI
import LocalAuthentication
import SwiftUI

struct AIProvidersPage: View {
    @ObservedObject var service: AIService
    @ObservedObject var settings: AISettingsStore
    @State private var editing: AIProviderDraft?

    var body: some View {
        Section {
            if settings.providers.isEmpty {
                Text("No providers yet.").foregroundStyle(.secondary)
            }
            ForEach(settings.providers) { provider in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.name)
                        Text(Self.detail(of: provider)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit\u{2026}") { editing = AIProviderDraft(provider) }
                }
            }
            HStack {
                Spacer()
                Button("Add Provider\u{2026}") { editing = AIProviderDraft() }
            }
            .sheet(item: $editing) { draft in
                AIProviderEditor(draft: draft, service: service, settings: settings)
            }
        } header: {
            Text("Providers")
        } footer: {
            aiFootnote("Connect a service you subscribe to with its API key, or a model server on this Mac. Keys stay in the Keychain and go only to their provider. Nothing is sent until a feature makes a request.")
        }
    }

    private static func detail(of provider: AIProviderConfiguration) -> String {
        guard case .http(let http) = provider.kind else { return "" }
        let key = http.hasKey ? "key saved" : "no key"
        let models = provider.models.count == 1 ? "1 model" : "\(provider.models.count) models"
        return [http.format.title, http.baseURL.host ?? http.baseURL.absoluteString, key, models].joined(separator: " \u{00B7} ")
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

/// A provider being added or edited. Nothing reaches `ai.json` or the Keychain until the user saves.
struct AIProviderDraft: Identifiable {
    struct Header: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    let id: AIProviderID
    let isNew: Bool
    var name: String
    var format: AIWireFormat
    var baseURL: String
    var headers: [Header]
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

    init(_ provider: AIProviderConfiguration) {
        guard case .http(let http) = provider.kind else { fatalError("Only HTTP providers exist") }
        id = provider.id
        isNew = false
        name = provider.name
        format = http.format
        baseURL = http.baseURL.absoluteString
        headers = http.headers.sorted { $0.key < $1.key }.map { Header(name: $0.key, value: $0.value) }
        hasKey = http.hasKey
        models = provider.models
        limits = provider.limits
    }

    /// The base URL, if requests may go to it.
    var validBaseURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces)).flatMap { AIHTTPConfiguration.isAllowedBaseURL($0) ? $0 : nil }
    }

    /// The configuration as it stands, with the key state the Keychain has before saving.
    var configuration: AIProviderConfiguration? {
        guard let url = validBaseURL else { return nil }
        let headerValues = Dictionary(headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { _, last in last })
        let http = AIHTTPConfiguration(format: format, baseURL: url, headers: headerValues, hasKey: hasKey)
        return AIProviderConfiguration(id: id, name: name.trimmingCharacters(in: .whitespaces), kind: .http(http), models: models, limits: limits)
    }
}

/// The sheet that adds or edits a provider. Replacing or removing a saved key asks for Touch ID or the login password first.
private struct AIProviderEditor: View {
    @State var draft: AIProviderDraft
    let service: AIService
    @ObservedObject var settings: AISettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var newModel = ""
    @State private var isReplacingKey = false
    @State private var isRefreshing = false
    @State private var message: String?
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(spacing: 0) {
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
                    aiFootnote(draft.format == .chatCompletions
                               ? "Requests go to the base URL followed by /chat/completions, with the key as a bearer token."
                               : "Requests go to the base URL followed by /messages, with the key in an x-api-key header. Add the version header the server requires under Headers.")
                }
                keySection
                headersSection
                modelsSection
                Section("Limits") {
                    Stepper("Concurrent requests: \(draft.limits.concurrentRequests)", value: $draft.limits.concurrentRequests, in: 1...16)
                    TextField("Requests per minute", value: $draft.limits.requestsPerMinute, format: .number, prompt: Text("No limit"))
                }
                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if !draft.isNew {
                    Button("Remove Provider\u{2026}", role: .destructive) { confirmsRemoval = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.configuration == nil || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 580)
        .confirmationDialog("Remove \(draft.name)?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Its key leaves the Keychain, and features that used its models fall back to their other models.")
        }
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
            aiFootnote("A server on this Mac may need no key. The key is entered once and never shown again.")
        }
    }

    // MARK: Headers

    @ViewBuilder private var headersSection: some View {
        Section {
            ForEach(draft.headers) { header in
                HStack {
                    TextField("Name", text: headerBinding(header.id, \.name), prompt: Text("Name"))
                        .labelsHidden()
                    TextField("Value", text: headerBinding(header.id, \.value), prompt: Text("Value"))
                        .labelsHidden()
                    Button {
                        draft.headers.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Spacer()
                Button("Add Header") { draft.headers.append(.init(name: "", value: "")) }
            }
        } header: {
            Text("Headers")
        } footer: {
            aiFootnote("Headers are saved in ai.json, so they must not hold secrets. The key goes under API Key.")
        }
    }

    /// Looks the header up by ID on every read and write, so removing a row never reads a stale index.
    private func headerBinding(_ id: UUID, _ field: WritableKeyPath<AIProviderDraft.Header, String>) -> Binding<String> {
        Binding(
            get: { draft.headers.first(where: { $0.id == id })?[keyPath: field] ?? "" },
            set: { value in
                guard let index = draft.headers.firstIndex(where: { $0.id == id }) else { return }
                draft.headers[index][keyPath: field] = value
            })
    }

    // MARK: Models

    @ViewBuilder private var modelsSection: some View {
        Section {
            ForEach(draft.models.map(\.name), id: \.self) { name in
                AIModelRow(model: modelBinding(name), format: draft.format) {
                    draft.models.removeAll { $0.name == name }
                }
            }
            HStack {
                TextField("Model", text: $newModel, prompt: Text("Model name"))
                    .labelsHidden()
                    .onSubmit(addModel)
                Button("Add", action: addModel)
                    .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(isRefreshing ? "Refreshing\u{2026}" : "Refresh") { Task { await refreshModels() } }
                    .disabled(isRefreshing || draft.configuration == nil)
                    .help("Add the models the provider lists")
            }
        } header: {
            Text("Models")
        } footer: {
            aiFootnote("Refresh asks the provider for its models; it is the only request Settings sends on its own.")
        }
    }

    private func modelBinding(_ name: String) -> Binding<AIModelConfiguration> {
        Binding(
            get: { draft.models.first(where: { $0.name == name }) ?? AIModelConfiguration(name: name) },
            set: { model in
                guard let index = draft.models.firstIndex(where: { $0.name == name }) else { return }
                draft.models[index] = model
            })
    }

    private func addModel() {
        let name = newModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !draft.models.contains(where: { $0.name == name }) { draft.models.append(AIModelConfiguration(name: name)) }
        newModel = ""
    }

    private func refreshModels() async {
        guard var configuration = draft.configuration else { return }
        if draft.removesKey, case .http(var http) = configuration.kind {
            http.hasKey = false
            configuration.kind = .http(http)
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let names = try await service.listModels(of: configuration, key: draft.newKey)
            let added = names.filter { name in !draft.models.contains(where: { $0.name == name }) }
            draft.models += added.map { AIModelConfiguration(name: $0) }
            message = added.isEmpty ? "No new models." : "Added \(added.count) of \(names.count) models."
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Saving

    private func save() async {
        guard let configuration = draft.configuration else { return }
        let key = draft.newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.hasKey && (draft.removesKey || !key.isEmpty) {
            guard await Self.authorize("change the API key for \(configuration.name)") else {
                message = "The key was not changed."
                return
            }
        }
        settings.save(configuration)
        do {
            if !key.isEmpty {
                try settings.setKey(key, for: configuration.id)
            } else if draft.removesKey {
                try settings.removeKey(for: configuration.id)
            }
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    private func remove() async {
        if draft.hasKey, !(await Self.authorize("remove the API key for \(draft.name)")) {
            message = "The provider was not removed."
            return
        }
        do {
            try settings.removeProvider(draft.id)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Touch ID or the login password through LocalAuthentication.
    private static func authorize(_ reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// One model with its input limit, optional price, and capability overrides.
private struct AIModelRow: View {
    @Binding var model: AIModelConfiguration
    let format: AIWireFormat
    let remove: () -> Void

    var body: some View {
        DisclosureGroup(model.name) {
            TextField("Input limit (characters)", value: $model.inputCharacterLimit, format: .number)
            Toggle("Price per million tokens", isOn: Binding(
                get: { model.price != nil },
                set: { model.price = $0 ? AIPrice(currency: Locale.current.currency?.identifier ?? "USD", inputPerMillion: 0, outputPerMillion: 0) : nil }))
            if model.price != nil {
                TextField("Currency", text: priceBinding(\.currency, fallback: ""))
                TextField("Input", value: priceBinding(\.inputPerMillion, fallback: 0), format: .number)
                TextField("Output", value: priceBinding(\.outputPerMillion, fallback: 0), format: .number)
                TextField("Cached input", value: priceBinding(\.cachedInputPerMillion, fallback: nil), format: .number, prompt: Text("Same as input"))
            }
            Toggle("Use the format's capabilities", isOn: Binding(
                get: { model.capabilities == nil },
                set: { model.capabilities = $0 ? nil : format.capabilities }))
            if let capabilities = model.capabilities {
                ForEach(AIModelCapability.allCases, id: \.self) { capability in
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
        }
    }
}
