// Outside clients' agent runs and renames (`docs/hooks.md`, arch-cli agent run and rename; Tools): `AgentRunGrant.forClient(_:)` from the client's grant; a run on the client's agent tabs and the tabs shared with it under `agentRun`, renaming its own agent tab, refusing a shared tab's rename with `wouldAsk`, logging each tool call under the grant, and counting toward the grant's runs a day; `rename_tab` from the client under P19; and `agent/run`, which needs Start Agent Tasks and a tab.
import AgentControl
import AI
import ARCHEngine
import Foundation
import Testing
@testable import Agent

/// The suggested names the fake host gives, by tab.
@MainActor private var suggestedNames: [UUID: String?] = [:]

extension FakeHost: AgentTabNaming {
    func suggestName(_ name: String?, forTab id: UUID, showing document: URL, byGrant grant: UUID, applying: Bool) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), tab.url == document else { return false }
        if applying { suggestedNames[id] = name }
        return true
    }
}

@MainActor @Suite(.serialized) struct OutsideRunsTests {
    let provider = AIProviderConfiguration(name: "Chosen", kind: .http(AIHTTPConfiguration(format: .messages, baseURL: URL(string: "https://provider.example/v1")!)))

    @Test func aClientsRunGrantFollowsItsGrant() {
        var grant = AgentGrant(client: AgentClientIdentity(key: .unsigned(path: "/bin/agent", codeHash: "00"), name: "agent", executablePath: "/bin/agent", host: nil, isInterpreter: false),
                               personaID: UUID(), spaceID: UUID(), level: .readOnly, scopes: AgentGrantScopes(startTasks: true), expiry: .whenArchQuits, grantedAt: Date())
        grant.runsPerDay = 12
        let run = AgentRunGrant.forClient(grant)
        #expect(run.tools == ["read_text", "snapshot", "rename_tab"] && run.tabAccess == .page)
        #expect(run.minimumRecord == .activity && run.maximumRecord == .session && run.returnsReply && run.runsPerDay == 12)
        #expect(run.limits == AgentRunLimits(timeout: .seconds(600), rounds: 20, toolCalls: 50))
        let none = AgentRunOptions(prompt: "Name it", model: .tier(.standard), record: .none, tools: ["rename_tab"])
        #expect(run.refusal(for: none) != nil)
    }

