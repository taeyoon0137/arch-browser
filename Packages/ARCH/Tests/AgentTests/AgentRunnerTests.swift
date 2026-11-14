import AI
import Foundation
import Testing
@testable import Agent

@MainActor
@Suite struct AgentRunnerTests {
    let host = FakeHost()
    let hook = UUID()
    let tab = UUID()
    let page = URL(string: "https://example.org/path?private=yes#top")!
    let provider = AIProviderConfiguration(name: "Chosen", kind: .http(AIHTTPConfiguration(format: .messages, baseURL: URL(string: "https://provider.example/v1")!)))

    private func request() -> AgentRunRequest {
        host.tabs = [AgentTabInfo(id: tab, spaceID: nil, title: "Title", url: page, isLoading: false, engine: .webKit)]
        host.userTabIDs = [tab]
        return AgentRunRequest(options: AgentRunOptions(prompt: "Name it", model: .tier(.fast), tools: ["rename_tab"], limits: AgentRunLimits(rounds: 1), dryRun: true),
                               tabs: [tab], allowedTabs: [tab], documents: [tab: page], documentIDs: [tab: host.tabs[0].documentID], knownProviders: [provider.id: AgentRunRequest.destination(of: provider)],
                               origin: .hook(hook, run: UUID()), promptSource: .user, feature: .agentHook(hook), grant: AgentRunGrant(tools: ["rename_tab"]))
    }

    private func runner(_ client: ScriptedClient, reserve: @escaping () -> Bool = { true }) -> AgentRunner {
        AgentRunner(host: host, client: client, resolve: { feature, route in
            #expect(feature == .agentHook(hook) && route == .tier(.fast))
            return [AIModelRef(provider: provider.id, model: "selected")]
        }, provider: { $0 == provider.id ? provider : nil }, allowsAI: { $0.host != "private.example" }, reserve: { _, _ in reserve() })
    }

