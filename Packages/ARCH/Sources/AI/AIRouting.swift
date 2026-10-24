// Routes: which models serve each feature, with up to two fallbacks. The service resolves a request's route once, at its start, and keeps it for the whole request.
import Foundation

public struct AIModelRef: Hashable, Codable, Sendable {
    public var provider: AIProviderID
    /// The provider's model name.
    public var model: String

    public init(provider: AIProviderID, model: String) {
        self.provider = provider
        self.model = model
    }
}

public struct AIRoute: Codable, Sendable, Equatable {
    /// The primary model and up to two fallbacks.
    public static let maximumModels = 3

    public var isEnabled: Bool
    /// The model to use first, then up to two fallbacks in order. Empty uses the default route, for features the user starts.
    public var models: [AIModelRef]

    public init(isEnabled: Bool, models: [AIModelRef] = []) {
        self.isEnabled = isEnabled
        self.models = models
    }

    /// The route of a feature without an entry in `ai.json`: hooks start switched off, everything else on, and none has models of its own.
    public static func standard(for feature: AIFeatureID) -> AIRoute {
        AIRoute(isEnabled: !feature.rawValue.hasPrefix("hook."))
    }
}

/// A model on a resolved route, with its provider's and its own settings at the time the request started.
struct AIRouteModel: Sendable {
    var ref: AIModelRef
    var provider: AIProviderConfiguration
    var model: AIModelConfiguration
}

extension AISettingsStore {
    /// The models that serve `feature`, in order. Throws `notConfigured` when the feature is off or has no usable model. An automatic feature never uses the default route, so nothing runs on its own until the user assigns it a model.
    func routeModels(for feature: AIFeature) throws -> [AIRouteModel] {
        let route = route(for: feature.id)
        guard route.isEnabled else { throw AIError.notConfigured(.switchedOff) }
        var refs = route.models
        if refs.isEmpty {
            let fallback = self.route(for: .defaultRoute)
            guard feature.trigger == .user, fallback.isEnabled, !fallback.models.isEmpty else { throw AIError.notConfigured(.noModel) }
            refs = fallback.models
        }
        let usable = refs.prefix(AIRoute.maximumModels).compactMap { ref -> AIRouteModel? in
            guard let provider = providers.first(where: { $0.id == ref.provider }),
                  let model = provider.models.first(where: { $0.name == ref.model }),
                  feature.requirements.isSubset(of: provider.capabilities(of: model)) else { return nil }
            return AIRouteModel(ref: ref, provider: provider, model: model)
        }
        guard !usable.isEmpty else { throw AIError.notConfigured(.noUsableModel) }
        return usable
    }
}
