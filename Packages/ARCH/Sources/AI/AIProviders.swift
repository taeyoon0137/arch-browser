// The providers the user connects, as stored in `ai.json`, and the internal protocol that each provider kind implements. Provider types other than the configurations stay internal to this module, so no feature calls a provider directly.
import CryptoKit
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

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, models, limits
    }

    /// A provider written by hand may lack its models and limits, which then take the defaults: no models, and the limits of its kind.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AIProviderID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(AIProviderKind.self, forKey: .kind)
        models = try container.decodeIfPresent([AIModelConfiguration].self, forKey: .models) ?? []
        if let limits = try container.decodeIfPresent(AIProviderLimits.self, forKey: .limits) {
            self.limits = limits
        } else if case .commandLine = kind {
            limits = .commandLine
        } else {
            limits = .http
        }
    }

    /// The destination sealed with a user-approved hook. Includes the CLI invocation's preset, arguments and environment.
    public var hookDestination: String {
        switch kind {
        case .http(let http):
            return http.baseURL.absoluteString
        case .commandLine(let tool):
            struct Invocation: Encodable {
                var agent: AIAgentKind?
                var arguments: [String]
                var environment: [String: String]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(Invocation(agent: tool.agent, arguments: tool.arguments, environment: tool.environment))) ?? Data()
            return tool.executable.path + " sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Whether the key saved for this provider may go with `edited`, the same provider with other settings: an HTTP provider's key goes only to the base URL it was saved for, and a command-line provider has none.
    public func keepsItsKey(in edited: AIProviderConfiguration) -> Bool {
        switch (kind, edited.kind) {
        case let (.http(saved), .http(edited)): return saved.baseURL == edited.baseURL
        case (.commandLine, .commandLine): return true
        default: return false
        }
    }

    /// The capabilities a model of this provider has unless it overrides them. `agent` is not among them, since it is derived (`capabilities(of:)`).
    public var defaultCapabilities: Set<AIModelCapability> {
        switch kind {
        case .http(let http): return http.format.capabilities
        case .commandLine: return AICommandLineConfiguration.capabilities
        }
    }

    /// The subscription tool this provider uses for sessions, if it is a CLI preset.
    public var commandLineAgent: AIAgentKind? {
        guard case .commandLine(let configuration) = kind else { return nil }
        return configuration.agent
    }

    /// The model's capabilities. `agent` is derived and no override adds or removes it (agent decision 14): a model of a Claude Code or Codex preset has it, and an HTTP model has it while it has `tools`.
    public func capabilities(of model: AIModelConfiguration) -> Set<AIModelCapability> {
        var capabilities = (model.capabilities ?? defaultCapabilities).subtracting([.agent])
        switch kind {
        case .http:
            if capabilities.contains(.tools) { capabilities.insert(.agent) }
        case .commandLine(let tool):
            if tool.agent != nil { capabilities.insert(.agent) }
        }
        return capabilities
    }

    /// Whether requests with page, selection, file, or download parts may go to this provider. A tool that can run commands could be steered by text in a page, so a command-line tool gets page data only when the user confirmed that its arguments turn its own tools off, or when it is a Claude Code or Codex preset, whose ordinary requests Arch runs with every tool off (agent decision 4).
    var acceptsPageData: Bool {
        switch kind {
        case .http: return true
        case .commandLine(let tool): return tool.runsWithoutTools || tool.agent != nil
        }
    }
}

/// Encodes as an object with one key named after the case, such as `{ "http": { … } }`, which the synthesized conformance would not do.
public enum AIProviderKind: Codable, Sendable, Equatable {
    case http(AIHTTPConfiguration)
    case commandLine(AICommandLineConfiguration)

    private enum CodingKeys: String, CodingKey {
        case http
        case commandLine
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let http = try container.decodeIfPresent(AIHTTPConfiguration.self, forKey: .http) {
            self = .http(http)
            return
        }
        if let tool = try container.decodeIfPresent(AICommandLineConfiguration.self, forKey: .commandLine) {
            self = .commandLine(tool)
            return
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown provider kind"))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .http(let http): try container.encode(http, forKey: .http)
        case .commandLine(let tool): try container.encode(tool, forKey: .commandLine)
        }
    }
}

public struct AIModelConfiguration: Codable, Sendable, Equatable {
    public static let defaultInputCharacterLimit = 100_000

    /// The provider's model name. Empty for a command-line tool's own default model.
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
    /// Default 4 for HTTP providers and 1 for command-line tools.
    public var concurrentRequests: Int
    /// nil means no limit.
    public var requestsPerMinute: Int?

    public init(concurrentRequests: Int, requestsPerMinute: Int? = nil) {
        self.concurrentRequests = concurrentRequests
        self.requestsPerMinute = requestsPerMinute
    }

    public static let http = AIProviderLimits(concurrentRequests: 4)
    public static let commandLine = AIProviderLimits(concurrentRequests: 1)
    /// Claude Code and Codex: a running agent turn holds one slot, so the page reader still gets the other.
    public static let agentPreset = AIProviderLimits(concurrentRequests: 2)
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

    private enum CodingKeys: String, CodingKey {
        case format, baseURL, headers, hasKey
    }

    /// A provider written by hand may lack its headers and `hasKey`, which then mean no extra headers and no key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(AIWireFormat.self, forKey: .format)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        hasKey = try container.decodeIfPresent(Bool.self, forKey: .hasKey) ?? false
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

// MARK: - Command-line tools

/// A command-line tool whose arguments and output Arch knows: Claude Code's `claude` or Codex's `codex`, which connect the user's subscription (`docs/agents.md`, Sessions on the user's CLI).
public enum AIAgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
}

/// A tool the user installed and signed in to in the built-in terminal. Each request runs it without a window; the tool keeps its own sign-in, which Arch never reads.
public struct AICommandLineConfiguration: Codable, Sendable, Equatable {
    /// JSON replies, asked for in the instructions and checked as JSON. Tools get no tools from Arch, except Arch's own in an agent session, and only text files.
    public static let capabilities: Set<AIModelCapability> = [.jsonOutput]
    /// The text in `arguments` that becomes the model's name.
    public static let modelPlaceholder = "{model}"

    /// An absolute path, found through the login shell's PATH when the user adds the tool. Stored as a path.
    public var executable: URL
    /// `{model}` is replaced with the model name; an argument that contains it is left out for the tool's default model.
    public var arguments: [String]
    /// Added to the minimal environment. Stored in `ai.json`, so values must not be secrets.
    public var environment: [String: String]
    public var output: AICommandLineOutput
    /// The user confirmed that `arguments` turn off the tool's own tools, such as running commands or editing files.
    public var runsWithoutTools: Bool
    /// Set by the Claude Code and Codex presets. Arch then builds every argument and reads the output in the kind's format; `arguments`, `output`, and `runsWithoutTools` do not apply.
    public var agent: AIAgentKind?

    public init(executable: URL, arguments: [String] = [], environment: [String: String] = [:], output: AICommandLineOutput = .text, runsWithoutTools: Bool = false, agent: AIAgentKind? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.output = output
        self.runsWithoutTools = runsWithoutTools
        self.agent = agent
    }

    private enum CodingKeys: String, CodingKey {
        case executable, arguments, environment, output, runsWithoutTools, agent
    }

    /// The executable is a plain path in `ai.json`, not a `file:` URL.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        executable = URL(fileURLWithPath: try container.decode(String.self, forKey: .executable))
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        output = try container.decodeIfPresent(AICommandLineOutput.self, forKey: .output) ?? .text
        runsWithoutTools = try container.decodeIfPresent(Bool.self, forKey: .runsWithoutTools) ?? false
        agent = try container.decodeIfPresent(AIAgentKind.self, forKey: .agent)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executable.path, forKey: .executable)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(output, forKey: .output)
        try container.encode(runsWithoutTools, forKey: .runsWithoutTools)
        try container.encodeIfPresent(agent, forKey: .agent)
    }
}

