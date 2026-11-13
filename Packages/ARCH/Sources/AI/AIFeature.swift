// Features register with the service before they make requests. A feature names what starts its requests, the page data they may carry, and the capabilities its models need.
import Foundation

public struct AIFeature: Identifiable, Sendable {
    public var id: AIFeatureID
    public var name: String
    /// What the feature does and what it sends, in one or two sentences for Settings ▸ AI.
    public var summary: String
    public var trigger: AITrigger
    public var data: AIDataScope
    public var requirements: Set<AIModelCapability>

    public init(id: AIFeatureID, name: String, summary: String, trigger: AITrigger, data: AIDataScope, requirements: Set<AIModelCapability> = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.trigger = trigger
        self.data = data
        self.requirements = requirements
    }
}

public enum AITrigger: String, Codable, Sendable {
    /// The user starts each request, for example by asking a question.
    case user
    /// Requests start on their own, for example from a hook.
    case automatic
}

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

public enum AIDataKind: String, Codable, Sendable, CaseIterable {
    case page
    case selection
    case file
    case download
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
