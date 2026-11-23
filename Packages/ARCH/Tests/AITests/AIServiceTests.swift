// The service: route resolution, the default route for user features only, fallbacks before and not after the first text, capability filtering, part checks and truncation, the checks repeated after a request's waits, budgets, usage, cancellation, and tool rounds.
import Foundation
import Security
import Testing
@testable import AI

@MainActor
@Suite struct RoutingTests {
    @Test func userFeatureUsesTheDefaultRoute() async {
        let primary = provider("First", models: [AIModelConfiguration(name: "model-a"), AIModelConfiguration(name: "model-b")])
        let service = scriptedService(providers: [primary], script: ["model-a": [.event(.text("A")), .event(.finished(.completed))]])
        service.register(userFeature)
        #expect(service.settings.route(for: .defaultRoute).models == [AIModelRef(provider: primary.id, model: "model-a")])
        #expect(service.isAvailable(userFeature.id))
        let result = await collect(service.stream(textRequest(userFeature)))
        #expect(result.events == ["started:model-a", "text:A", "finished:completed"])
    }

    @Test func automaticFeatureNeverUsesTheDefaultRoute() async {
        let service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: [:])
        service.register(automaticFeature)
        // Hooks start switched off.
        guard case .notConfigured(.switchedOff) = await collect(service.stream(textRequest(automaticFeature))).error else {
            Issue.record("Expected switchedOff")
            return
        }
        service.settings.setRoute(AIRoute(isEnabled: true), for: automaticFeature.id)
        guard case .notConfigured(.noModel) = await collect(service.stream(textRequest(automaticFeature))).error else {
            Issue.record("Expected noModel")
            return
        }
        #expect(!service.isAvailable(automaticFeature.id))
    }

    @Test func unknownAndSwitchedOffFeatures() async {
        let service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: [:])
        guard case .notConfigured(.unknownFeature) = await collect(service.stream(textRequest(userFeature))).error else {
            Issue.record("Expected unknownFeature")
            return
        }
        service.register(userFeature)
        service.settings.setRoute(AIRoute(isEnabled: false), for: userFeature.id)
        guard case .notConfigured(.switchedOff) = await collect(service.stream(textRequest(userFeature))).error else {
            Issue.record("Expected switchedOff")
            return
        }
    }

    @Test func dropsModelsWithoutARequiredCapabilityOrProvider() async {
        let plain = AIModelConfiguration(name: "plain", capabilities: [])
        let capable = AIModelConfiguration(name: "capable")
        let first = provider("First", models: [plain, capable])
        let service = scriptedService(providers: [first], script: ["capable": [.event(.text("ok")), .event(.finished(.completed))]])
        var feature = userFeature
        feature.requirements = [.jsonOutput]
        service.register(feature)
        let gone = AIModelRef(provider: AIProviderID(), model: "missing")
        service.settings.setRoute(AIRoute(isEnabled: true, models: [gone, AIModelRef(provider: first.id, model: "plain"), AIModelRef(provider: first.id, model: "capable")]), for: feature.id)
        #expect(await collect(service.stream(textRequest(feature))).events == ["started:capable", "text:ok", "finished:completed"])

        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "plain")]), for: feature.id)
        guard case .notConfigured(.noUsableModel) = await collect(service.stream(textRequest(feature))).error else {
            Issue.record("Expected noUsableModel")
            return
        }
    }

    @Test func removingAProviderClearsItsRoutesAndKey() async throws {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: [:])
        try await service.settings.setKey("secret", for: first.id)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: userFeature.id)
        try await service.settings.removeProvider(first.id)
        #expect(service.settings.route(for: userFeature.id).models.isEmpty)
        #expect(try await service.settings.keys.key(for: first.id) == nil)
    }

    /// A key the Keychain keeps leaves its provider and routes in place, so that the provider can be removed again.
    @Test func aKeyThatStaysKeepsItsProvider() async throws {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let keys = InMemoryKeys()
        let settings = AISettingsStore(fileURL: temporaryDirectory().appendingPathComponent("ai.json"), keys: keys)
        settings.providers = [first]
        try await settings.setKey("secret", for: first.id)
        settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: userFeature.id)
        keys.removalError = AIKeychainError(status: errSecUserCanceled)
        await #expect(throws: AIKeychainError.self) { try await settings.removeProvider(first.id) }
        #expect(settings.providers.map(\.id) == [first.id])
        #expect(settings.route(for: userFeature.id).models.count == 1)
        #expect(try await keys.key(for: first.id) == "secret")
    }

    /// Refresh in Settings sends the saved key only to the base URL it was saved for: at an edited base URL that is not saved yet, the key has to be entered again.
    @Test func listingModelsAtAnUnsavedBaseURLNeedsTheKeyAgain() async throws {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: [:])
        try await service.settings.setKey("secret", for: first.id)
        var edited = try #require(service.settings.providers.first)
        #expect(try await service.listModels(of: edited) == ["model-a"])
        if case .http(var http) = edited.kind {
            http.baseURL = URL(string: "https://other.example.test/v1")!
            edited.kind = .http(http)
        }
        await #expect(throws: AIError.self) { try await service.listModels(of: edited) }
        #expect(try await service.listModels(of: edited, key: "typed key") == ["model-a"])
    }
}

