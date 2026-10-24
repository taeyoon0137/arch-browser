// The service: route resolution, the default route for user features only, fallbacks before and not after the first text, capability filtering, part checks and truncation, budgets, usage, cancellation, and tool rounds.
import Foundation
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

    @Test func removingAProviderClearsItsRoutesAndKey() throws {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: [:])
        try service.settings.setKey("secret", for: first.id)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: userFeature.id)
        try service.settings.removeProvider(first.id)
        #expect(service.settings.route(for: userFeature.id).models.isEmpty)
        #expect(try service.settings.keys.key(for: first.id) == nil)
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
        try settings.setKey("wrong-key", for: bad.id)
        try settings.setKey("right-key", for: good.id)
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
        while log.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
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
}
