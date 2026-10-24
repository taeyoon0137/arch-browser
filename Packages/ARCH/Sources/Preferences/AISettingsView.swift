// Settings ▸ AI: the providers the user connects, the models for each registered feature, the sites where AI is off, usage, and recent requests. Arch ships no model or provider account, so this section is the only place that mentions AI until a provider is connected.
import AI
import SwiftUI

extension AIFeature {
    /// Sends what the user types under Features ▸ Test Prompt, so a provider and its fallbacks can be tried before any browsing feature uses them.
    static let testPrompt = AIFeature(id: AIFeatureID(rawValue: "testPrompt"), name: "Test Prompt",
                                      summary: "Sends the prompt below and shows the reply, to try a provider and its fallbacks.",
                                      trigger: .user, data: .textOnly)
}

/// The AI section has more to show than the others, so it keeps one height and its pages scroll.
struct AISettingsView: View {
    private enum Page: String, CaseIterable {
        case providers = "Providers"
        case features = "Features"
        case sites = "Sites"
        case usage = "Usage"
        case activity = "Activity"
    }

    @ObservedObject private var service = AIService.shared
    @ObservedObject private var settings = AIService.shared.settings
    @State private var page = Page.providers

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                if settings.replacedUnreadableFile {
                    Section {
                        Text("ai.json could not be read, so Arch renamed it ai.json.unreadable and started with new AI settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                switch page {
                case .providers: AIProvidersPage(service: service, settings: settings)
                case .features: AIFeaturesPage(service: service, settings: settings)
                case .sites: AISitesPage(settings: settings)
                case .usage: AIUsagePage(usage: service.usage, settings: settings)
                case .activity: AIActivityPage(service: service, settings: settings)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: sectionWidth, height: 540)
        .onAppear { service.register(.testPrompt) }
    }
}

/// A grouped form's footer is trailing-aligned, primary, and sometimes cut to one line by default.
func aiFootnote(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Features

/// The default route, then one section per registered feature with its switch, its models, what it sends, and its last error. The Test Prompt feature's section also holds the prompt.
private struct AIFeaturesPage: View {
    @ObservedObject var service: AIService
    @ObservedObject var settings: AISettingsStore

    var body: some View {
        Section {
            AIRoutePickers(settings: settings, feature: .defaultRoute, emptyChoice: nil)
        } header: {
            Text("Default Model")
        } footer: {
            aiFootnote("Features you start, such as a question about a page, use these models unless they have their own. Features that run on their own never do.")
        }
        ForEach(service.features) { feature in
            Section {
                Toggle("On", isOn: Binding(
                    get: { settings.route(for: feature.id).isEnabled },
                    set: { isOn in
                        var route = settings.route(for: feature.id)
                        route.isEnabled = isOn
                        settings.setRoute(route, for: feature.id)
                    }))
                AIRoutePickers(settings: settings, feature: feature.id, emptyChoice: feature.trigger == .user ? "Default Model" : "None")
                if feature.id == AIFeature.testPrompt.id {
                    AITestPromptRows(service: service, settings: settings)
                } else if let error = lastError(of: feature.id) {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text(feature.name)
            } footer: {
                aiFootnote("\(feature.summary) \(Self.sentence(for: feature))")
            }
        }
    }

    private func lastError(of feature: AIFeatureID) -> String? {
        guard case .failed(let error) = service.activity.last(where: { $0.feature == feature })?.result else { return nil }
        return error.localizedDescription
    }

    /// What the feature sends, in words.
    private static func sentence(for feature: AIFeature) -> String {
        let names: [(AIDataKind, String)] = [(.page, "the page's text"), (.selection, "the selection"), (.file, "files"), (.download, "download details")]
        let kinds = names.filter { feature.data.kinds.contains($0.0) }.map(\.1)
        let sends = kinds.isEmpty ? "It sends text only." : "It sends text and \(ListFormatter.localizedString(byJoining: kinds))."
        return feature.trigger == .automatic ? "\(sends) It runs on its own." : sends
    }
}

/// The primary model and up to two fallbacks of one route. A fallback picker appears once the slot before it has a model.
private struct AIRoutePickers: View {
    @ObservedObject var settings: AISettingsStore
    let feature: AIFeatureID
    /// The primary's empty choice; nil for the default route, which uses the first connected model while it has none of its own.
    let emptyChoice: String?

    var body: some View {
        let route = settings.route(for: feature)
        let options = settings.providers.flatMap { provider in provider.models.map { AIModelRef(provider: provider.id, model: $0.name) } }
        if options.isEmpty {
            Text("Add a provider with a model under Providers first.").foregroundStyle(.secondary)
        } else {
            ForEach(0..<min(route.models.count + 1, AIRoute.maximumModels), id: \.self) { slot in
                let current = route.models[safe: slot]
                // A model that has left its provider stays listed until the user picks another.
                let choices = current.map { options.contains($0) ? options : options + [$0] } ?? options
                Picker(slot == 0 ? "Model" : "Fallback \(slot)", selection: binding(slot)) {
                    if slot > 0 || emptyChoice != nil {
                        Text(slot == 0 ? emptyChoice ?? "None" : "None").tag(AIModelRef?.none)
                    }
                    ForEach(choices, id: \.self) { ref in
                        Text(settings.title(of: ref)).tag(Optional(ref))
                    }
                }
            }
        }
    }

    private func binding(_ slot: Int) -> Binding<AIModelRef?> {
        Binding(
            get: { settings.route(for: feature).models[safe: slot] },
            set: { choice in
                var route = settings.route(for: feature)
                if let choice {
                    if slot < route.models.count { route.models[slot] = choice } else { route.models.append(choice) }
                } else {
                    // Clearing a slot clears the fallbacks after it.
                    route.models = Array(route.models.prefix(slot))
                }
                settings.setRoute(route, for: feature)
            })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Streams a reply to the typed text through the Test Prompt feature, showing the model that answered after any fallback, or the error.
private struct AITestPromptRows: View {
    @ObservedObject var service: AIService
    @ObservedObject var settings: AISettingsStore
    @State private var prompt = "Reply with one short sentence."
    @State private var reply = ""
    @State private var status: String?
    @State private var isError = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        TextField("Prompt", text: $prompt, axis: .vertical)
            .lineLimit(1...4)
        HStack {
            Spacer()
            if task != nil {
                Button("Stop") { task?.cancel() }
            } else {
                Button("Send", action: send)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !service.isAvailable(AIFeature.testPrompt.id))
            }
        }
        if !reply.isEmpty {
            Text(reply).textSelection(.enabled)
        }
        if let status {
            Text(status).font(.callout).foregroundStyle(isError ? .red : .secondary)
        }
    }

    private func send() {
        reply = ""
        status = nil
        isError = false
        let request = AIRequest(feature: AIFeature.testPrompt.id, messages: [AIMessage(role: .user, parts: [.text(prompt)])], maxOutputTokens: 512)
        task = Task {
            var model: AIModelRef?
            var tokens = ""
            do {
                for try await event in service.stream(request) {
                    switch event {
                    case .waiting(.queued):
                        status = "Waiting for a free request slot\u{2026}"
                    case .waiting(.rateLimited(let until)):
                        status = "Waiting for the provider's rate limit until \(until.formatted(date: .omitted, time: .standard))\u{2026}"
                    case .started(let ref):
                        model = ref
                        status = "Answering: \(settings.title(of: ref))"
                    case .text(let text):
                        reply += text
                    case .usage(let usage):
                        tokens = " \u{00B7} \(usage.inputTokens + usage.cachedInputTokens) input and \(usage.outputTokens) output tokens"
                    case .finished(let reason):
                        let cut = reason == .lengthLimit ? " The reply reached the length limit." : ""
                        status = "Answered by \(model.map(settings.title(of:)) ?? "the model")\(tokens).\(cut)"
                    case .toolCall:
                        break
                    }
                }
                if Task.isCancelled { status = "Stopped." }
            } catch AIError.cancelled {
                status = "Stopped."
            } catch {
                status = error.localizedDescription
                isError = true
            }
            task = nil
        }
    }
}

// MARK: - Sites

/// The sites where AI is off for every feature.
private struct AISitesPage: View {
    @ObservedObject var settings: AISettingsStore
    @State private var newSite = ""

    var body: some View {
        Section {
            ForEach(settings.excludedSites, id: \.self) { site in
                HStack {
                    Text(Self.title(of: site))
                    Spacer()
                    Button {
                        settings.excludedSites.removeAll { $0 == site }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Allow AI on this site")
                }
            }
            HStack {
                TextField("Site", text: $newSite, prompt: Text("example.org"))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(AISitePattern(parsing: newSite) == nil)
            }
        } header: {
            Text("AI Is Off on These Sites")
        } footer: {
            aiFootnote("Nothing from these sites goes to any provider. A site includes its subdomains. Internal pages such as flags:// are always excluded.")
        }
    }

    private func add() {
        guard let pattern = AISitePattern(parsing: newSite) else { return }
        if !settings.excludedSites.contains(pattern) { settings.excludedSites.append(pattern) }
        newSite = ""
    }

    private static func title(of site: AISitePattern) -> String {
        switch site {
        case .fileScheme: return "Local files (file:)"
        case .localNetwork: return "Local network and this Mac"
        default: return site.value
        }
    }
}
