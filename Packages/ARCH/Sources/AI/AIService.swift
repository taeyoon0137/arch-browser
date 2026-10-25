// The one `AIClient` the app uses. It resolves each request's route, checks budgets and page access, waits for the provider's rate limiter, moves to fallback models, and records usage and the in-memory activity list.
import Foundation

/// One finished request in Settings ▸ AI ▸ Activity, kept in memory only.
public struct AIActivityEntry: Identifiable, Sendable {
    public enum Result: Sendable {
        case completed(AIFinishReason)
        case failed(AIError)
        case cancelled
    }

    public let id = UUID()
    public var date: Date
    public var feature: AIFeatureID
    /// The last model tried; nil when the request ended before reaching one.
    public var model: AIModelRef?
    /// The kind and character count of each part sent, such as `("page", 4200)`.
    public var parts: [(kind: String, characters: Int)]
    public var result: Result
    public var usage: AIUsage?
    /// What was sent, as text. Settings ▸ AI shows it on request; quitting clears it.
    public var content: String
}

@MainActor
public final class AIService: ObservableObject, AIClient {
    /// Reads `ai.json` and `ai-usage.json` from the app's Application Support folder. Nothing goes to a provider until the user connects one and uses a feature.
    public static let shared = AIService(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Arch"))

    public static let activityLimit = 50

    public let settings: AISettingsStore
    public let usage: AIUsageStore
    /// Where features subscribe to browser events, which run their requests through this service.
    public private(set) lazy var hooks = AIHookCenter(service: self)
    @Published public private(set) var features: [AIFeature] = []
    /// The last 50 requests, newest last, kept in memory only.
    @Published public private(set) var activity: [AIActivityEntry] = []

    private let keys: any AIKeyStore
    private let makeProvider: @MainActor (AIProviderConfiguration, String?) -> any AIProvider
    private var limiters: [AIProviderID: AIRateLimiter] = [:]

    public convenience init(directory: URL) {
        let keys = AIKeychain()
        let session = AIRedirectGuard.makeSession()
        self.init(settings: AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys),
                  usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")),
                  keys: keys,
                  makeProvider: { configuration, key in
                      switch configuration.kind {
                      case .http(let http): return HTTPProvider(configuration: configuration, http: http, key: key, session: session)
                      case .commandLine(let tool): return CommandLineProvider(configuration: configuration, tool: tool)
                      }
                  })
    }

    init(settings: AISettingsStore, usage: AIUsageStore, keys: any AIKeyStore, makeProvider: @escaping @MainActor (AIProviderConfiguration, String?) -> any AIProvider) {
        self.settings = settings
        self.usage = usage
        self.keys = keys
        self.makeProvider = makeProvider
    }

    // MARK: Features

    /// Adds the feature, or replaces the registered one with the same ID.
    public func register(_ feature: AIFeature) {
        if let index = features.firstIndex(where: { $0.id == feature.id }) {
            features[index] = feature
        } else {
            features.append(feature)
        }
    }

    public func unregister(_ id: AIFeatureID) {
        features.removeAll { $0.id == id }
    }

    /// Whether the feature is on and has a usable route. Commands for a feature that is not available stay hidden.
    public func isAvailable(_ id: AIFeatureID) -> Bool {
        guard let feature = features.first(where: { $0.id == id }) else { return false }
        return (try? settings.routeModels(for: feature)) != nil
    }

    /// The provider's model names, for Settings ▸ AI. `key` is a key the user has typed but not saved; without one the provider's saved key is used.
    public func listModels(of configuration: AIProviderConfiguration, key: String? = nil) async throws -> [String] {
        var resolvedKey = key.flatMap { $0.isEmpty ? nil : $0 }
        if resolvedKey == nil { resolvedKey = try await storedKey(for: configuration) }
        return try await makeProvider(configuration, resolvedKey).listModels()
    }