@MainActor
@Suite struct FallbackTests {
    private func routed(_ script: [String: [Step]], log: ProviderLog = ProviderLog()) -> AIService {
        let first = provider("First", models: [AIModelConfiguration(name: "primary"), AIModelConfiguration(name: "fallback")])
        let service = scriptedService(providers: [first], script: script, log: log)
        service.register(userFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "primary"), AIModelRef(provider: first.id, model: "fallback")]), for: userFeature.id)
        return service
    }

    @Test func movesToTheFallbackBeforeTheFirstText() async {
        let service = routed([
            "primary": [.fail(.providerUnavailable(AIProviderID(), detail: "down"))],
            "fallback": [.event(.text("from fallback")), .event(.finished(.completed))],
        ])
        let result = await collect(service.stream(textRequest(userFeature)))
        #expect(result.error == nil)
        #expect(result.events == ["started:fallback", "text:from fallback", "finished:completed"])
        #expect(service.activity.last?.model?.model == "fallback")
    }

    @Test func keepsTheModelAfterTheFirstText() async {
        let log = ProviderLog()
        let service = routed([
            "primary": [.event(.text("partial")), .fail(.providerUnavailable(AIProviderID(), detail: "down"))],
            "fallback": [.event(.text("never")), .event(.finished(.completed))],
        ], log: log)
        let result = await collect(service.stream(textRequest(userFeature)))
        #expect(result.events == ["started:primary", "text:partial"])
        guard case .providerUnavailable = result.error else {
            Issue.record("Expected providerUnavailable")
            return
        }
        #expect(log.requests.map(\.model) == ["primary"])
    }

    @Test func invalidRequestsEndAtOnce() async {
        let log = ProviderLog()
        let service = routed(["primary": [.fail(.invalidRequest("bad"))]], log: log)
        guard case .invalidRequest = await collect(service.stream(textRequest(userFeature))).error else {
            Issue.record("Expected invalidRequest")
            return
        }
        #expect(log.requests.map(\.model) == ["primary"])
    }

    /// The cool-down belongs to the provider, so the fallback is on another one.
    @Test func aLongCoolDownMovesToTheFallback() async {
        let limited = provider("Limited", models: [AIModelConfiguration(name: "primary")])
        let other = provider("Other", models: [AIModelConfiguration(name: "fallback")])
        let service = scriptedService(providers: [limited, other], script: [
            "primary": [.fail(.rateLimited(AIProviderID(), until: Date() + 60))],
            "fallback": [.event(.text("ok")), .event(.finished(.completed))],
        ])
        service.register(userFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: limited.id, model: "primary"), AIModelRef(provider: other.id, model: "fallback")]), for: userFeature.id)
        #expect(await collect(service.stream(textRequest(userFeature))).events == ["started:fallback", "text:ok", "finished:completed"])
    }

    @Test func anUnspecifiedProviderResetAppliesBackoffWithoutAdvertisingIt() async {
        let limited = provider("Limited", models: [AIModelConfiguration(name: "primary")])
        let log = ProviderLog()
        let service = scriptedService(providers: [limited], script: ["primary": [.fail(.rateLimited(limited.id, until: nil))]], log: log)
        service.register(automaticFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: limited.id, model: "primary")]), for: automaticFeature.id)
        let result = await collect(service.stream(textRequest(automaticFeature)))
        guard case .rateLimited(let id, nil) = result.error else {
            Issue.record("Expected the provider's rate limit without a reset date")
            return
        }
        #expect(id == limited.id)
        #expect(log.requests.count == 1)
        #expect(await service.limiter(for: id).coolDownUntil ?? .distantPast > Date())
    }

    @Test func aShortCoolDownRetriesTheSameModel() async {
        let log = ProviderLog()
        let first = provider("First", models: [AIModelConfiguration(name: "primary")])
        let service = scriptedService(providers: [first], script: ["primary": [.fail(.rateLimited(AIProviderID(), until: Date() + 0.2))]], log: log)
        service.register(userFeature)
        let result = await collect(service.stream(textRequest(userFeature)))
        // The first attempt and two retries, which wait in the limiter while the cool-down lasts.
        #expect(log.requests.count == 3)
        #expect(result.events.allSatisfy { $0 == "waiting:rateLimited" })
        guard case .rateLimited = result.error else {
            Issue.record("Expected rateLimited")
            return
        }
    }

    @Test func authenticationFailureOverHTTPMovesToTheFallback() async throws {
        let failing = StubURLProtocol.host(replying: .init(status: 401, headers: [:], chunks: []))
        let working = StubURLProtocol.host(replying: .init(chunks: sse([
            #"data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ])))
        let directory = temporaryDirectory()
        let keys = InMemoryKeys()
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
        let bad = provider("Bad", models: [AIModelConfiguration(name: "model-a")], baseURL: "https://\(failing)/v1")
        let good = provider("Good", models: [AIModelConfiguration(name: "model-b")], baseURL: "https://\(working)/v1")
        settings.providers = [bad, good]
        try await settings.setKey("wrong-key", for: bad.id)
        try await settings.setKey("right-key", for: good.id)
        let session = StubURLProtocol.session()
        let service = AIService(settings: settings, usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")), keys: keys) { configuration, key in
            guard case .http(let http) = configuration.kind else { fatalError() }
            return HTTPProvider(configuration: configuration, http: http, key: key, session: session)
        }
        service.register(userFeature)
        settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: bad.id, model: "model-a"), AIModelRef(provider: good.id, model: "model-b")]), for: userFeature.id)
        let result = await collect(service.stream(textRequest(userFeature)))
        #expect(result.events == ["started:model-b", "text:Hi", "finished:completed"])
        #expect(StubURLProtocol.requests(to: failing).first?.headers["Authorization"] == "Bearer wrong-key")
        #expect(StubURLProtocol.requests(to: working).first?.headers["Authorization"] == "Bearer right-key")
        let totals = service.usage.totals(monthsAgo: 0)
        #expect(totals.first(where: { $0.model == "model-a" })?.errors == 1)
        #expect(totals.first(where: { $0.model == "model-b" })?.requests == 1)
    }
}

