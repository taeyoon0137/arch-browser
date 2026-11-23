// Settings ▸ AI lists connected providers, models for each registered feature and tier, excluded sites, usage, and recent requests.
// It also shows outside agent access, grants, activity, and hooks.
// Arch ships no model or provider account. Until the user connects one, this is the only section that mentions AI, apart from New Agent Task and Show Agent Panel, which open Settings ▸ AI ▸ Providers.
import Agent
import AI
import Hooks
import SwiftUI

extension AIFeature {
    /// Sends what the user types under Features ▸ Test Prompt, so a provider and its fallbacks can be tried before any browsing feature uses them.
    static let testPrompt = AIFeature(id: AIFeatureID(rawValue: "testPrompt"), name: localized("Test Prompt"),
                                      summary: localized("Sends the prompt above and shows the reply, to try a provider and its fallbacks."),
                                      trigger: .user, data: .textOnly)
}

/// The AI section has more to show than the others, so it keeps one height and its pages scroll.
struct AISettingsView: View {
    /// The pages of Settings ▸ AI, in the order of its page picker.
    enum Page: String, CaseIterable {
        case providers = "Providers"
        case features = "Features"
        case sites = "Sites"
        case usage = "Usage"
        case activity = "Activity"
        case agents = "Agents"
        case agentHooks = "Hooks"

        var title: String {
            switch self {
            case .providers: return localized("Providers")
            case .features: return localized("Features")
            case .sites: return localized("Sites")
            case .usage: return localized("Usage")
            case .activity: return localized("Activity")
            case .agents: return localized("Agents")
            case .agentHooks: return localized("Hooks")
            }
        }
    }

    /// The AI section's shown page, which the Settings window keeps so that the app can open the section at a given page.
    final class Navigation: ObservableObject {
        @Published var page = Page.providers
    }