    /// Sends a short request to the provider's first model and returns the reply, for the Check button in Settings ▸ AI. The configuration may be unsaved. The request belongs to no feature, so it waits for no rate limiter and counts toward no usage.
    public func check(_ configuration: AIProviderConfiguration) async throws -> String {
        guard let model = configuration.models.first else { throw AIError.notConfigured(.noModel) }
        let request = AIProviderRequest(model: model.name, instructions: nil, messages: [AIMessage(role: .user, parts: [.text("Reply with one short sentence.")])],
                                        tools: [], output: .text, maxOutputTokens: 256)
        var reply = ""
        for try await event in makeProvider(configuration, try await storedKey(for: configuration)).stream(request) {
            if case .text(let text) = event { reply += text }
        }
        // A stream read by a cancelled task ends without an error.
        if Task.isCancelled { throw AIError.cancelled }
        return reply
    }

    // MARK: Requests

    nonisolated public func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var entry = AIActivityEntry(date: Date(), feature: request.feature, model: nil, parts: [], result: .cancelled, usage: nil, content: "")
                do {
                    let reason = try await self.serve(request, entry: &entry, continuation: continuation)
                    entry.result = .completed(reason)
                    continuation.finish()
                } catch {
                    let error = Task.isCancelled ? AIError.cancelled : AIError(error)
                    if case .cancelled = error { entry.result = .cancelled } else { entry.result = .failed(error) }
                    continuation.finish(throwing: error)
                }
                self.activity.append(entry)
                if self.activity.count > Self.activityLimit { self.activity.removeFirst(self.activity.count - Self.activityLimit) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs the request on its route's models in order. It moves to the next model only when the current one fails before any text or tool call reached the caller, so a reply is never repeated or mixed.
    private func serve(_ request: AIRequest, entry: inout AIActivityEntry, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws -> AIFinishReason {
        guard let feature = features.first(where: { $0.id == request.feature }) else { throw AIError.notConfigured(.unknownFeature) }
        let models = try settings.routeModels(for: feature, carryingPageData: AIPartText.carriesData(request.messages))
        if let budget = reachedBudget(for: feature) { throw AIError.budgetReached(budget) }
        if feature.trigger == .automatic { usage.countAutomaticRequest(for: feature.id) }
        var attempt = AIAttempt(continuation: continuation)
        var lastError = AIError.notConfigured(.noUsableModel)
        for (index, candidate) in models.enumerated() {
            let hasNext = index + 1 < models.count
            var retries = 0
            while true {
                do {
                    return try await send(request, feature: feature, on: candidate, attempt: &attempt, entry: &entry)
                } catch let error as AIError where !attempt.hasDeliveredContent && !Task.isCancelled && error.movesToNextModel {
                    lastError = error
                    guard case .rateLimited(_, let until) = error else { break }
                    // A cool-down of up to 10 seconds waits in the limiter and tries the same model again. A longer one goes to the next model; without one, a user request keeps waiting, while an automatic one has already waited its limit.
                    let isLong = until.map { $0.timeIntervalSinceNow > 10 } ?? true
                    if isLong && (hasNext || feature.trigger == .automatic) { break }
                    retries += 1
                    if retries > 2 { break }
                }
            }
        }
        throw lastError
    }

    /// One attempt on one model: rate limiting, page access checks for the model's limit, the provider's stream, and usage.
    private func send(_ request: AIRequest, feature: AIFeature, on candidate: AIRouteModel, attempt: inout AIAttempt, entry: inout AIActivityEntry) async throws -> AIFinishReason {
        entry.model = candidate.ref
        let policy = AIPartPolicy(scope: feature.data, excludedSites: settings.excludedSites, inputCharacterLimit: candidate.model.inputCharacterLimit, provider: candidate.provider.id)
        let messages = try policy.prepare(request.messages)
        let providerRequest = AIProviderRequest(model: candidate.model.name,
                                                instructions: AIPartText.instructions(request.instructions, for: messages),
                                                messages: messages, tools: request.tools, output: request.output,
                                                maxOutputTokens: request.maxOutputTokens ?? 4096)
        entry.parts = Self.partSummary(messages)
        entry.content = AIPartText.transcript(of: providerRequest)
        let limiter = limiter(for: candidate.provider.id)
        await limiter.update(candidate.provider.limits)
        try await limiter.acquire(isUser: feature.trigger == .user) { [continuation = attempt.continuation] reason in
            continuation.yield(.waiting(reason))
        }
        var reported: AIUsage?
        do {
            let key = try await storedKey(for: candidate.provider)
            var finishReason: AIFinishReason?
            for try await event in makeProvider(candidate.provider, key).stream(providerRequest) {
                switch event {
                case .waiting, .started:
                    continue
                case .usage(let value):
                    reported = value
                case .finished(let reason):
                    finishReason = reason
                case .text, .toolCall:
                    attempt.hasDeliveredContent = true
                }
                attempt.yield(event, servedBy: candidate.ref)
            }
            // A cancelled request's stream ends without an error, so cancellation is checked here.
            try Task.checkCancellation()
            guard let finishReason else { throw AIError.malformedReply("The reply ended without finishing.") }
            await limiter.release()
            await limiter.recordSuccess()
            entry.usage = reported
            usage.record(feature: feature, provider: candidate.provider, model: candidate.model, usage: reported, isError: false)
            return finishReason
        } catch {
            await limiter.release()
            var error = Task.isCancelled ? AIError.cancelled : AIError(error)
            if case .rateLimited(let provider, let retryAfter) = error {
                error = .rateLimited(provider, until: await limiter.coolDown(retryAfter: retryAfter))
            }
            entry.usage = reported
            let isCancelled: Bool
            if case .cancelled = error { isCancelled = true } else { isCancelled = false }
            usage.record(feature: feature, provider: candidate.provider, model: candidate.model, usage: reported, isError: !isCancelled)
            throw error
        }
    }

    /// The budget that keeps the feature from starting a request now: an automatic feature's daily request limit, or the monthly spending limit, which stops automatic and user requests alike until the user raises it.
    func reachedBudget(for feature: AIFeature) -> AIBudget? {
        let limits = settings.limits
        if feature.trigger == .automatic, usage.automaticRequestCount(for: feature.id) >= limits.automaticRequestsPerDay {
            return .automaticRequestsPerDay
        }
        if let limit = limits.monthlySpendingLimit, usage.estimatedCost(in: limit.currency) >= limit.amount {
            return .monthlySpending
        }
        return nil
    }

    private func limiter(for provider: AIProviderID) -> AIRateLimiter {
        if let limiter = limiters[provider] { return limiter }
        let limiter = AIRateLimiter(provider: provider, limits: .http)
        limiters[provider] = limiter
        return limiter
    }

    /// The Keychain read can wait for the user to unlock the keychain, so it runs off the main thread.
    private func storedKey(for provider: AIProviderConfiguration) async throws -> String? {
        guard case .http(let http) = provider.kind, http.hasKey else { return nil }
        let keys = keys
        let id = provider.id
        do {
            return try await Task.detached { try keys.key(for: id) }.value
        } catch {
            throw AIError.authentication(id)
        }
    }

    private static func partSummary(_ messages: [AIMessage]) -> [(kind: String, characters: Int)] {
        messages.flatMap(\.parts).map { part in
            let kind: String
            switch part {
            case .text: kind = "text"
            case .page: kind = "page"
            case .selection: kind = "selection"
            case .file: kind = "file"
            case .download: kind = "download"
            case .toolCall: kind = "tool call"
            case .toolResult: kind = "tool result"
            }
            return (kind, AIPartPolicy.characterCount(of: [AIMessage(role: .user, parts: [part])]))
        }
    }
}

/// The state one request carries across its attempts: whether content reached the caller, and whether `started` has been sent for the serving model.
private struct AIAttempt {
    let continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation
    var hasDeliveredContent = false
    private var startedModel: AIModelRef?

    init(continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        self.continuation = continuation
    }

    /// Sends `started` before the first event a model produces, so it names the model that serves the request.
    mutating func yield(_ event: AIEvent, servedBy model: AIModelRef) {
        if startedModel != model {
            startedModel = model
            continuation.yield(.started(model))
        }
        continuation.yield(event)
    }
}
