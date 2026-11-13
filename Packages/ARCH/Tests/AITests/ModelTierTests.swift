// Model tiers and request routes (`docs/hooks.md`, Model choice and tiers): tiers resolved with fallbacks, an empty tier's error, request routes accepted for `perRequest` and user features and refused for stored automatic ones, capability drops after a tier, budgets for `perRequest` automatic features, Activity without content, and the tier routes in `ai.json`.
import Foundation
import Testing
@testable import AI

/// An agent hook's feature: automatic, and each request names its route.
private let perRequestFeature = AIFeature(id: AIFeatureID(rawValue: "agentHook.test"), name: "Hook Test", summary: "", trigger: .automatic,
                                          data: .textOnly, routing: .perRequest)

private func request(_ feature: AIFeature, route: AIRouteChoice?, recordsContent: Bool = true) -> AIRequest {
    AIRequest(feature: feature.id, messages: [AIMessage(role: .user, parts: [.text("Hello")])], route: route, recordsContent: recordsContent)
}

private func answering(_ text: String) -> [Step] {
    [.event(.text(text)), .event(.finished(.completed))]
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ModelTierTests {
    @Test func aTierResolvesToItsModelsWithFallbacks() async throws {
        let first = provider("First", models: [AIModelConfiguration(name: "primary"), AIModelConfiguration(name: "fallback")])
        let service = scriptedService(providers: [first], script: [
            "primary": [.fail(.providerUnavailable(first.id, detail: "down"))],
            "fallback": answering("from fallback"),
        ])
        service.register(perRequestFeature)
        let models = [AIModelRef(provider: first.id, model: "primary"), AIModelRef(provider: first.id, model: "fallback")]
        service.settings.setRoute(AIRoute(isEnabled: true, models: models), for: .tier(.fast))
        #expect(try service.resolvedModels(for: perRequestFeature.id, route: .tier(.fast)) == models)
        #expect(await collect(service.stream(request(perRequestFeature, route: .tier(.fast)))).events == ["started:fallback", "text:from fallback", "finished:completed"])
    }

    /// The user chose the tier for its cost, so an empty one uses neither another tier nor the default route.
    @Test func anEmptyTierFailsWithoutFallingBack() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let log = ProviderLog()
        let service = scriptedService(providers: [first], script: [:], log: log)
        service.register(perRequestFeature)
        service.register(userFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: .tier(.standard))
        #expect(!service.settings.route(for: .defaultRoute).models.isEmpty)
        for feature in [perRequestFeature, userFeature] {
            let error = await collect(service.stream(request(feature, route: .tier(.fast)))).error
            guard case .notConfigured(.emptyTier(.fast)) = error else {
                Issue.record("Expected the empty Fast tier, got \(String(describing: error))")
                continue
            }
            #expect(error?.localizedDescription == "Assign a model to the Fast tier in Settings \u{25B8} AI.")
        }
        #expect(log.requests.isEmpty)
        #expect(!service.isAvailable(perRequestFeature.id, route: .tier(.fast)))
        #expect(service.isAvailable(perRequestFeature.id, route: .tier(.standard)))
    }

    /// A tier has no switch: its route is written on, and one written off by hand still serves.
    @Test func aTiersSwitchIsWrittenOnAndNotRead() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: ["model-a": answering("ok")])
        service.register(perRequestFeature)
        let ref = AIModelRef(provider: first.id, model: "model-a")
        service.settings.setRoute(AIRoute(isEnabled: false, models: [ref]), for: .tier(.deep))
        #expect(service.settings.route(for: .tier(.deep)) == AIRoute(isEnabled: true, models: [ref]))
        service.settings.routes[AIFeatureID.tier(.deep).rawValue] = AIRoute(isEnabled: false, models: [ref])
        #expect(await collect(service.stream(request(perRequestFeature, route: .tier(.deep)))).events == ["started:model-a", "text:ok", "finished:completed"])
    }

    /// A tier lists any connected model; the feature's requirements drop the ones that cannot serve it when a request resolves the tier.
    @Test func capabilitiesDropModelsAfterATier() async throws {
        let plain = AIModelConfiguration(name: "plain", capabilities: [])
        let capable = AIModelConfiguration(name: "capable")
        let first = provider("First", models: [plain, capable])
        let service = scriptedService(providers: [first], script: ["capable": answering("ok")])
        var feature = perRequestFeature
        feature.requirements = [.tools]
        service.register(feature)
        let refs = [AIModelRef(provider: first.id, model: "plain"), AIModelRef(provider: first.id, model: "capable")]
        service.settings.setRoute(AIRoute(isEnabled: true, models: refs), for: .tier(.fast))
        #expect(try service.resolvedModels(for: feature.id, route: .tier(.fast)) == [refs[1]])
        #expect(await collect(service.stream(request(feature, route: .tier(.fast)))).events == ["started:capable", "text:ok", "finished:completed"])

        service.settings.setRoute(AIRoute(isEnabled: true, models: [refs[0]]), for: .tier(.fast))
        guard case .notConfigured(.noUsableModel) = await collect(service.stream(request(feature, route: .tier(.fast)))).error else {
            Issue.record("Expected noUsableModel")
            return
        }
    }

    /// Removing a provider takes its models out of the tiers too.
    @Test func removingAProviderClearsItsModelsFromTheTiers() async throws {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: [:])
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: .tier(.fast))
        try await service.settings.removeProvider(first.id)
        #expect(service.settings.route(for: .tier(.fast)).models.isEmpty)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct RequestRouteTests {
    @Test func aPerRequestFeatureNeedsARoute() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: ["model-a": answering("ok")])
        service.register(perRequestFeature)
        for route in [nil, AIRouteChoice.models([])] {
            guard case .notConfigured(.noModel) = await collect(service.stream(request(perRequestFeature, route: route))).error else {
                Issue.record("Expected noModel for \(String(describing: route))")
                continue
            }
        }
        #expect(!service.isAvailable(perRequestFeature.id))
        let route = AIRouteChoice.models([AIModelRef(provider: first.id, model: "model-a")])
        #expect(service.isAvailable(perRequestFeature.id, route: route))
        #expect(await collect(service.stream(request(perRequestFeature, route: route))).events == ["started:model-a", "text:ok", "finished:completed"])
    }

    /// A feature the user starts may name another route, as the agent composer's model menu does, and its switch still applies.
    @Test func aUserFeatureMayNameItsOwnRoute() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a"), AIModelConfiguration(name: "model-b")])
        let service = scriptedService(providers: [first], script: ["model-a": answering("a"), "model-b": answering("b")])
        service.register(userFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: userFeature.id)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-b")]), for: .tier(.deep))
        #expect(await collect(service.stream(request(userFeature, route: nil))).events == ["started:model-a", "text:a", "finished:completed"])
        #expect(await collect(service.stream(request(userFeature, route: .tier(.deep)))).events == ["started:model-b", "text:b", "finished:completed"])
        #expect(await collect(service.stream(request(userFeature, route: .models([AIModelRef(provider: first.id, model: "model-b")])))).events
            == ["started:model-b", "text:b", "finished:completed"])

        service.settings.setRoute(AIRoute(isEnabled: false, models: [AIModelRef(provider: first.id, model: "model-a")]), for: userFeature.id)
        guard case .notConfigured(.switchedOff) = await collect(service.stream(request(userFeature, route: .tier(.deep)))).error else {
            Issue.record("Expected switchedOff")
            return
        }
    }

    /// Tab Names keeps the models the user chose for it: a stored automatic feature refuses a request's route before any request goes out, and its switch does not change that.
    @Test func aStoredAutomaticFeatureRefusesARequestRoute() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let log = ProviderLog()
        let service = scriptedService(providers: [first], script: ["model-a": answering("ok")], log: log)
        service.register(automaticFeature)
        let ref = AIModelRef(provider: first.id, model: "model-a")
        service.settings.setRoute(AIRoute(isEnabled: true, models: [ref]), for: .tier(.fast))
        for isEnabled in [true, false] {
            service.settings.setRoute(AIRoute(isEnabled: isEnabled, models: [ref]), for: automaticFeature.id)
            for route in [AIRouteChoice.tier(.fast), .models([ref])] {
                guard case .invalidRequest = await collect(service.stream(request(automaticFeature, route: route))).error else {
                    Issue.record("Expected invalidRequest for \(route)")
                    continue
                }
            }
        }
        #expect(log.requests.isEmpty)
        #expect(!service.isAvailable(automaticFeature.id, route: .tier(.fast)))
        #expect(service.usage.automaticRequestCount(for: automaticFeature.id) == 0)
    }

    /// A route names a model and at most two fallbacks.
    @Test func aRouteKeepsThreeModels() throws {
        let first = provider("First", models: (1...4).map { AIModelConfiguration(name: "model-\($0)") })
        let service = scriptedService(providers: [first], script: [:])
        service.register(perRequestFeature)
        let refs = (1...4).map { AIModelRef(provider: first.id, model: "model-\($0)") }
        #expect(try service.resolvedModels(for: perRequestFeature.id, route: .models(refs)) == Array(refs.prefix(3)))
    }

    /// A session takes the request's route when it names no model, and only presets among its models serve it.
    @Test func anAgentSessionTakesTheRequestsRoute() async throws {
        let feature = AIFeature(id: .agent, name: "Agent", summary: "", trigger: .user, data: AIDataScope(kinds: [.page]), requirements: [.agent])
        // No message is sent, so the preset's executable never runs.
        let preset = AIAgentKind.claudeCode.preset(executable: URL(fileURLWithPath: "/usr/bin/false"))
        let http = provider("HTTP", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [preset, http], script: [:])
        service.register(feature)
        let server = AIAgentToolServer(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], environment: [:], tools: [])
        func start(_ route: AIRouteChoice) throws -> AIAgentSession {
            let folder = temporaryDirectory().appendingPathComponent("Arch-Agent-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            return try service.startAgentSession(AIAgentSessionRequest(route: route, instructions: "Harness", toolServer: server, folder: folder))
        }
        do {
            _ = try start(.tier(.fast))
            Issue.record("Expected the empty Fast tier")
        } catch AIError.notConfigured(.emptyTier(.fast)) {}
        do {
            _ = try start(.models([AIModelRef(provider: http.id, model: "model-a")]))
            Issue.record("Expected noUsableModel for an HTTP model")
        } catch AIError.notConfigured(.noUsableModel) {}
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: http.id, model: "model-a"), AIModelRef(provider: preset.id, model: "")]), for: .tier(.fast))
        let session = try start(.tier(.fast))
        #expect(FileManager.default.fileExists(atPath: session.folder.path))
        await session.end(keepingThread: true)
        #expect(!FileManager.default.fileExists(atPath: session.folder.path))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PerRequestBudgetTests {
    @Test func aPerRequestAutomaticFeatureCountsTowardTheDailyLimit() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: ["model-a": answering("ok")])
        service.register(perRequestFeature)
        service.settings.limits.automaticRequestsPerDay = 2
        let route = AIRouteChoice.models([AIModelRef(provider: first.id, model: "model-a")])
        #expect(await collect(service.stream(request(perRequestFeature, route: route))).error == nil)
        #expect(await collect(service.stream(request(perRequestFeature, route: route))).error == nil)
        guard case .budgetReached(.automaticRequestsPerDay) = await collect(service.stream(request(perRequestFeature, route: route))).error else {
            Issue.record("Expected the daily limit")
            return
        }
        #expect(service.usage.automaticRequestCount(for: perRequestFeature.id) == 2)
    }

    /// Usage records the feature's name, so Usage lists a feature that Features does not.
    @Test func aPerRequestFeatureStopsAtTheSpendingLimitAndIsListedByName() async {
        let price = AIPrice(currency: "USD", inputPerMillion: 1_000_000, outputPerMillion: 1_000_000)
        let first = provider("First", models: [AIModelConfiguration(name: "model-a", price: price)])
        let service = scriptedService(providers: [first], script: ["model-a": [.event(.text("x")), .event(.usage(AIUsage(inputTokens: 2, outputTokens: 1))), .event(.finished(.completed))]])
        service.register(perRequestFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "model-a")]), for: .tier(.fast))
        service.settings.limits.monthlySpendingLimit = AIMoney(currency: "USD", amount: 3)
        #expect(await collect(service.stream(request(perRequestFeature, route: .tier(.fast)))).error == nil)
        guard case .budgetReached(.monthlySpending) = await collect(service.stream(request(perRequestFeature, route: .tier(.fast)))).error else {
            Issue.record("Expected the spending limit")
            return
        }
        let total = service.usage.totals(monthsAgo: 0).first
        #expect(total?.feature == perRequestFeature.id.rawValue)
        #expect(total?.featureName == "Hook Test")
        #expect(total?.costs["USD"] == 3)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ActivityContentTests {
    @Test func aRequestThatRecordsNoContentLeavesActivityWithoutIt() async {
        let first = provider("First", models: [AIModelConfiguration(name: "model-a")])
        let service = scriptedService(providers: [first], script: ["model-a": [.event(.text("ok")), .event(.usage(AIUsage(inputTokens: 4, outputTokens: 1))), .event(.finished(.completed))]])
        service.register(perRequestFeature)
        let route = AIRouteChoice.models([AIModelRef(provider: first.id, model: "model-a")])
        #expect(await collect(service.stream(request(perRequestFeature, route: route, recordsContent: false))).error == nil)
        let entry = service.activity.last
        #expect(entry?.content == "")
        #expect(entry?.model?.model == "model-a")
        #expect(entry?.parts.map(\.kind) == ["text"])
        #expect(entry?.usage == AIUsage(inputTokens: 4, outputTokens: 1))
        #expect(service.usage.totals(monthsAgo: 0).first?.requests == 1)

        #expect(await collect(service.stream(request(perRequestFeature, route: route))).error == nil)
        #expect(service.activity.last?.content.contains("Hello") == true)
    }
}