/// How a tool prints its reply. Encodes as an object with one key named after the case, such as `{ "text": {} }`, which the synthesized conformance would not do.
public enum AICommandLineOutput: Codable, Sendable, Equatable {
    /// Standard output is the reply.
    case text
    /// One JSON object per line; the paths pick fields, such as `delta.text`.
    case jsonLines(AIJSONLinePaths)

    private enum CodingKeys: String, CodingKey {
        case text
        case jsonLines
    }

    private struct NoFields: Codable {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.text) {
            self = .text
            return
        }
        if let paths = try container.decodeIfPresent(AIJSONLinePaths.self, forKey: .jsonLines) {
            self = .jsonLines(paths)
            return
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown output format"))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text: try container.encode(NoFields(), forKey: .text)
        case .jsonLines(let paths): try container.encode(paths, forKey: .jsonLines)
        }
    }
}

/// Dotted paths to fields of a tool's JSON lines, such as `delta.text`; a number picks an array element, as in `content.0.text`. A path left nil is not read.
public struct AIJSONLinePaths: Codable, Sendable, Equatable {
    /// Text to append to the reply.
    public var textDelta: String?
    /// Used when no delta arrived, for tools that print the reply once at the end.
    public var finalText: String?
    public var inputTokens: String?
    public var outputTokens: String?
    /// A field that, when present, says the request failed; its text becomes the error's detail.
    public var error: String?

    public init(textDelta: String? = nil, finalText: String? = nil, inputTokens: String? = nil, outputTokens: String? = nil, error: String? = nil) {
        self.textDelta = textDelta
        self.finalText = finalText
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.error = error
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