    @Test func aRunRenamesTheClientsOwnTabAndNeverASharedOne() async throws {
        let host = FakeHost()
        let grant = UUID()
        let own = AgentTabInfo(id: UUID(), spaceID: nil, title: "Docs", url: URL(string: "https://docs.example/a")!, isLoading: false, engine: .webKit, agentOwnerID: grant)
        let shared = AgentTabInfo(id: UUID(), spaceID: nil, title: "Mail", url: URL(string: "https://mail.example/")!, isLoading: false, engine: .chromium)
        host.tabs = [own, shared]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OutsideRuns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let activity = AgentActivityLog(fileURL: folder.appendingPathComponent("agent-activity.json"), now: Date.init)
        var reserved: [(AIFeatureID, Int)] = []
        let client = ScriptedClient { index in
            index == 0 ? [.event(.toolCall(AIToolCall(id: "a", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":"Docs"}"#.utf8)))),
                          .event(.toolCall(AIToolCall(id: "b", name: "rename_tab", arguments: Data(#"{"tab":"t2","name":"Mail"}"#.utf8)))), .event(.finished(.toolUse))]
                : [.event(.text("Named one tab.")), .event(.finished(.completed))]
        }
        let runner = AgentRunner(host: host, client: client, activity: activity, resolve: { feature, _ in
            #expect(feature == .agentRun)
            return [AIModelRef(provider: provider.id, model: "selected")]
        }, provider: { $0 == provider.id ? provider : nil }, allowsAI: { _ in true }, reserve: { reserved.append(($0, $1)); return true })
        let identity = AgentClientIdentity(key: .unsigned(path: "/bin/agent", codeHash: "00"), name: "agent", executablePath: "/bin/agent", host: nil, isInterpreter: false)
        var grantValue = AgentGrant(id: grant, client: identity, personaID: FakeHost.defaultPersona.id, spaceID: UUID(), level: .readOnly, scopes: AgentGrantScopes(startTasks: true),
                                    expiry: .whenArchQuits, grantedAt: Date())
        grantValue.runsPerDay = 7
        var request = AgentRunRequest(options: AgentRunOptions(prompt: "Name the tabs", model: .tier(.standard), record: .activity, tools: ["rename_tab"]),
                                      tabs: [own.id, shared.id], allowedTabs: [own.id, shared.id], documents: [own.id: own.url!, shared.id: shared.url!],
                                      documentIDs: [own.id: own.documentID, shared.id: shared.documentID], knownProviders: nil, origin: .outsideClient(grant: grant),
                                      promptSource: .program(name: "agent"), feature: .agentRun, grant: .forClient(grantValue))
        request.sharedTabs = [shared.id]
        var renamed: [UUID] = []
        let result = await runner.run(request, personaID: FakeHost.defaultPersona.id) { id, _, _, _ in
            renamed.append(id)
            return true
        }
        #expect(result.status == .completed && result.reply == "Named one tab.")
        #expect(renamed == [own.id])
        #expect(result.actions == [.renamedTab(tab: own.id, name: "Docs")])
        guard case .toolResult(let refusal)? = client.requests.last?.messages.last?.parts.last else { Issue.record("The model received no second result."); return }
        #expect(refusal.isError)
        #expect(reserved.count == 1 && reserved.first?.0 == .agentRun(grant: grant) && reserved.first?.1 == 7)
        let entries = activity.entries.filter { $0.grantID == grant && $0.event == .toolCall }
        #expect(entries.map(\.tool) == ["rename_tab", "rename_tab"])
        #expect(entries.map(\.decision) == [.auto, .refused])
        // A hook's feature, or a tab outside the client's, is refused before any model.
        var wrong = request
        wrong.feature = .agentHook(UUID())
        #expect(await runner.run(wrong, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in true }.code == "notGranted")
        wrong = request
        wrong.tabs = [UUID()]
        #expect(await runner.run(wrong, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in true }.code == "notGranted")
        #expect(client.requests.count == 2)
    }

    private func connected(_ harness: Harness, scopes: AgentGrantScopes = AgentGrantScopes()) async throws -> (AgentService, TestClient) {
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.defaultPersona.id), level: .actInAgentTabs, scopes: scopes)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        return (service, client)
    }

    @Test func renameTabNamesTheClientsOwnTabUnderP19() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, client) = try await connected(harness)
        harness.host.pages[URL(string: "https://docs.example/start")!] = (title: "Docs", text: "Docs")
        let opened = try await client.callTool("open_tab", ["url": "https://docs.example/start"])
        #expect(opened.status == .ok)
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let named = try await client.callTool("rename_tab", ["tab": .string(handle), "name": "  Docs home\nsecond line"])
        #expect(named.status == .ok && named.structured?["name"] == "Docs home")
        let tab = try #require(harness.host.tabs.first { $0.agentOwnerID == service.grants.first?.id })
        #expect(suggestedNames[tab.id] == .some("Docs home"))
        #expect(try await client.callTool("rename_tab", ["tab": "t99", "name": "x"]).code == "tabNotFound")
        #expect(service.activity.entries.contains { $0.tool == "rename_tab" && $0.outcome == "ok" })
    }

    @Test func agentRunNeedsStartAgentTasksAndATab() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (_, client) = try await connected(harness)
        await #expect(throws: AgentClientError.self) {
            _ = try await client.call(AgentControlMethod.agentRun, params: ["prompt": "Name it"])
        }
        let scoped = try Harness()
        defer { scoped.cleanUp() }
        let (service, starter) = try await connected(scoped, scopes: AgentGrantScopes(startTasks: true))
        let result = try await starter.call(AgentControlMethod.agentRun, params: ["prompt": "Name it"])
        #expect(result["status"] == "refused" && result["code"] == "noTab")
        #expect(service.activity.entries.contains { $0.event == .agentRun && $0.rule == "noTab" })
        let other = try await starter.call(AgentControlMethod.agentRun, params: ["prompt": "Name it", "tabs": ["t5"]])
        #expect(other["code"] == "tabNotFound")
    }
}
