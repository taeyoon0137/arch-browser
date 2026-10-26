// The AI settings in `ai.json`: providers, routes, site exclusions, and limits. The file holds no secrets; keys go to the Keychain. Personas share one file.
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

        /// A file missing a field takes that field's default, as do the providers, routes, and limits in it for their fields that have one.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
            providers = try container.decodeIfPresent([AIProviderConfiguration].self, forKey: .providers) ?? []
            routes = try container.decodeIfPresent([String: AIRoute].self, forKey: .routes) ?? [:]
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

    public func setRoute(_ route: AIRoute, for feature: AIFeatureID) {
        var route = route
        route.models = Array(route.models.prefix(AIRoute.maximumModels))
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