@MainActor
@Suite struct PartCheckTests {
    private let page = AIPageContent(url: URL(string: "https://news.example.org/story?id=7#top")!, title: "Story", text: String(repeating: "word ", count: 100))

    private func service(limit: Int = 100_000, log: ProviderLog) -> AIService {
        let service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a", inputCharacterLimit: limit)])], script: [:], log: log)
        service.register(userFeature)
        return service
    }

    @Test func stripsQueryAndFragmentAndAddsTheNote() async throws {
        let log = ProviderLog()
        let service = service(log: log)
        _ = await collect(service.stream(AIRequest(feature: userFeature.id, instructions: "Summarize.", messages: [AIMessage(role: .user, parts: [.page(page)])])))
        let sent = try #require(log.requests.first)
        guard case .page(let sentPage) = sent.messages.first?.parts.first else {
            Issue.record("Expected a page part")
            return
        }
        #expect(sentPage.url.absoluteString == "https://news.example.org/story")
        #expect(sent.instructions == "\(AIPartText.untrustedContentNote)\n\nSummarize.")
    }

    /// An address a page or a download came from can carry a user name and password, which never reach the provider.
    @Test func stripsTheUserNameAndPassword() async throws {
        let log = ProviderLog()
        let service = service(log: log)
        let page = AIPageContent(url: URL(string: "https://admin:s3cret@nas.example.org/files?id=7")!, title: "Files", text: "Text")
        let selection = AISelection(pageURL: page.url, pageTitle: "Files", text: "x")
        _ = await collect(service.stream(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.page(page), .selection(selection)])])))
        let parts = try #require(log.requests.first?.messages.first?.parts)
        guard case .page(let sentPage) = parts.first, case .selection(let sentSelection) = parts.last else {
            Issue.record("Expected a page and a selection")
            return
        }
        #expect(sentPage.url.absoluteString == "https://nas.example.org/files")
        #expect(sentSelection.pageURL.absoluteString == "https://nas.example.org/files")
    }

    @Test func blocksUndeclaredKindsAndExcludedSites() async {
        let log = ProviderLog()
        let service = service(log: log)
        let download = AIDownloadInfo(filename: "a.zip")
        guard case .blockedByPolicy(.dataNotDeclared(.download)) = await collect(service.stream(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.download(download)])]))).error else {
            Issue.record("Expected dataNotDeclared")
            return
        }
        service.settings.excludedSites.append(AISitePattern("example.org"))
        guard case .blockedByPolicy(.siteExcluded("news.example.org")) = await collect(service.stream(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.page(page)])]))).error else {
            Issue.record("Expected siteExcluded")
            return
        }
        let internalPage = AIPageContent(url: URL(string: "flags://")!, title: "Flags", text: "")
        guard case .blockedByPolicy(.siteExcluded) = await collect(service.stream(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.selection(AISelection(pageURL: internalPage.url, pageTitle: "", text: "x"))])]))).error else {
            Issue.record("Expected an internal page to be excluded")
            return
        }
        #expect(log.requests.isEmpty)
    }

    @Test func cutsPageTextToTheScopeAndTheModelLimit() async throws {
        let log = ProviderLog()
        let service = service(limit: 120, log: log)
        var feature = userFeature
        feature.data.pageTextLimit = 300
        service.register(feature)
        _ = await collect(service.stream(AIRequest(feature: feature.id, messages: [AIMessage(role: .user, parts: [.text("Question?"), .page(page)])])))
        let parts = try #require(log.requests.first?.messages.first?.parts)
        guard case .page(let sentPage) = parts[1] else {
            Issue.record("Expected a page part")
            return
        }
        // 120 characters in all: 9 of text, 5 of title, and the rest page text.
        #expect(sentPage.text.count == 120 - 9 - 5)
        #expect(sentPage.isTruncated)
        #expect(AIPartPolicy.characterCount(of: log.requests[0].messages) == 120)
    }

    @Test func tooLongWithoutPageTextIsContextTooLong() async {
        let service = service(limit: 3, log: ProviderLog())
        guard case .contextTooLong = await collect(service.stream(textRequest(userFeature, "Too long"))).error else {
            Issue.record("Expected contextTooLong")
            return
        }
    }
}

