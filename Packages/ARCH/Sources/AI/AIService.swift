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
    /// Reads `ai.json` and `ai-usage.json` from the app's Application Support folder, the folder the app shell gives the browser session. Nothing goes to a provider until the user connects one and uses a feature.
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

    /// The provider's model names, for Settings ▸ AI. `key` is a key the user has typed but not saved; without one the provider's saved key is used, while the configuration keeps the saved base URL.
    public func listModels(of configuration: AIProviderConfiguration, key: String? = nil) async throws -> [String] {
        var resolvedKey = key.flatMap { $0.isEmpty ? nil : $0 }
        if resolvedKey == nil { resolvedKey = try await savedKey(forUnsaved: configuration) }
        return try await makeProvider(configuration, resolvedKey).listModels()
    }

    /// Sends a short request to the provider's first model and returns the reply, for the Check button in Settings ▸ AI. The configuration may be unsaved. The request belongs to no feature, so it waits for no rate limiter and counts toward no usage. A Claude Code or Codex preset runs its status command and probes instead, never a model.
    public func check(_ configuration: AIProviderConfiguration) async throws -> String {
        if case .commandLine(let tool) = configuration.kind, let kind = tool.agent {
            return try await checkAgentTool(tool, kind: kind)
        }
        guard let model = configuration.models.first else { throw AIError.notConfigured(.noModel) }
        let request = AIProviderRequest(model: model.name, instructions: nil, messages: [AIMessage(role: .user, parts: [.text("Reply with one short sentence.")])],
                                        tools: [], output: .text, maxOutputTokens: 256)
        var reply = ""
        for try await event in makeProvider(configuration, try await savedKey(forUnsaved: configuration)).stream(request) {
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

    /// Runs the request on its route's models in order, or on its pinned model alone. It moves to the next model only when the current one fails before any text or tool call reached the caller, so a reply is never repeated or mixed.
    private func serve(_ request: AIRequest, entry: inout AIActivityEntry, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws -> AIFinishReason {
        guard let feature = features.first(where: { $0.id == request.feature }) else { throw AIError.notConfigured(.unknownFeature) }
        let models = try models(for: request, feature: feature)
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

    /// The models that may serve the request: its pinned model alone, under the same rules as a route's models, or the feature's route. A request with tools uses only HTTP models that take tools, so a tool loop never reaches a command-line tool, also one whose capabilities the user overrode to list tool calls. Throws as `routeModels(for:carryingPageData:)` does when none is left.
    private func models(for request: AIRequest, feature: AIFeature) throws -> [AIRouteModel] {
        let carriesPageData = AIPartText.carriesData(request.messages)
        var models: [AIRouteModel]
        if let ref = request.pinnedModel {
            guard settings.route(for: feature.id).isEnabled else { throw AIError.notConfigured(.switchedOff) }
            guard let provider = settings.providers.first(where: { $0.id == ref.provider }),
                  let model = provider.models.first(where: { $0.name == ref.model }),
                  feature.requirements.isSubset(of: provider.capabilities(of: model)) else { throw AIError.notConfigured(.noUsableModel) }
            if carriesPageData, !provider.acceptsPageData { throw AIError.blockedByPolicy(.commandLineToolWithPageData) }
            models = [AIRouteModel(ref: ref, provider: provider, model: model)]
        } else {
            models = try settings.routeModels(for: feature, carryingPageData: carriesPageData)
        }
        if !request.tools.isEmpty {
            models = models.filter { candidate in
                guard case .http = candidate.provider.kind else { return false }
                return candidate.provider.capabilities(of: candidate.model).contains(.tools)
            }
            guard !models.isEmpty else { throw AIError.notConfigured(.noUsableModel) }
        }
        return models
    }

    /// One attempt on one model: rate limiting, page access checks for the model's limit, the provider's stream, and usage.
    private func send(_ request: AIRequest, feature: AIFeature, on candidate: AIRouteModel, attempt: inout AIAttempt, entry: inout AIActivityEntry) async throws -> AIFinishReason {
        entry.model = candidate.ref
        // A part the checks refuse ends the attempt before it waits.
        _ = try prepare(request, feature: feature, on: candidate, entry: &entry)
        let limiter = limiter(for: candidate.provider.id)
        await limiter.update(candidate.provider.limits)
        try await limiter.acquire(isUser: feature.trigger == .user) { [continuation = attempt.continuation] reason in
            continuation.yield(.waiting(reason))
        }
        let key: String?
        let providerRequest: AIProviderRequest
        do {
            key = try await storedKey(for: candidate.provider)
            // The waits for the slot, a cool-down, and the Keychain can last minutes. Meanwhile the request may have been cancelled, the user may have moved the provider to another base URL with that server's key, which the read by the provider's ID gave, switched AI off for the page's site, or the request ahead of it may have reached the spending limit, so each is checked again just before the request goes out.
            try Task.checkCancellation()
            if key != nil, settings.providers.first(where: { $0.id == candidate.provider.id })?.keepsItsKey(in: candidate.provider) != true {
                throw AIError.providerUnavailable(candidate.provider.id, detail: "The provider's settings changed while the request waited.")
            }
            if reachedSpendingLimit() { throw AIError.budgetReached(.monthlySpending) }
            providerRequest = try prepare(request, feature: feature, on: candidate, entry: &entry)
        } catch {
            // Nothing reached the provider, so nothing counts toward usage.
            await limiter.release(after: .other)
            throw error
        }
        var reported: AIUsage?
        var outcome: Result<AIFinishReason, AIError>
        do {
            var finishReason: AIFinishReason?
            for try await event in makeProvider(candidate.provider, key).stream(providerRequest) {
                switch event {
                case .waiting, .started:
                    continue
                case .usage(let value):
                    reported = value
                case .finished(let reason):
                    // A model that spends the whole limit thinking, as `max_completion_tokens` lets a reasoning model do, stops at the limit before any text or tool call. That is no reply, though its tokens count.
                    if reason == .lengthLimit, !attempt.hasDeliveredContent { throw AIError.replyTooLong }
                    finishReason = reason
                case .text, .toolCall:
                    attempt.hasDeliveredContent = true
                }
                attempt.yield(event, servedBy: candidate.ref)
            }
            // A cancelled request's stream ends without an error, so cancellation is checked here.
            try Task.checkCancellation()
            guard let finishReason else { throw AIError.malformedReply("The reply ended without finishing.") }
            outcome = .success(finishReason)
        } catch {
            outcome = .failure(Task.isCancelled ? .cancelled : AIError(error))
        }
        // The usage counts before the slot is freed, so the request that takes the slot next finds this one's cost in the spending limit.
        let isError: Bool
        switch outcome {
        case .success, .failure(.cancelled): isError = false
        case .failure: isError = true
        }
        entry.usage = reported
        usage.record(feature: feature, provider: candidate.provider, model: candidate.model, usage: reported, isError: isError)
        // One limiter call frees the slot and starts a 429's cool-down, so a request waiting for the slot waits for the cool-down as well.
        switch outcome {
        case .success:
            await limiter.release(after: .answered)
        case .failure(.rateLimited(let provider, let retryAfter)):
            outcome = .failure(.rateLimited(provider, until: await limiter.release(after: .rateLimited(retryAfter: retryAfter))))
        case .failure:
            await limiter.release(after: .other)
        }
        return try outcome.get()
    }

    /// The request for the candidate's model after the page access checks against the feature's scope, the excluded sites as they are now, and the model's input limit, which older tool results meet as their notes before any page text is cut. The activity entry shows its parts and content.
    private func prepare(_ request: AIRequest, feature: AIFeature, on candidate: AIRouteModel, entry: inout AIActivityEntry) throws -> AIProviderRequest {
        let policy = AIPartPolicy(scope: feature.data, excludedSites: settings.excludedSites, inputCharacterLimit: candidate.model.inputCharacterLimit, provider: candidate.provider.id)
        let checked = Self.checkedToolResults(in: request.messages, policy: policy, imageNote: Self.imageNote(for: candidate))
        let messages = try policy.prepare(AIToolHistory.fitted(checked, characterLimit: policy.inputCharacterLimit))
        let providerRequest = AIProviderRequest(model: candidate.model.name,
                                                instructions: AIPartText.instructions(request.instructions, for: messages),
                                                messages: messages, tools: request.tools, output: request.output,
                                                maxOutputTokens: request.maxOutputTokens ?? 4096)
        entry.parts = Self.partSummary(messages)
        entry.content = AIPartText.transcript(of: providerRequest)
        return providerRequest
    }

    static let imageNotTakenNote = "An image was left out: this model does not take images."
    static let imageNotInToolResultsNote = "An image was left out: this provider's format sends tool results as text."

    /// The note sent in place of each image in a tool result, or nil when the model takes them there: one with `images` on the `messages` format. The `chatCompletions` format sends a tool result as text.
    private static func imageNote(for candidate: AIRouteModel) -> String? {
        guard candidate.provider.capabilities(of: candidate.model).contains(.images) else { return imageNotTakenNote }
        if case .http(let http) = candidate.provider.kind, http.format == .messages { return nil }
        return imageNotInToolResultsNote
    }

    /// The messages with each tool result as this attempt sends it. A result that the part checks refuse, as one carrying a page or an image on an excluded site or a kind the feature does not declare, becomes an error result that says why without naming the site, so that a tool loop goes on without its data, also for a site excluded after the result arrived. With an `imageNote`, the note replaces each image.
    private static func checkedToolResults(in messages: [AIMessage], policy: AIPartPolicy, imageNote: String?) -> [AIMessage] {
        // The probe only checks; the length limit applies to the whole request afterward.
        var probe = policy
        probe.inputCharacterLimit = .max
        return messages.map { message in
            var message = message
            message.parts = message.parts.map { part in
                guard case .toolResult(var result) = part else { return part }
                if let imageNote {
                    result.parts = result.parts.map { part in
                        if case .file(let file) = part, AIPartText.isImage(file) { return .text(imageNote) }
                        return part
                    }
                }
                do {
                    _ = try probe.prepare([AIMessage(role: message.role, parts: [.toolResult(result)])])
                } catch AIError.blockedByPolicy(let reason) {
                    return .toolResult(AIToolResult(callID: result.callID, parts: [.text(refusal(reason))], isError: true))
                } catch {}
                return .toolResult(result)
            }
            return message
        }
    }

    /// What the model reads in place of a refused tool result.
    static func refusal(_ reason: AIPolicyReason) -> String {
        switch reason {
        case .siteExcluded: return "Arch did not send this result: it holds data from a site where AI is off."
        case .dataNotDeclared(let kind): return "Arch did not send this result: this feature does not send \(kind.rawValue) data."
        default: return "Arch did not send this result."
        }
    }

    /// The budget that keeps the feature from starting a request now: an automatic feature's daily request limit, or the monthly spending limit.
    func reachedBudget(for feature: AIFeature) -> AIBudget? {
        if feature.trigger == .automatic, usage.automaticRequestCount(for: feature.id) >= settings.limits.automaticRequestsPerDay {
            return .automaticRequestsPerDay
        }
        return reachedSpendingLimit() ? .monthlySpending : nil
    }

    /// Whether the month's estimated cost has reached the monthly spending limit, which stops automatic and user requests alike until the user raises it.
    private func reachedSpendingLimit() -> Bool {
        guard let limit = settings.limits.monthlySpendingLimit else { return false }
        return usage.estimatedCost(in: limit.currency) >= limit.amount
    }

    func limiter(for provider: AIProviderID) -> AIRateLimiter {
        if let limiter = limiters[provider] { return limiter }
        let limiter = AIRateLimiter(provider: provider, limits: .http)
        limiters[provider] = limiter
        return limiter
    }

    /// The provider's saved key. A key the Keychain does not give, as when the user cancels the keychain password prompt, makes the provider unavailable with the Keychain's reason rather than its key wrong, since no request went out.
    private func storedKey(for provider: AIProviderConfiguration) async throws -> String? {
        guard case .http(let http) = provider.kind, http.hasKey else { return nil }
        do {
            return try await keys.key(for: provider.id)
        } catch {
            throw AIError.providerUnavailable(provider.id, detail: "The key could not be read from the Keychain. \(error.localizedDescription)")
        }
    }

    /// The saved key for a configuration that Settings may not have saved yet. A key saved for another base URL never goes to the configuration's, so a provider moved to another server gets the key only once the user enters it again or saves the move.
    private func savedKey(forUnsaved configuration: AIProviderConfiguration) async throws -> String? {
        guard case .http(let http) = configuration.kind, http.hasKey else { return nil }
        if let saved = settings.providers.first(where: { $0.id == configuration.id }), !saved.keepsItsKey(in: configuration) {
            throw AIError.providerUnavailable(configuration.id, detail: "Enter the key again to use it with the new base URL, or save the change first.")
        }
        return try await storedKey(for: configuration)
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
