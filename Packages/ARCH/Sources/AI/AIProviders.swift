// The providers the user connects, as stored in `ai.json`, and the internal protocol that each provider kind implements. Provider types other than the configurations stay internal to this module, so no feature calls a provider directly.
import Foundation

public struct AIProviderID: RawRepresentable, Hashable, Codable, Sendable {
    /// A UUID string made when the user adds the provider.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A new identifier for a provider the user adds.
    public init() {
        rawValue = UUID().uuidString
    }
}

public struct AIProviderConfiguration: Identifiable, Codable, Sendable, Equatable {
    public var id: AIProviderID
    public var name: String
    public var kind: AIProviderKind
    public var models: [AIModelConfiguration]
    public var limits: AIProviderLimits

    public init(id: AIProviderID = AIProviderID(), name: String, kind: AIProviderKind, models: [AIModelConfiguration] = [], limits: AIProviderLimits = .http) {
        self.id = id
        self.name = name
        self.kind = kind
        self.models = models
        self.limits = limits
    }

    /// The capabilities a model of this provider has unless it overrides them.
    public var defaultCapabilities: Set<AIModelCapability> {
        switch kind {
        case .http(let http): return http.format.capabilities
        }
    }

    func capabilities(of model: AIModelConfiguration) -> Set<AIModelCapability> {
        model.capabilities ?? defaultCapabilities
    }
}

/// Encodes as an object with one key named after the case, such as `{ "http": { … } }`, which the synthesized conformance would not do.
public enum AIProviderKind: Codable, Sendable, Equatable {
    case http(AIHTTPConfiguration)

    private enum CodingKeys: String, CodingKey {
        case http
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let http = try container.decodeIfPresent(AIHTTPConfiguration.self, forKey: .http) {
            self = .http(http)
            return
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown provider kind"))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .http(let http): try container.encode(http, forKey: .http)
        }
    }
}

public struct AIModelConfiguration: Codable, Sendable, Equatable {
    public static let defaultInputCharacterLimit = 100_000

    /// The provider's model name.
    public var name: String
    /// Characters of all parts together that one request may carry; page text is cut to fit.
    public var inputCharacterLimit: Int
    public var price: AIPrice?
    /// nil uses the capabilities of the provider's format.
    public var capabilities: Set<AIModelCapability>?

    public init(name: String, inputCharacterLimit: Int = AIModelConfiguration.defaultInputCharacterLimit, price: AIPrice? = nil, capabilities: Set<AIModelCapability>? = nil) {
        self.name = name
        self.inputCharacterLimit = inputCharacterLimit
        self.price = price
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case name, inputCharacterLimit, price, capabilities
    }

    /// A model entered by name may lack a limit, which then takes the default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        inputCharacterLimit = try container.decodeIfPresent(Int.self, forKey: .inputCharacterLimit) ?? Self.defaultInputCharacterLimit
        price = try container.decodeIfPresent(AIPrice.self, forKey: .price)
        capabilities = try container.decodeIfPresent(Set<AIModelCapability>.self, forKey: .capabilities)
    }
}

public struct AIProviderLimits: Codable, Sendable, Equatable {
    /// Default 4 for HTTP providers.
    public var concurrentRequests: Int
    /// nil means no limit.
    public var requestsPerMinute: Int?

    public init(concurrentRequests: Int, requestsPerMinute: Int? = nil) {
        self.concurrentRequests = concurrentRequests
        self.requestsPerMinute = requestsPerMinute
    }

    public static let http = AIProviderLimits(concurrentRequests: 4)
}

// MARK: - HTTP APIs

public struct AIHTTPConfiguration: Codable, Sendable, Equatable {
    public var format: AIWireFormat
    /// https, or http only for a loopback host such as a model server on this Mac.
    public var baseURL: URL
    /// Extra headers that are not secret, such as a version header the format requires.
    public var headers: [String: String]
    /// Whether the Keychain holds a key for this provider. The key itself is never in this value or in `ai.json`.
    public var hasKey: Bool

    public init(format: AIWireFormat, baseURL: URL, headers: [String: String] = [:], hasKey: Bool = false) {
        self.format = format
        self.baseURL = baseURL
        self.headers = headers
        self.hasKey = hasKey
    }

    /// Whether requests may go to `url`: https to any host, or http to a loopback host only.
    public static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return false }
        switch scheme {
        case "https": return true
        case "http": return host == "localhost" || host.hasSuffix(".localhost") || AISitePattern.isLoopbackAddress(host)
        default: return false
        }
    }
}

public enum AIWireFormat: String, Codable, Sendable, CaseIterable {
    case chatCompletions
    case messages

    public var capabilities: Set<AIModelCapability> {
        switch self {
        case .chatCompletions: return [.tools, .jsonOutput, .images]
        case .messages: return [.tools, .jsonOutput, .images, .files]
        }
    }

    /// The headers that carry the key.
    func authorizationHeaders(key: String) -> [String: String] {
        switch self {
        case .chatCompletions: return ["Authorization": "Bearer \(key)"]
        case .messages: return ["x-api-key": key]
        }
    }
}

// MARK: - Provider protocol

/// One connected provider. Internal to the `AI` module.
protocol AIProvider: Sendable {
    var configuration: AIProviderConfiguration { get }
    func listModels() async throws -> [String]
    /// Emits `text`, `toolCall`, `usage`, and `finished`; the service adds `waiting` and `started`.
    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<AIEvent, any Error>
}

struct AIProviderRequest: Sendable {
    var model: String
    var instructions: String?
    /// After the service's checks: page parts cut to fit and addresses without query or fragment.
    var messages: [AIMessage]
    var tools: [AITool]
    var output: AIOutputFormat
    var maxOutputTokens: Int
}
