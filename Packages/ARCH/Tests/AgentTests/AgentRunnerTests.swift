import AgentControl
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
                               tabs: [tab], allowedTabs: [tab], documents: [tab: page], knownProviders: [provider.id: AgentRunRequest.destination(of: provider)],
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

    @Test func anEditorTestReportsUsageWithoutSpendingTheHooksAutomaticAllowance() async {
        var req = request()
        req.origin = .test(hook: hook)
        let usage = AIUsage(inputTokens: 3, outputTokens: 1)
        let client = ScriptedClient { _ in [.event(.usage(usage)), .event(.finished(.completed))] }
        let runner = runner(client) { Issue.record("A manual test reserved an automatic run."); return false }
        let result = await runner.run(req, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in false }
        #expect(result.status == .completed && result.usage == usage && client.requests.count == 1)
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
    func pageAccessUsesTheGrantedDocumentAndRechecksItAfterExtraction(changed: Bool) async throws {
        var req = request()
        req.options.tabAccess = .page
        req.grant.tabAccess = .page
        req.options.tools = ["read_text"]
        req.grant.tools = ["read_text"]
        req.options.limits.rounds = 2
        host.pages[page] = ("Title", "permitted page text")
        if changed { host.beforeReturningContent = { host.tabs[0].url = URL(string: "https://private.example/") } }
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

    @Test func aCLIRunUsesItsOwnBoundConnectionAndLeavesNoTask() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        try await harness.settled(service)
        let preset = AIAgentKind.codex.preset(executable: URL(fileURLWithPath: "/fixture/codex"))
        let model = AIModelRef(provider: preset.id, model: "chosen")
        var req = request()
        req.knownProviders = [preset.id: AgentRunRequest.destination(of: preset)]
        let client = ScriptedClient { _ in [] }
        let runner = AgentRunner(host: host, client: client, resolve: { _, _ in [model] }, provider: { _ in preset }, allowsAI: { _ in true }, reserve: { _, _ in true })
        runner.startCLI = { try service.startHookCLI($0, feature: $1, models: $2, turns: $3, instructions: $4) }
        runner.finishCLI = { service.finishHookCLI($0) }
        let task = Task { await runner.run(req, personaID: FakeHost.defaultPersona.id) { id, suggestion, _, applies in
            #expect(id == tab && suggestion == "Docs" && !applies)
            return true
        } }
        try await waitUntil { !harness.runners.isEmpty }
        let cli = try #require(harness.runners.first)
        #expect(cli.request.ephemeral && cli.request.maxTurns == 1 && cli.request.route == .models([model]))
        #expect(cli.request.toolServer.tools == ["rename_tab"] && cli.request.skills == nil)
        #expect(cli.sent.first?.contains("?private") == false && cli.sent.first?.contains("<untrusted") == true)
        let ticket = try #require(cli.request.toolServer.environment[AgentMCPServer.ticketVariable])
        let pid: pid_t = 4_242
        harness.addProcess(pid, parent: 1)
        cli.startProcess(pid)
        await #expect(throws: AgentClientError.self) { try await TestClient(harness.location).hello(ticket: ticket) }
        harness.addProcess(getpid(), parent: pid)
        let peer = try TestClient(harness.location)
        #expect(try await peer.hello(ticket: ticket).status == .bound)
        let list = try await peer.call(AgentControlMethod.toolsList)
        #expect(try list.decode(as: AgentToolList.self).tools == ["rename_tab"])
        let call = Task { try await peer.call(AgentControlMethod.toolsCall, params: ["name": "rename_tab", "arguments": ["tab": "t1", "name": "Docs"]]) }
        await Task.yield()
        cli.emit(.ready(model))
        #expect(try await call.value.decode(as: AgentToolResult.self).status == .ok)
        let refused = try await peer.call(AgentControlMethod.toolsCall, params: ["name": "open_tab", "arguments": [:]])
        #expect(try refused.decode(as: AgentToolResult.self).code == "notGranted")
        cli.emit(.text("Done"))
        cli.emit(.turnFinished(.completed))
        let result = await task.value
        #expect(result.status == .completed && result.reply == "Done" && result.actions == [.renamedTab(tab: tab, name: "Docs")])
        #expect(client.requests.isEmpty && runner.keptRuns.isEmpty && service.sessions.isEmpty)
        #expect(cli.endedKeepingThread == false && cli.processID == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.location.path))
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