@MainActor
@Suite struct TierFileTests {
    @Test func writesAndReadsTheTierRoutes() throws {
        let directory = temporaryDirectory()
        let keys = InMemoryKeys()
        let store = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
        let first = provider("Work API", models: [AIModelConfiguration(name: "model-a"), AIModelConfiguration(name: "model-b")])
        store.providers = [first]
        let fast = [AIModelRef(provider: first.id, model: "model-a"), AIModelRef(provider: first.id, model: "model-b")]
        store.setRoute(AIRoute(isEnabled: true, models: fast), for: .tier(.fast))
        store.setRoute(AIRoute(isEnabled: true, models: [fast[1]]), for: .tier(.deep))
        store.saveNow()

        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let routes = try #require(object["routes"] as? [String: Any])
        let route = try #require(routes["tier.fast"] as? [String: Any])
        #expect(route["isEnabled"] as? Bool == true)
        #expect((route["models"] as? [[String: String]])?.map { $0["model"] } == ["model-a", "model-b"])
        #expect(routes["tier.standard"] == nil)

        let reloaded = AISettingsStore(fileURL: store.fileURL, keys: keys)
        #expect(reloaded.route(for: .tier(.fast)).models == fast)
        #expect(reloaded.route(for: .tier(.standard)) == AIRoute(isEnabled: true))
        #expect(reloaded.route(for: .tier(.deep)).models == [fast[1]])
    }

