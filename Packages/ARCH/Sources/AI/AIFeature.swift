// Features register with the service before they make requests. A feature names what starts its requests, the page data they may carry, the capabilities its models need, and where its requests' routes come from.
import Foundation

/// A registered AI feature's trigger, allowed data, model needs, and route source.
public struct AIFeature: Identifiable, Sendable {
    public var id: AIFeatureID
    public var name: String
    /// What the feature does and what it sends, in one or two sentences for Settings ▸ AI.
    public var summary: String
    public var trigger: AITrigger
    public var data: AIDataScope
    public var requirements: Set<AIModelCapability>
    public var routing: AIFeatureRouting

    public init(id: AIFeatureID, name: String, summary: String, trigger: AITrigger, data: AIDataScope, requirements: Set<AIModelCapability> = [],
                routing: AIFeatureRouting = .stored) {
        self.id = id
        self.name = name
        self.summary = summary
        self.trigger = trigger
        self.data = data
        self.requirements = requirements
        self.routing = routing
    }
}

/// Whether the user or the app starts each request from a feature.
public enum AITrigger: String, Codable, Sendable {
    /// The user starts each request, for example by asking a question.
    case user
    /// Requests start on their own, for example from a hook.
    case automatic
}

/// Where a feature obtains the models for its requests.
public enum AIFeatureRouting: String, Codable, Sendable {
    /// The feature's route in `ai.json`, which Settings ▸ AI ▸ Features edits. The default.
    case stored
    /// Each request names its route, as an agent hook run does. The Features page does not list this feature; Usage lists it by name.
    case perRequest
}

/// A capability a model may offer to an AI feature.
public enum AIModelCapability: String, Codable, Sendable, CaseIterable {
    case tools
    case jsonOutput
    case images
    case files
    /// Runs an agent session (`docs/agents.md`). Derived from the provider and not overridable: see `AIProviderConfiguration.capabilities(of:)`.
    case agent

    /// The capabilities a model's settings can turn on and off.
    public static let overridable = allCases.filter { $0 != .agent }
}

/// A nontext data kind that a feature may declare it sends.
public enum AIDataKind: String, Codable, Sendable, CaseIterable {
    case page
    case selection
    case file
    case download

    /// The kind as the sentences that say what requests send name it, such as "the text of pages": Settings ▸ AI's for each feature, and the install sheet's and Settings ▸ Plugins' for a plugin's `ai`.
    public var sentenceName: String {
        switch self {
        case .page: return "the text of pages"
        case .selection: return "selected text"
        case .file: return "files"
        case .download: return "download details"
        }
    }
}

/// The kinds of data a feature's requests may carry besides text.
public struct AIDataScope: Codable, Sendable {
    /// Text parts are always allowed.
    public var kinds: Set<AIDataKind>
    /// Characters of page text per page part; nil uses the model's limit.
    public var pageTextLimit: Int?

    public init(kinds: Set<AIDataKind>, pageTextLimit: Int? = nil) {
        self.kinds = kinds
        self.pageTextLimit = pageTextLimit
    }

    public static let textOnly = AIDataScope(kinds: [])
}