/// The checks a request passes again once it has waited for its provider's slot and its key.
@MainActor
@Suite struct ChecksAfterWaitingTests {
    /// A provider with one slot, which a first text request holds for 300 milliseconds.
    private func service(price: AIPrice? = nil, log: ProviderLog) -> AIService {
        var first = provider("First", models: [AIModelConfiguration(name: "model-a", price: price)])
        first.limits = AIProviderLimits(concurrentRequests: 1)
        let service = scriptedService(providers: [first], script: ["model-a": [
            .sleep(.milliseconds(300)), .event(.text("x")), .event(.usage(AIUsage(inputTokens: 2, outputTokens: 1))), .event(.finished(.completed)),
        ]], log: log)
        service.register(userFeature)
        return service
    }

    /// Starts the request and waits until it reports that it waits for the slot.
    private func waitingRequest(_ request: AIRequest, on service: AIService) async throws -> Task<AIError?, Never> {
        let events = HookLog()
        let task = Task {
            do {
                for try await event in service.stream(request) { events.record(describe(event)) }
                return nil as AIError?
            } catch {
                return error as? AIError
            }
        }
        try #require(await eventually { events.entries.contains("waiting:queued") })
        return task
    }

    @Test func aRevokedToolResultIsRecheckedAfterWaitingForTheProvider() async throws {
        @MainActor final class Grant { var shared = true }
        let grant = Grant()
        let log = ProviderLog()
        let service = service(log: log)
        let first = Task { await collect(service.stream(textRequest(userFeature))) }
        try #require(await eventually { log.requests.count == 1 })
        let page = AIPageContent(url: URL(string: "https://example.org")!, title: "Private", text: "Private body")
        var retained = AIToolResult(callID: "read", parts: [.page(page)])
        retained.checkingAccess = { result in
            grant.shared ? result : AIToolResult(callID: result.callID, parts: [.text("Access withdrawn.")], isError: true)
        }
        let waiting = try await waitingRequest(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.toolResult(retained)])]), on: service)
        grant.shared = false
        #expect(await waiting.value == nil)
        #expect(await first.value.error == nil)
        let sent = try #require(log.requests.last?.messages.last)
        guard case .toolResult(let result) = sent.parts.first else { Issue.record("Expected the checked tool result"); return }
        #expect(result.callID == "read" && result.isError && !AIPartText.carriesData([sent]))
        #expect(service.activity.last?.content.contains("Private body") == false)
    }

    @Test func aSiteSwitchedOffDuringTheWaitKeepsItsPage() async throws {
        let log = ProviderLog()
        let service = service(log: log)
        let first = Task { await collect(service.stream(textRequest(userFeature))) }
        try #require(await eventually { log.requests.count == 1 })
        let page = AIPageContent(url: URL(string: "https://news.example.org/story")!, title: "Story", text: "Text")
        let waiting = try await waitingRequest(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.text("Summarize."), .page(page)])]), on: service)
        service.settings.setAllowsAI(false, on: page.url)
        guard case .blockedByPolicy(.siteExcluded("news.example.org")) = await waiting.value else {
            Issue.record("Expected siteExcluded")
            return
        }
        #expect(await first.value.error == nil)
        #expect(log.requests.count == 1)
        #expect(!AIPartText.carriesData(log.requests[0].messages))
        // The refused request reached no provider, so it counts toward no usage.
        #expect(service.usage.totals(monthsAgo: 0).first?.requests == 1)
    }

    @Test func theRequestAheadThatReachesTheSpendingLimitStopsTheWaitingOne() async throws {
        let log = ProviderLog()
        // Each request costs 3 USD, the whole limit.
        let service = service(price: AIPrice(currency: "USD", inputPerMillion: 1_000_000, outputPerMillion: 1_000_000), log: log)
        service.settings.limits.monthlySpendingLimit = AIMoney(currency: "USD", amount: 3)
        let first = Task { await collect(service.stream(textRequest(userFeature))) }
        try #require(await eventually { log.requests.count == 1 })
        let waiting = try await waitingRequest(textRequest(userFeature), on: service)
        guard case .budgetReached(.monthlySpending) = await waiting.value else {
            Issue.record("Expected the spending limit")
            return
        }
        #expect(await first.value.error == nil)
        #expect(log.requests.count == 1)
        #expect(service.usage.totals(monthsAgo: 0).first?.costs["USD"] == 3)
    }

    @Test func anApprovedDestinationThatChangesWhileQueuedIsRefusedWithoutAKey() async throws {
        let log = ProviderLog()
        let service = service(log: log)
        var provider = try #require(service.settings.providers.first)
        let running = Task { await collect(service.stream(textRequest(userFeature))) }
        try #require(await eventually { log.requests.count == 1 })
        var request = textRequest(userFeature)
        request.knownProviders = [provider.id: provider.hookDestination]
        let waiting = try await waitingRequest(request, on: service)
        if case .http(var http) = provider.kind {
            http.baseURL = URL(string: "https://changed.example/v1")!
            provider.kind = .http(http)
        }
        service.settings.save(provider)
        guard case .blockedByPolicy(.unknownProvider) = await waiting.value else {
            Issue.record("Expected a refusal for the changed destination")
            return
        }
        #expect(await running.value.error == nil && log.requests.count == 1)
    }

    /// A provider that the user moves to another base URL while a request waits has the new server's key under its ID by then. That key never goes to the old address: the waiting request ends without reaching a provider.
    @Test func aProviderMovedToAnotherBaseURLDuringTheWaitSendsNoKeyToTheOldOne() async throws {
        let log = ProviderLog()
        let service = service(log: log)
        var first = try #require(service.settings.providers.first)
        try await service.settings.setKey("old server's key", for: first.id)
        first = try #require(service.settings.providers.first)
        let running = Task { await collect(service.stream(textRequest(userFeature))) }
        try #require(await eventually { log.requests.count == 1 })
        let waiting = try await waitingRequest(textRequest(userFeature), on: service)
        if case .http(var http) = first.kind {
            http.baseURL = URL(string: "https://other.example.test/v1")!
            first.kind = .http(http)
        }
        service.settings.save(first)
        try await service.settings.setKey("new server's key", for: first.id)
        guard case .providerUnavailable(_, let detail) = await waiting.value else {
            Issue.record("Expected providerUnavailable")
            return
        }
        #expect(detail == catalogText("The provider's settings changed while the request waited."))
        #expect(await running.value.error == nil)
        #expect(log.requests.count == 1)
    }

    /// A key the Keychain does not give makes the provider unavailable with the Keychain's reason, and the request that never went out counts toward no usage.
    @Test func aKeyThatCannotBeReadMakesTheProviderUnavailable() async throws {
        let log = ProviderLog()
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: [:], log: log)
        service.register(userFeature)
        try await service.settings.setKey("secret", for: first.id)
        let keys = try #require(service.settings.keys as? InMemoryKeys)
        keys.readError = AIKeychainError(status: errSecUserCanceled)
        guard case .providerUnavailable(_, let detail) = await collect(service.stream(textRequest(userFeature))).error else {
            Issue.record("Expected providerUnavailable")
            return
        }
        #expect(detail.hasPrefix("The key could not be read from the Keychain."))
        #expect(log.requests.isEmpty)
        #expect(service.usage.totals(monthsAgo: 0).isEmpty)
    }
}

