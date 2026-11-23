// Routes: which models serve each feature, with up to two fallbacks, and the routes a request names for itself, a model tier or models of its own (`docs/hooks.md`, Model choice and tiers). The service resolves a request's route once, at its start, and keeps it for the whole request. The interface names a route's models and estimates their costs here.
import Foundation

/// A provider and its model name as stored in a feature route.
public struct AIModelRef: Hashable, Codable, Sendable {
    public var provider: AIProviderID
    /// The provider's model name. Empty for a command-line tool's own default model.
    public var model: String

    public init(provider: AIProviderID, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// Whether a feature is enabled and which models it tries in order.
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

    private enum CodingKeys: String, CodingKey {
        case isEnabled, models
    }

    /// A route written by hand may lack its models, which then means none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        models = try container.decodeIfPresent([AIModelRef].self, forKey: .models) ?? []
    }

    /// The route of a feature without an entry in `ai.json`: hooks start switched off, everything else on, and none has models of its own. A tier's route is on and starts empty.
    public static func standard(for feature: AIFeatureID) -> AIRoute {
        AIRoute(isEnabled: !feature.rawValue.hasPrefix("hook."))
    }
}

// MARK: - Model tiers and request routes

/// Models the user assigns once in Settings ▸ AI ▸ Features, so that a caller names the kind of model it needs rather than a model (hook decision 6).
public enum AIModelTier: String, Codable, Hashable, Sendable, CaseIterable {
    case fast
    case standard
    case deep

    /// "Fast", "Standard", or "Deep".
    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .standard: return "Standard"
        case .deep: return "Deep"
        }
    }
}

extension AIFeatureID {
    /// The route that holds a tier's models in `ai.json`: `tier.fast`, `tier.standard`, or `tier.deep`. Like `defaultRoute`, it is not a feature itself.
    public static func tier(_ tier: AIModelTier) -> AIFeatureID {
        AIFeatureID(rawValue: "tier.\(tier.rawValue)")
    }

    /// Whether this names a tier's route, whose `isEnabled` is written true and never read.
    var isTierRoute: Bool {
        AIModelTier.allCases.contains { .tier($0) == self }
    }
}

/// The route a request names for itself: a tier, or a model and up to two fallbacks. It encodes as `{"tier": "fast"}` or `{"models": [{"provider": …, "model": …}]}`, the form agent run options take in JavaScript and on the wire; a value with both keys does not decode, so neither choice is dropped unseen.
public enum AIRouteChoice: Codable, Hashable, Sendable {
    case tier(AIModelTier)
    /// A model and up to two fallbacks; later models are left out.
    case models([AIModelRef])

    private enum CodingKeys: String, CodingKey {
        case tier
        case models
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard !(container.contains(.tier) && container.contains(.models)) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "A route names a tier or models, not both."))
        }
        if let tier = try container.decodeIfPresent(AIModelTier.self, forKey: .tier) {
            self = .tier(tier)
        } else if let models = try container.decodeIfPresent([AIModelRef].self, forKey: .models) {
            self = .models(models)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "A route names a tier or models."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tier(let tier): try container.encode(tier, forKey: .tier)
        case .models(let models): try container.encode(models, forKey: .models)
        }
    }
}

/// A model on a resolved route, with its provider's and its own settings at the time the request started.
struct AIRouteModel: Sendable {
    var ref: AIModelRef
    var provider: AIProviderConfiguration
    var model: AIModelConfiguration
}

extension AISettingsStore {
    /// The models that serve `feature` for a request that names `choice` or none, in order. Throws `notConfigured` when the feature is off or has no usable model, and `blockedByPolicy(.routeNotAllowed)` when a stored automatic feature is given a route. An automatic feature never uses the default route, so nothing runs on its own until the user assigns it a model. A request that carries page data skips command-line tools that may run their own tools, and throws `blockedByPolicy` when only that rule left no model.
    func routeModels(for feature: AIFeature, route choice: AIRouteChoice? = nil, carryingPageData: Bool = false) throws -> [AIRouteModel] {
        let refs = try routeRefs(for: feature, choice: choice)
        let usable = refs.prefix(AIRoute.maximumModels).compactMap { ref -> AIRouteModel? in
            guard let provider = providers.first(where: { $0.id == ref.provider }),
                  let model = provider.models.first(where: { $0.name == ref.model }),
                  feature.requirements.isSubset(of: provider.capabilities(of: model)) else { return nil }
            return AIRouteModel(ref: ref, provider: provider, model: model)
        }
        guard !usable.isEmpty else { throw AIError.notConfigured(.noUsableModel) }
        guard carryingPageData else { return usable }
        let allowed = usable.filter(\.provider.acceptsPageData)
        guard !allowed.isEmpty else { throw AIError.blockedByPolicy(.commandLineToolWithPageData) }
        return allowed
    }

    /// The models a route names, before the checks above drop any. A `perRequest` feature takes the request's route and has none without one. A stored feature's switch applies to every request; one the user starts may name its own route, while an automatic one keeps the models the user chose for it, so a request cannot move Tab Names to another provider.
    private func routeRefs(for feature: AIFeature, choice: AIRouteChoice?) throws -> [AIModelRef] {
        switch feature.routing {
        case .perRequest:
            guard let choice else { throw AIError.notConfigured(.noModel) }
            return try refs(of: choice)
        case .stored:
            if choice != nil, feature.trigger == .automatic {
                throw AIError.blockedByPolicy(.routeNotAllowed)
            }
            let route = route(for: feature.id)
            guard route.isEnabled else { throw AIError.notConfigured(.switchedOff) }
            if let choice { return try refs(of: choice) }
            if !route.models.isEmpty { return route.models }
            let fallback = self.route(for: .defaultRoute)
            guard feature.trigger == .user, fallback.isEnabled, !fallback.models.isEmpty else { throw AIError.notConfigured(.noModel) }
            return fallback.models
        }
    }

    /// A tier's models, or the models a request names. An empty tier fails rather than using another tier or the default route, since the user chose the tier for its cost (hook decision 6).
    private func refs(of choice: AIRouteChoice) throws -> [AIModelRef] {
        switch choice {
        case .tier(let tier):
            let models = route(for: .tier(tier)).models
            guard !models.isEmpty else { throw AIError.notConfigured(.emptyTier(tier)) }
            return models
        case .models(let models):
            guard !models.isEmpty else { throw AIError.notConfigured(.noModel) }
            return models
        }
    }
}

// MARK: - Model names and costs

/// A model's name in lists. A command-line tool's own default model has no name.
public func aiModelTitle(_ name: String) -> String {
    name.isEmpty ? "default model" : name
}

extension AISettingsStore {
    /// "Provider — model", for pickers and for the line under an answer.
    public func title(of ref: AIModelRef) -> String {
        guard let provider = providers.first(where: { $0.id == ref.provider }) else { return "\(aiModelTitle(ref.model)) (removed)" }
        return "\(provider.name) \u{2014} \(aiModelTitle(ref.model))"
    }

    /// The estimated cost of `usage` on the model `ref` names, in its price's currency, or nil when the model has no price.
    public func estimatedCost(of usage: AIUsage, on ref: AIModelRef) -> AIMoney? {
        let model = providers.first(where: { $0.id == ref.provider })?.models.first(where: { $0.name == ref.model })
        guard let price = model?.price else { return nil }
        return AIMoney(currency: price.currency, amount: price.cost(of: usage))
    }
}