    /// The agents' service, whose page shows only when the app shell set one.
    let agents: AgentService?
    /// The hook registry. Its page shows only when the app shell set both it and the agents' service, whose runner keeps the hooks' agent runs.
    let hooks: HookRegistry?
    @ObservedObject private var service = AIService.shared
    @ObservedObject private var settings = AIService.shared.settings
    @ObservedObject var navigation: Navigation
    /// The Test Prompt request, kept here rather than in its rows, so that leaving the Features page or the section stops it: it then neither runs on unseen nor lets Send start a second one when the page shows again.
    @State private var testPromptTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Picker(localized("Page"), selection: $navigation.page) {
                ForEach(Page.allCases.filter { ($0 != .agents || agents != nil) && ($0 != .agentHooks || (hooks != nil && agents != nil)) }, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(localized("Page"))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                if settings.replacedUnreadableFile {
                    Section {
                        Text("ai.json could not be read, so Arch renamed it ai.json.unreadable and started with new AI settings.", bundle: .module)
                            .foregroundStyle(.secondary)
                    }
                }
                switch navigation.page {
                case .providers: AIProvidersPage(service: service, settings: settings)
                case .features: AIFeaturesPage(service: service, settings: settings, hooks: service.hooks, testPromptTask: $testPromptTask)
                case .sites: AISitesPage(settings: settings)
                case .usage: AIUsagePage(usage: service.usage, settings: settings)
                case .activity: AIActivityPage(service: service, settings: settings)
                case .agents:
                    if let agents {
                        AgentSettingsPage(service: agents, activity: agents.activity, hookName: { id in hooks?.hooks.first { $0.id == id }?.name })
                    }
                case .agentHooks:
                    if let hooks, let agents {
                        AgentHooksPage(registry: hooks, runner: agents.runs, currentTab: { PreferencesWindowController.session?.lastMainWindow?.selectedTabID })
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: sectionWidth, height: 540)
        .onAppear { service.register(.testPrompt) }
        .onChange(of: navigation.page) { testPromptTask?.cancel() }
        .onDisappear { testPromptTask?.cancel() }
    }
}

// MARK: - Features

/// The default route, then one section per registered feature with a stored route, with its switch, its models, what it sends, and its last error, and for a feature whose hooks paused, a way to resume them, then the model tiers. The Test Prompt feature's section also holds the prompt. A feature whose requests name their own routes has no models to choose here; Usage lists it by name.
private struct AIFeaturesPage: View {
    @ObservedObject var service: AIService
    @ObservedObject var settings: AISettingsStore
    @ObservedObject var hooks: AIHookCenter
    @Binding var testPromptTask: Task<Void, Never>?

    var body: some View {
        Section {
            AIRoutePickers(settings: settings, feature: .defaultRoute, emptyChoice: nil)
        } header: {
            Text("Default Model", bundle: .module)
        } footer: {
            formFootnote(localized("Features you start, such as a question about a page, use these models unless they have their own. Features that run on their own never do."))
        }
        ForEach(service.features.filter { $0.routing == .stored }) { feature in
            Section {
                Toggle(localized("Use \(feature.name)"), isOn: Binding(
                    get: { settings.route(for: feature.id).isEnabled },
                    set: { isOn in
                        var route = settings.route(for: feature.id)
                        route.isEnabled = isOn
                        settings.setRoute(route, for: feature.id)
                    }))
                AIRoutePickers(settings: settings, feature: feature.id, emptyChoice: feature.trigger == .user ? localized("Same as Default Model") : localized("None"))
                if feature.id == AIFeature.testPrompt.id {
                    AITestPromptRows(service: service, settings: settings, task: $testPromptTask)
                } else if let error = lastError(of: feature) {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if hooks.pausedFeatures.contains(feature.id) {
                    HStack {
                        Text("Paused after \(AIHookCenter.failuresBeforePause) failed requests in a row.", bundle: .module).foregroundStyle(.secondary)
                        Spacer()
                        Button(localized("Resume")) { hooks.resume(feature.id) }
                    }
                }
            } header: {
                Text(feature.name)
            } footer: {
                formFootnote(localized("\(feature.summary) \(Self.sentence(for: feature))"))
            }
        }
        AIModelTierSections(settings: settings)
    }

    /// An automatic feature's hooks can also stop before a request, as for a budget or a timeout, so its last error comes from the hook center. A plugin's feature runs no hooks there, so its last error is its last request's, as for a feature the user starts.
    private func lastError(of feature: AIFeature) -> String? {
        if feature.trigger == .automatic, !feature.id.rawValue.hasPrefix(AIFeatureID.plugin("").rawValue) { return hooks.lastErrors[feature.id].map(settings.message(for:)) }
        guard case .failed(let error) = service.activity.last(where: { $0.feature == feature.id })?.result else { return nil }
        return settings.message(for: error)
    }

    /// What the feature sends, in words.
    private static func sentence(for feature: AIFeature) -> String {
        let kinds = AIDataKind.allCases.filter(feature.data.kinds.contains).map(\.sentenceName)
        let sends = kinds.isEmpty ? localized("It sends text only.") : localized("It sends \(ListFormatter.localizedString(byJoining: kinds)) with its requests.")
        return feature.trigger == .automatic ? localized("\(sends) It runs on its own.") : sends
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
            Text("Add a provider with a model under Providers first.", bundle: .module).foregroundStyle(.secondary)
        } else {
            ForEach(0..<min(route.models.count + 1, AIRoute.maximumModels), id: \.self) { slot in
                let current = route.models[safe: slot]
                // A model that has left its provider stays listed until the user picks another.
                let choices = current.map { options.contains($0) ? options : options + [$0] } ?? options
                Picker(slot == 0 ? localized("Model") : localized("Fallback \(slot)"), selection: binding(slot)) {
                    if slot > 0 || emptyChoice != nil {
                        Text(slot == 0 ? emptyChoice ?? localized("None") : localized("None")).tag(AIModelRef?.none)
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
    @State private var prompt = localized("Reply with one short sentence.")
    @State private var reply = ""
    @State private var status: String?
    @State private var isError = false
    @Binding var task: Task<Void, Never>?

    var body: some View {
        TextField(localized("Prompt"), text: $prompt, axis: .vertical)
            .lineLimit(1...4)
        HStack {
            Spacer()
            if task != nil {
                Button(localized("Stop")) { task?.cancel() }
            } else {
                Button(localized("Send"), action: send)
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
                        status = localized("Waiting for a free request slot\u{2026}")
                    case .waiting(.rateLimited(let until)):
                        status = localized("Waiting for the provider\u{2019}s rate limit until \(until.formatted(date: .omitted, time: .standard))\u{2026}")
                    case .started(let ref):
                        model = ref
                        status = localized("Answering: \(settings.title(of: ref))")
                    case .text(let text):
                        reply += text
                    case .usage(let usage):
                        tokens = localized(" \u{00B7} \(usage.inputTokens + usage.cachedInputTokens) input and \(usage.outputTokens) output tokens")
                    case .finished(let reason):
                        let cut = reason == .lengthLimit ? localized(" The reply reached the length limit.") : ""
                        let answerer = model.map(settings.title(of:)) ?? localized("the model")
                        status = localized("Answered by \(answerer)\(tokens).\(cut)")
                    case .toolCall:
                        break
                    }
                }
                if Task.isCancelled { status = localized("Stopped.") }
            } catch AIError.cancelled {
                status = localized("Stopped.")
            } catch {
                status = settings.message(for: error)
                isError = true
            }
            task = nil
        }
    }
}

// MARK: - Model tiers

/// The end of the Features page: one section per tier with the feature rows' model menus and a sentence on what the tier is for, which names no feature, since a feature uses the models chosen for it and only a request that names a tier uses one. The first tier's footer says how a tier serves. A tier starts empty and lists every connected model; a request that names the tier drops the models that cannot serve it.
private struct AIModelTierSections: View {
    @ObservedObject var settings: AISettingsStore

    var body: some View {
        ForEach(AIModelTier.allCases, id: \.self) { tier in
            Section {
                AIRoutePickers(settings: settings, feature: .tier(tier), emptyChoice: localized("None"))
            } header: {
                Text("\(tier.title) Tier", bundle: .module)
            } footer: {
                formFootnote(tier == AIModelTier.allCases.first
                             ? localized("\(Self.purpose(of: tier)) A request that names a tier, such as an agent hook\u{2019}s, uses its model and fallbacks; the features above use the models chosen for them. A tier without a model fails and never uses another tier or the default model.")
                             : Self.purpose(of: tier))
            }
        }
    }

    private static func purpose(of tier: AIModelTier) -> String {
        switch tier {
        case .fast: return localized("For small, frequent tasks, where a quick, inexpensive model serves best.")
        case .standard: return localized("For everyday tasks that need more care than a quick, inexpensive model gives.")
        case .deep: return localized("For hard tasks that need the most capable model, at a higher cost and with slower replies.")
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
                    .help(localized("Allow AI on this site"))
                    .accessibilityLabel(localized("Allow AI on this site"))
                }
            }
            HStack {
                TextField(localized("Site"), text: $newSite, prompt: Text(verbatim: "example.org"))
                    .onSubmit(add)
                Button(localized("Add"), action: add)
                    .disabled(AISitePattern(parsing: newSite) == nil)
            }
        } header: {
            Text("AI Is Off on These Sites", bundle: .module)
        } footer: {
            formFootnote(localized("Nothing from these sites goes to any provider. A site includes its subdomains. Internal pages such as flags:// are always excluded."))
        }
    }

    private func add() {
        guard let pattern = AISitePattern(parsing: newSite) else { return }
        if !settings.excludedSites.contains(pattern) { settings.excludedSites.append(pattern) }
        newSite = ""
    }

    private static func title(of site: AISitePattern) -> String {
        switch site {
        case .fileScheme: return localized("Local files (file:)")
        case .localNetwork: return localized("Local network and this Mac")
        default: return site.value
        }
    }
}