@MainActor
@Suite struct BudgetAndUsageTests {
    @Test func automaticFeaturesStopAtTheDailyLimit() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: [:])
        service.register(automaticFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: automaticFeature.id)
        service.settings.limits.automaticRequestsPerDay = 2
        #expect(await collect(service.stream(textRequest(automaticFeature))).error == nil)
        #expect(await collect(service.stream(textRequest(automaticFeature))).error == nil)
        guard case .budgetReached(.automaticRequestsPerDay) = await collect(service.stream(textRequest(automaticFeature))).error else {
            Issue.record("Expected the daily limit")
            return
        }
    }

    @Test func requestsStopAtTheMonthlySpendingLimit() async {
        let price = AIPrice(currency: "USD", inputPerMillion: 1_000_000, outputPerMillion: 1_000_000)
        let first = provider("First", models: [AIModelConfiguration(name: "model-a", price: price)])
        let service = scriptedService(providers: [first], script: ["model-a": [.event(.text("x")), .event(.usage(AIUsage(inputTokens: 2, outputTokens: 1))), .event(.finished(.completed))]])
        service.register(userFeature)
        service.settings.limits.monthlySpendingLimit = AIMoney(currency: "USD", amount: 3)
        #expect(await collect(service.stream(textRequest(userFeature))).error == nil)
        #expect(service.usage.totals(monthsAgo: 0).first?.costs["USD"] == 3)
        guard case .budgetReached(.monthlySpending) = await collect(service.stream(textRequest(userFeature))).error else {
            Issue.record("Expected the spending limit")
            return
        }
    }

    /// A price whose currency was typed in lowercase counts toward a limit in the same currency.
    @Test func aPriceInLowercaseCountsTowardTheLimit() async {
        let price = AIPrice(currency: " usd", inputPerMillion: 1_000_000, outputPerMillion: 1_000_000)
        let first = provider("First", models: [AIModelConfiguration(name: "model-a", price: price)])
        let service = scriptedService(providers: [first], script: ["model-a": [.event(.text("x")), .event(.usage(AIUsage(inputTokens: 2, outputTokens: 1))), .event(.finished(.completed))]])
        service.register(userFeature)
        service.settings.limits.monthlySpendingLimit = AIMoney(currency: "USD", amount: 3)
        #expect(await collect(service.stream(textRequest(userFeature))).error == nil)
        #expect(service.usage.estimatedCost(in: "usd") == 3)
        guard case .budgetReached(.monthlySpending) = await collect(service.stream(textRequest(userFeature))).error else {
            Issue.record("Expected the spending limit")
            return
        }
    }

    /// A clock or time zone that goes back past the start of a month records into that month's entry again, and the spending limit counts all of the current month.
    @Test func aClockThatGoesBackFindsItsMonthAgain() {
        var now = Self.date(month: 11, day: 15)
        let store = AIUsageStore(fileURL: temporaryDirectory().appendingPathComponent("ai-usage.json")) { now }
        let model = AIModelConfiguration(name: "model-a", price: AIPrice(currency: "USD", inputPerMillion: 1_000_000, outputPerMillion: 0))
        let first = provider("First", models: [model])
        for day in [(11, 15), (10, 31), (11, 16)] {
            now = Self.date(month: day.0, day: day.1)
            store.record(feature: userFeature, provider: first, model: model, usage: AIUsage(inputTokens: 1, outputTokens: 0), isError: false)
        }
        #expect(store.months.map(\.month) == ["2026-10", "2026-11"])
        #expect(store.totals(monthsAgo: 0).first?.requests == 2)
        #expect(store.estimatedCost(in: "USD") == 2)
    }

    /// A file from an earlier version that lists a month twice reads as one entry per month, whose totals and cost count both entries.
    @Test func aFileThatListsAMonthTwiceAddsItsEntriesTogether() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai-usage.json")
        func month(_ key: String, requests: Int, cost: Int) -> String {
            #"{"month": "\#(key)", "totals": [{"feature": "user", "featureName": "User", "provider": "p", "providerName": "P", "model": "model-a", "requests": \#(requests), "errors": 0, "usage": {"inputTokens": \#(requests), "outputTokens": 0, "cachedInputTokens": 0}, "costs": {"USD": \#(cost)}}]}"#
        }
        let months = [month("2026-10", requests: 1, cost: 1), month("2026-11", requests: 2, cost: 2), month("2026-10", requests: 4, cost: 4), month("2026-11", requests: 8, cost: 8)]
        try Data(#"{"version": 1, "months": [\#(months.joined(separator: ", "))], "day": "", "automaticRequests": {}}"#.utf8).write(to: file)
        let store = AIUsageStore(fileURL: file) { Self.date(month: 11, day: 15) }
        #expect(store.months.map(\.month) == ["2026-10", "2026-11"])
        #expect(store.totals(monthsAgo: 0).map(\.requests) == [10])
        #expect(store.totals(monthsAgo: 0).first?.usage == AIUsage(inputTokens: 10, outputTokens: 0))
        #expect(store.totals(monthsAgo: 1).map(\.requests) == [5])
        #expect(store.estimatedCost(in: "USD") == 10)
    }

    @Test func dailyAgentRunsSurviveRestartAndCountOnceAcrossModelRounds() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai-usage.json")
        var now = Self.date(month: 11, day: 15)
        // A usage file from before agent runs already contains ordinary request counts.
        try Data(#"{"months":[],"day":"2026-11-15","version":1,"automaticRequests":{"first":2}}"#.utf8).write(to: file)
        let first = AIFeatureID(rawValue: "first")
        let other = AIFeatureID(rawValue: "other")
        var store = AIUsageStore(fileURL: file) { now }
        #expect(store.reserveAgentRun(for: first, dailyLimit: 1))
        store.countAutomaticRequest(for: first)
        #expect(store.automaticRequestCount(for: first) == 3)
        store.saveNow()
        store = AIUsageStore(fileURL: file) { now }
        #expect(!store.reserveAgentRun(for: first, dailyLimit: 1))
        #expect(store.reserveAgentRun(for: other, dailyLimit: 1))
        now = Self.date(month: 11, day: 16)
        #expect(store.reserveAgentRun(for: first, dailyLimit: 1))
        #expect(store.automaticRequestCount(for: first) == 0)
        #expect(store.reserveAgentRun(for: other, dailyLimit: 1))
    }

    private static func date(month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    @Test func usageTotalsCountRequestsErrorsAndTokens() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: ["model-a": [.event(.text("x")), .event(.usage(AIUsage(inputTokens: 5, outputTokens: 3, cachedInputTokens: 2))), .event(.finished(.completed))]])
        service.register(userFeature)
        _ = await collect(service.stream(textRequest(userFeature)))
        _ = await collect(service.stream(textRequest(userFeature)))
        let total = service.usage.totals(monthsAgo: 0).first
        #expect(total?.requests == 2)
        #expect(total?.errors == 0)
        #expect(total?.usage == AIUsage(inputTokens: 10, outputTokens: 6, cachedInputTokens: 4))
        #expect(total?.featureName == "User Test")
        service.usage.saveNow()
        let data = (try? Data(contentsOf: service.usage.fileURL)) ?? Data()
        #expect(!String(decoding: data, as: UTF8.self).contains("Hello"))
    }
}