    @Test func aDryRunUsesTheSelectedModelAndReducedTitleOnceAndKeepsNothing() async throws {
        let req = request()
        let model = AIModelRef(provider: provider.id, model: "selected")
        let client = ScriptedClient { _ in
            [.event(.started(model)), .event(.toolCall(AIToolCall(id: "c1", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":" A Title "}"#.utf8)))),
             .event(.usage(AIUsage(inputTokens: 6, outputTokens: 3))), .event(.finished(.toolUse))]
        }
        let runner = runner(client)
        var renames = 0
        let result = await runner.run(req, personaID: FakeHost.defaultPersona.id) { id, name, doc, apply in
            #expect(id == tab && name == "A Title" && doc == page && !apply)
            renames += 1
            return true
        }
        #expect(renames == 1 && result.status == .completed && result.code == "roundLimit")
        #expect(result.actions == [.renamedTab(tab: tab, name: "A Title")] && result.model == model)
        #expect(result.usage == AIUsage(inputTokens: 6, outputTokens: 3) && result.keptRun == nil && runner.keptRuns.isEmpty)
        #expect(client.requests.count == 1)
        let sent = try #require(client.requests.first)
        #expect(sent.route == .models([model]) && !sent.recordsContent && sent.tools.map(\.name) == ["rename_tab"])
        let pageParts = sent.messages.flatMap(\.parts).compactMap { part -> AIPageContent? in
            if case .page(let p) = part { return p }
            return nil
        }
        #expect(pageParts.count == 1 && pageParts[0].url.absoluteString == "https://example.org/path" && pageParts[0].title == "Title" && pageParts[0].text.isEmpty)
    }

    @Test func refusedSourcesRoutesAndLimitsNeverReachAModel() async {
        let client = ScriptedClient { _ in [] }
        var reserves = 0
        let runner = runner(client) { reserves += 1; return false }
        func attempt(_ request: AgentRunRequest) async -> String? {
            await runner.run(request, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false }.code
        }
        var req = request()
        req.allowedTabs = []
        #expect(await attempt(req) == "notGranted")
        req = request()
        req.knownProviders = [:]
        #expect(await attempt(req) == "unknownProvider")
        req = request()
        req.promptSource = .program(name: "Program")
        #expect(await attempt(req) == "notGranted")
        req = request()
        let excluded = URL(string: "https://private.example/account")!
        host.tabs[0].url = excluded
        req.documents[tab] = excluded
        #expect(await attempt(req) == "P16")
        #expect(reserves == 0)
        #expect(await attempt(request()) == "dailyRuns")
        #expect(reserves == 1 && client.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func aMissingOrReplacedEventDocumentNeverReachesTheModel(missing: Bool) async {
        var req = request()
        if missing { req.documentIDs = [:] } else { host.tabs[0].documentID = UUID() }
        let client = ScriptedClient { _ in [] }
        let result = await runner(client).run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false }
        #expect(result.status == .refused && client.requests.isEmpty)
    }

    @Test func aModelCannotRenameAReloadAtTheSameAddress() async {
        let req = request()
        let client = ScriptedClient { _ in
            [.perform { await MainActor.run { host.tabs[0].documentID = UUID() } },
             .event(.toolCall(AIToolCall(id: "r", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":"Old title"}"#.utf8)))), .event(.finished(.toolUse))]
        }
        let result = await runner(client).run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in
            Issue.record("A rename reached the replacement document.")
            return false
        }
        #expect(result.actions.isEmpty && client.requests.count == 1)
    }

    private enum PageChange: CaseIterable, Sendable { case unchanged, differentAddress, reload }

    @Test(arguments: PageChange.allCases)
    private func pageAccessUsesTheGrantedDocumentAndRechecksItAfterExtraction(change: PageChange) async throws {
        var req = request()
        req.options.tabAccess = .page
        req.grant.tabAccess = .page
        req.options.tools = ["read_text"]
        req.grant.tools = ["read_text"]
        req.options.limits.rounds = 2
        host.pages[page] = ("Title", "permitted page text")
        switch change {
        case .unchanged: break
        case .differentAddress: host.beforeReturningContent = { host.tabs[0].url = URL(string: "https://private.example/") }
        case .reload: host.beforeReturningContent = { host.tabs[0].documentID = UUID() }
        }
        let client = ScriptedClient { n in
            n == 0 ? [.event(.toolCall(AIToolCall(id: "r", name: "read_text", arguments: Data(#"{"tab":"t1"}"#.utf8)))), .event(.finished(.toolUse))]
                : [.event(.text("Done")), .event(.finished(.completed))]
        }
        let runner = runner(client)
        let result = await runner.run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false }
        #expect(result.status == .completed && result.reply == "Done")
        let message = try #require(client.requests.last?.messages.last)
        guard case .toolResult(let tool)? = message.parts.first else { Issue.record("Expected a tool result"); return }
        let pageText = tool.parts.compactMap { part -> String? in
            if case .page(let page) = part { return page.text }
            return nil
        }
        let changed = change != .unchanged
        #expect(tool.isError == changed)
        #expect(pageText == (changed ? [] : ["permitted page text"]))
    }

    @Test func theToolBudgetStopsAtTheFirstAllowedCallWithoutAnotherRound() async {
        var req = request()
        req.options.limits = AgentRunLimits(rounds: 2, toolCalls: 1)
        let call = AIToolCall(id: "r", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":"Docs"}"#.utf8))
        let client = ScriptedClient { _ in [.event(.toolCall(call)), .event(.toolCall(call)), .event(.finished(.toolUse))] }
        let runner = runner(client)
        let result = await runner.run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in true }
        #expect(result.code == "toolCallLimit" && result.actions.count == 1 && client.requests.count == 1)
    }

    @Test func keepSessionStaysInMemoryAndReplyNeedsItsOwnGrant() async throws {
        var req = request()
        req.options.record = .session
        req.grant.returnsReply = false
        let client = ScriptedClient { _ in [.event(.text("private reply")), .event(.finished(.completed))] }
        let runner = runner(client)
        let result = await runner.run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false }
        let id = try #require(result.keptRun)
        #expect(result.reply == nil && runner.keptRuns.first?.id == id && client.requests.first?.recordsContent == true)
        runner.deleteKeptRun(id)
        #expect(runner.keptRuns.isEmpty)
    }

    @Test func stopAllCancelsBothRunsAndTheThirdIsRefusedAtCapacity() async throws {
        let req = request()
        let client = ScriptedClient { _ in [.hold] }
        let runner = runner(client)
        let first = Task { await runner.run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false } }
        let second = Task { await runner.run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false } }
        try await waitUntil { client.requests.count == 2 }
        let third = await runner.run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false }
        #expect(third.code == "busy")
        runner.cancelAll()
        #expect(await first.value.status == .cancelled)
        #expect(await second.value.status == .cancelled)
        try await waitUntil { client.terminations == 2 }
    }
}