    @Test func readsAHandWrittenTierRoute() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai.json")
        try Data("""
        {
          "providers": [ { "id": "6F1C", "name": "Work API", "kind": { "http": { "format": "chatCompletions", "baseURL": "https://api.example.com/v1" } },
                           "models": [ { "name": "model-a" } ] } ],
          "routes": { "tier.deep": { "isEnabled": false, "models": [ { "provider": "6F1C", "model": "model-a" } ] } }
        }
        """.utf8).write(to: file)
        let store = AISettingsStore(fileURL: file, keys: InMemoryKeys())
        #expect(!store.replacedUnreadableFile)
        #expect(store.route(for: .tier(.deep)).models == [AIModelRef(provider: AIProviderID(rawValue: "6F1C"), model: "model-a")])
        #expect(store.route(for: .tier(.fast)).models.isEmpty)
    }

    @Test func routeChoicesEncodeAsOneKey() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ref = AIModelRef(provider: AIProviderID(rawValue: "6F1C"), model: "model-a")
        #expect(String(decoding: try encoder.encode(AIRouteChoice.tier(.fast)), as: UTF8.self) == #"{"tier":"fast"}"#)
        #expect(String(decoding: try encoder.encode(AIRouteChoice.models([ref])), as: UTF8.self) == #"{"models":[{"model":"model-a","provider":"6F1C"}]}"#)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AIRouteChoice.self, from: Data(#"{"tier": "standard"}"#.utf8)) == .tier(.standard))
        #expect(try decoder.decode(AIRouteChoice.self, from: Data(#"{"models": [{"provider": "6F1C", "model": "model-a"}]}"#.utf8)) == .models([ref]))
        #expect(throws: DecodingError.self) { try decoder.decode(AIRouteChoice.self, from: Data(#"{"tier": "huge"}"#.utf8)) }
        #expect(throws: DecodingError.self) { try decoder.decode(AIRouteChoice.self, from: Data(#"{"model": "model-a"}"#.utf8)) }
        #expect(AIModelTier.allCases.map { AIFeatureID.tier($0).rawValue } == ["tier.fast", "tier.standard", "tier.deep"])
    }
}
