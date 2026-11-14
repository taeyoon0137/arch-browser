// The AI settings in `ai.json`: providers, routes (the model tiers' among them), site exclusions, and limits. The file holds no secrets; keys go to the Keychain. Personas share one file.
import Foundation

@MainActor
public final class AISettingsStore: ObservableObject {
    @Published public var providers: [AIProviderConfiguration] { didSet { scheduleSave() } }
    /// Keyed by the feature ID's raw value. A feature without an entry uses `AIRoute.standard(for:)`.
    @Published public var routes: [String: AIRoute] { didSet { scheduleSave() } }
    @Published public var excludedSites: [AISitePattern] { didSet { scheduleSave() } }
    /// The exclusions the Allow AI on This Site switch removed, by the site it allowed, so switching that site off again puts them back. Kept for the session only.
    var exclusionsRemovedBySwitch: [String: [AISitePattern]] = [:]
    @Published public var limits: AILimits { didSet { scheduleSave() } }
    /// Whether `ai.json` failed to decode at launch and was renamed `ai.json.unreadable`, so Settings ▸ AI can say so.
    @Published public private(set) var replacedUnreadableFile = false

    private struct File: Codable {
        static let currentVersion = 1

        var version = currentVersion
        var providers: [AIProviderConfiguration] = []
        var routes: [String: AIRoute] = [:]
        var excludedSites = AISitePattern.defaultExclusions
        var limits = AILimits()

        init() {}

        /// A route as a hand-written file may hold it. Without `isEnabled` it takes its feature's standard switch, so a hook stays off and a tier, whose switch is not read, needs none.
        private struct WrittenRoute: Decodable {
            var isEnabled: Bool?
            var models: [AIModelRef]?
        }

        /// A file missing a field takes that field's default, as do the providers, routes, and limits in it for their fields that have one.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
            providers = try container.decodeIfPresent([AIProviderConfiguration].self, forKey: .providers) ?? []
            let written = try container.decodeIfPresent([String: WrittenRoute].self, forKey: .routes) ?? [:]
            routes = written.reduce(into: [:]) { routes, entry in
                let isEnabled = entry.value.isEnabled ?? AIRoute.standard(for: AIFeatureID(rawValue: entry.key)).isEnabled
                routes[entry.key] = AIRoute(isEnabled: isEnabled, models: entry.value.models ?? [])
            }
            excludedSites = try container.decodeIfPresent([AISitePattern].self, forKey: .excludedSites) ?? AISitePattern.defaultExclusions
            limits = try container.decodeIfPresent(AILimits.self, forKey: .limits) ?? AILimits()
        }
    }

    let fileURL: URL
    let keys: any AIKeyStore
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL, keys: any AIKeyStore) {
        self.fileURL = fileURL
        self.keys = keys
        var file = File()
        var isUnreadable = false
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(File.self, from: data) {
                file = decoded
            } else {
                let unreadable = fileURL.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: unreadable)
                try? FileManager.default.moveItem(at: fileURL, to: unreadable)
                isUnreadable = true
            }
        }
        providers = file.providers
        routes = file.routes
        excludedSites = file.excludedSites
        limits = file.limits
        replacedUnreadableFile = isUnreadable
        // The AI module does not link AppKit, so it names the notification; a change made just before quitting still reaches the file.
        NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    /// The stored route, or the feature's standard one. The default route without models of its own uses the first model of the first provider the user connected.
    public func route(for feature: AIFeatureID) -> AIRoute {
        var route = routes[feature.rawValue] ?? AIRoute.standard(for: feature)
        if feature == .defaultRoute, route.models.isEmpty, let provider = providers.first(where: { !$0.models.isEmpty }) {
            route.models = [AIModelRef(provider: provider.id, model: provider.models[0].name)]
        }
        return route
    }

    /// The interface's sentence for the error, which every view that shows an AI request's failure uses. An error about one provider names it as the user named it, in place of "The provider", so that after a route has moved through several models the user can tell whose key or service to look at; a provider no longer listed stays "The provider". Another error, such as the Keychain's, keeps its own description.
    public func message(for error: any Error) -> String {
        guard let error = error as? AIError else { return error.localizedDescription }
        func name(of id: AIProviderID) -> String {
            providers.first { $0.id == id }.flatMap { $0.name.isEmpty ? nil : $0.name } ?? "The provider"
        }
        switch error {
        case .authentication(let id):
            return "\(name(of: id)) did not accept the API key."
        case .providerUnavailable(let id, let detail):
            return "\(name(of: id)) is unavailable: \(detail)"
        case .rateLimited(let id, let until):
            return AIError.rateLimitMessage(provider: name(of: id), until: until)
        default:
            return error.localizedDescription
        }
    }

    /// A tier's route (`AIFeatureID.tier(_:)`) is written on, since a tier has no switch.
    public func setRoute(_ route: AIRoute, for feature: AIFeatureID) {
        var route = route
        route.models = Array(route.models.prefix(AIRoute.maximumModels))
        if feature.isTierRoute { route.isEnabled = true }
        routes[feature.rawValue] = route
    }

    /// Adds the provider, or replaces the one with the same ID. Models no longer listed leave every route.
    public func save(_ provider: AIProviderConfiguration) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        removeRouteModels { ref in ref.provider == provider.id && !provider.models.contains(where: { $0.name == ref.model }) }
    }

    /// Removes the provider's key, then the provider and its models from every route; a route left empty falls back as before. A key the Keychain keeps leaves the provider in place, so that removing it can be tried again.
    public func removeProvider(_ id: AIProviderID) async throws {
        try await keys.removeKey(for: id)
        providers.removeAll { $0.id == id }
        removeRouteModels { $0.provider == id }
    }

    /// Writes the key to the Keychain and sets the provider's `hasKey`.
    public func setKey(_ key: String, for provider: AIProviderID) async throws {
        guard let configuration = providers.first(where: { $0.id == provider }), case .http = configuration.kind else { return }
        try await keys.setKey(key, for: provider, label: "Arch AI: \(configuration.name)")
        setHasKey(true, for: provider)
    }

    public func removeKey(for provider: AIProviderID) async throws {
        try await keys.removeKey(for: provider)
        setHasKey(false, for: provider)
    }

    /// Finds the provider again after the Keychain call, during which the list may have changed.
    private func setHasKey(_ hasKey: Bool, for provider: AIProviderID) {
        guard let index = providers.firstIndex(where: { $0.id == provider }), case .http(var http) = providers[index].kind else { return }
        http.hasKey = hasKey
        providers[index].kind = .http(http)
    }

    private func removeRouteModels(where shouldRemove: (AIModelRef) -> Bool) {
        var changed = routes
        for feature in routes.keys {
            changed[feature]?.models.removeAll(where: shouldRemove)
        }
        if changed != routes { routes = changed }
    }

    /// Combines rapid changes, such as typing in a field, into one file write, like the session store.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        var file = File()
        file.providers = providers
        file.routes = routes
        file.excludedSites = excludedSites
        file.limits = limits
        guard let data = try? JSONEncoder.aiFiles.encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