@MainActor
@Suite struct CancellationTests {
    @Test func cancellingTheReaderEndsTheProviderStream() async throws {
        let log = ProviderLog()
        let service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: ["model-a": [.event(.text("first")), .sleep(.seconds(30)), .event(.finished(.completed))]], log: log)
        service.register(userFeature)
        let reader = Task { await collect(service.stream(textRequest(userFeature))) }
        try #require(await eventually { !log.requests.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel()
        _ = await reader.value
        for _ in 0..<100 where log.terminations == 0 || service.activity.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.terminations == 1)
        guard case .cancelled = service.activity.last?.result else {
            Issue.record("Expected a cancelled activity entry, got \(String(describing: service.activity.last?.result))")
            return
        }
    }
}

@MainActor
@Suite struct ToolRoundTests {
    @Test func runPerformsCallsAndSendsResultsBack() async throws {
        let call = AIToolCall(id: "call_1", name: "weather", arguments: Data(#"{"city":"Seoul"}"#.utf8))
        let unknown = AIToolCall(id: "call_2", name: "missing", arguments: Data("{}".utf8))
        let log = ProviderLog()
        // The script depends on the round: the first request has no tool results yet.
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let directory = temporaryDirectory()
        let keys = InMemoryKeys()
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
        settings.providers = [first]
        let service = AIService(settings: settings, usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")), keys: keys) { configuration, _ in
            let round = log.requests.count
            let steps: [Step] = round == 0
                ? [.event(.toolCall(call)), .event(.toolCall(unknown)), .event(.finished(.toolUse))]
                : [.event(.text("Sunny")), .event(.finished(.completed))]
            return ScriptedProvider(configuration: configuration, script: ["model-a": steps], log: log)
        }
        service.register(userFeature)
        let handler = AIToolHandler(tool: AITool(name: "weather", description: "", inputSchema: Data("{}".utf8))) { call in
            AIToolResult(callID: call.id, parts: [.text("Sunny in Seoul")])
        }
        let result = await collect(service.run(textRequest(userFeature), tools: [handler]))
        #expect(result.error == nil)
        #expect(result.events.last == "finished:completed")
        #expect(result.events.contains("text:Sunny"))
        let second = try #require(log.requests.last)
        #expect(second.tools.map(\.name) == ["weather"])
        guard case .toolResult(let known) = second.messages.last?.parts.first, case .toolResult(let missing) = second.messages.last?.parts.last else {
            Issue.record("Expected tool results")
            return
        }
        #expect(!known.isError)
        #expect(missing.isError)
    }

    @Test func runStopsAtTheRoundLimit() async {
        let call = AIToolCall(id: "call_1", name: "weather", arguments: Data("{}".utf8))
        let service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: ["model-a": [.event(.toolCall(call)), .event(.finished(.toolUse))]])
        service.register(userFeature)
        let handler = AIToolHandler(tool: AITool(name: "weather", description: "", inputSchema: Data("{}".utf8))) { AIToolResult(callID: $0.id, parts: [.text("x")]) }
        guard case .toolRoundLimit = await collect(service.run(textRequest(userFeature), tools: [handler], maxRounds: 2)).error else {
            Issue.record("Expected toolRoundLimit")
            return
        }
    }

    @Test func replyRejectsJSONThatDoesNotParse() async {
        let service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: ["model-a": [.event(.text("{not json")), .event(.finished(.completed))]])
        service.register(userFeature)
        do {
            _ = try await service.reply(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.text("x")])], output: .json(schema: Data("{}".utf8))))
            Issue.record("Expected malformedReply")
        } catch AIError.malformedReply {
        } catch {
            Issue.record("Expected malformedReply, got \(error)")
        }
    }

    @Test func replyReportsJSONCutAtTheLengthLimit() async {
        let service = scriptedService(providers: [provider("First", models: [AIModelConfiguration(name: "model-a")])], script: ["model-a": [.event(.text(#"{"a": "#)), .event(.finished(.lengthLimit))]])
        service.register(userFeature)
        do {
            _ = try await service.reply(AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.text("x")])], output: .json(schema: Data("{}".utf8))))
            Issue.record("Expected replyTooLong")
        } catch AIError.replyTooLong {
        } catch {
            Issue.record("Expected replyTooLong, got \(error)")
        }
    }
}
