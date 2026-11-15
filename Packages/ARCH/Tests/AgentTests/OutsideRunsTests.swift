// Outside clients' agent runs and renames (`docs/hooks.md`, arch-cli agent run and rename; Tools): `AgentRunGrant.forClient(_:)` from the client's grant; a run on the client's agent tabs and the tabs shared with it under `agentRun`, renaming its own agent tab, refusing a shared tab's rename with `wouldAsk` until the user allowed the tab on P19's card, logging each tool call under the grant with its tab's site and the run's ID, a dry run's rename as previewed, and counting toward the grant's runs a day but not its 2,000 calls; `rename_tab` from the client under P19, refusing a tab that is no longer the client's, a site excluded from AI, and a tab loading another address, and asking once on P19's card, without Touch ID, before it renames a tab the user shared, a card that the tab's next document withdraws; and `agent/run`, which needs Start Agent Tasks and a tab, binds each tab's committed address, so that a tab loading another address joins no run, renames a shared tab the user allowed, and names renamed tabs by the client's handles.
import AgentControl
import AI
import ARCHEngine
import Foundation
import Testing
@testable import Agent

/// The suggested names the fake host gives, by tab.
@MainActor private var suggestedNames: [UUID: String?] = [:]
/// The committed address of a tab whose shown address still loads, by tab; any other tab has committed the address it shows.
@MainActor private var committedAddresses: [UUID: URL] = [:]

extension FakeHost: AgentTabNaming {
    func suggestName(_ name: String?, forTab id: UUID, showing document: URL, byGrant grant: UUID, applying: Bool) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), committedAddress(ofTab: id) == document else { return false }
        if applying { suggestedNames[id] = name }
        return true
    }

    func committedAddress(ofTab id: UUID) -> URL? {
        committedAddresses[id] ?? tabs.first { $0.id == id }?.url
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
            switch index {
            case 0: return [.event(.toolCall(AIToolCall(id: "a", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":"Docs"}"#.utf8)))),
                            .event(.toolCall(AIToolCall(id: "b", name: "rename_tab", arguments: Data(#"{"tab":"t2","name":"Mail"}"#.utf8)))), .event(.finished(.toolUse))]
            case 2: return [.event(.toolCall(AIToolCall(id: "c", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":"Docs"}"#.utf8)))), .event(.finished(.toolUse))]
            default: return [.event(.text("Named one tab.")), .event(.finished(.completed))]
            }
        }
        let runner = AgentRunner(host: host, client: client, activity: activity, resolve: { feature, _ in
            #expect(feature == .agentRun)
            return [AIModelRef(provider: provider.id, model: "selected")]
        }, provider: { $0 == provider.id ? provider : nil }, allowsAI: { _ in true }, reserve: { reserved.append(($0, $1)); return true })
        let identity = AgentClientIdentity(key: .unsigned(path: "/bin/agent", codeHash: "00"), name: "agent", executablePath: "/bin/agent", host: nil, isInterpreter: false)
        let runID = UUID()
        var grantValue = AgentGrant(id: grant, client: identity, personaID: FakeHost.defaultPersona.id, spaceID: UUID(), level: .readOnly, scopes: AgentGrantScopes(startTasks: true),
                                    expiry: .whenArchQuits, grantedAt: Date())
        grantValue.runsPerDay = 7
        var request = AgentRunRequest(options: AgentRunOptions(prompt: "Name the tabs", model: .tier(.standard), record: .activity, tools: ["rename_tab"]),
                                      tabs: [own.id, shared.id], allowedTabs: [own.id, shared.id], documents: [own.id: own.url!, shared.id: shared.url!],
                                      documentIDs: [own.id: own.documentID, shared.id: shared.documentID], knownProviders: nil, origin: .outsideClient(grant: grant, run: runID),
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
        #expect(entries.map(\.rule) == [nil, AgentPolicy.wouldAskCode])
        // Each call names its tab's site, as the client's own calls do, and the run, whose calls the client's 2,000 calls a day do not count.
        #expect(entries.map(\.site) == ["docs.example", "mail.example"])
        #expect(entries.allSatisfy { $0.runID == runID })
        #expect(activity.callsToday(of: grant, at: Date()) == 0)
        activity.record(AgentActivityEntry(date: Date(), event: .toolCall, grantID: grant, clientName: "agent", tool: "list_tabs"))
        #expect(activity.callsToday(of: grant, at: Date()) == 1)
        // A dry run's rename is logged as previewed.
        var dry = request
        dry.options.dryRun = true
        dry.tabs = [own.id]
        _ = await runner.run(dry, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in true }
        #expect(activity.entries.last?.outcome == "previewed")
        // A hook's feature, or a tab outside the client's, is refused before any model.
        let requests = client.requests.count
        var wrong = request
        wrong.feature = .agentHook(UUID())
        #expect(await runner.run(wrong, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in true }.code == "notGranted")
        wrong = request
        wrong.tabs = [UUID()]
        #expect(await runner.run(wrong, personaID: FakeHost.defaultPersona.id) { _, _, _, _ in true }.code == "notGranted")
        #expect(client.requests.count == requests)
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
        let index = try #require(harness.host.tabs.firstIndex { $0.id == tab.id })
        // While the tab loads another address, the name would be for the page it is leaving.
        harness.host.tabs[index].url = URL(string: "https://docs.example/next")
        committedAddresses[tab.id] = URL(string: "https://docs.example/start")
        #expect(try await client.callTool("rename_tab", ["tab": .string(handle), "name": "Next"]).code == "stale")
        committedAddresses[tab.id] = nil
        // A site excluded from AI refuses with P16.
        harness.host.tabs[index].url = URL(string: "https://excluded.example/inbox")
        #expect(try await client.callTool("rename_tab", ["tab": .string(handle), "name": "Inbox"]).code == AgentRule.p16.rawValue)
        // A tab the user took over is no longer the client's: P17.
        harness.host.tabs[index].url = URL(string: "https://docs.example/start")
        harness.host.tabs[index].agentOwnerID = nil
        #expect(try await client.callTool("rename_tab", ["tab": .string(handle), "name": "Docs"]).code == AgentRule.p17.rawValue)
    }

    /// Shares the user's tab with the client through `request_tab`, answering its card with Share, and returns the client's handle for it.
    private func share(_ tab: AgentTabInfo, _ service: AgentService, _ client: TestClient, _ harness: Harness) async throws -> String {
        harness.host.tabs.append(tab)
        harness.host.userTabIDs.insert(tab.id)
        let request = Task { try await client.callTool("request_tab", ["reason": "Name the inbox", "access": "read"]) }
        try await waitUntil { !service.approvals.pending.isEmpty }
        let card = try #require(service.approvals.pending.first)
        #expect(await service.approvals.answer(card.id, with: .tab(tab.id)))
        return try #require(try await request.value.structured?["tab"]?.stringValue)
    }

    /// The card a `rename_tab` call of the client opens.
    private func renameCard(_ handle: String, _ name: String, _ service: AgentService, _ client: TestClient) async throws -> (AgentApproval, Task<AgentToolResult, any Error>) {
        let call = Task { try await client.callTool("rename_tab", ["tab": .string(handle), "name": .string(name)]) }
        try await waitUntil { !service.approvals.pending.isEmpty }
        return (try #require(service.approvals.pending.first), call)
    }

    @Test func renameTabAsksOnceOnP19sCardBeforeRenamingATabTheUserShared() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, client) = try await connected(harness)
        _ = try await client.callTool("list_spaces")
        let grant = try #require(service.grants.first)
        let userTab = AgentTabInfo(id: UUID(), spaceID: grant.spaceID, title: "Inbox (3)", url: URL(string: "https://mail.example/inbox"), isLoading: false, engine: .webKit)
        let handle = try await share(userTab, service, client, harness)
        let prompts = harness.authenticator.count

        // The card is P19's own, not sensitive, with the tab's title and site, and the name as its exact text.
        var (card, call) = try await renameCard(handle, "Mail", service, client)
        #expect(card.kind == .renameSharedTab && card.rules == [.p19] && !card.isSensitive && !card.needsAuthentication(for: .allowOnTab))
        #expect(card.offers == [.allowOnTab, .deny, .denyAndStop, .reply("")] && AgentApprovalAnswer.allowOnTab.title(site: card.site) == "Allow for This Tab")
        #expect(card.action == "Rename your tab \u{201C}Inbox (3)\u{201D} on mail.example" && card.exactText == "Mail")
        #expect(card.tabID == userTab.id && card.tabHandle == handle && card.site == "mail.example")
        #expect(await service.approvals.answer(card.id, with: .deny))
        #expect(try await call.value.status == .denied)
        #expect(suggestedNames[userTab.id] == nil)

        // The tab's next document withdraws the card, and the name, which was for the page it left, is not given.
        (card, call) = try await renameCard(handle, "Mail", service, client)
        harness.host.userDocumentDidEnd?(userTab.id, userTab.documentID)
        #expect(try await call.value.status == .stale)
        #expect(suggestedNames[userTab.id] == nil)

        // Allow for This Tab names the tab without Touch ID, and the client's later renames of the tab ask nothing.
        (card, call) = try await renameCard(handle, "Mail", service, client)
        #expect(await service.approvals.answer(card.id, with: .allowOnTab))
        let named = try await call.value
        #expect(named.status == .ok && named.structured?["name"] == "Mail")
        #expect(suggestedNames[userTab.id] == .some("Mail") && harness.authenticator.count == prompts)
        #expect(service.activity.entries.last { $0.tool == "rename_tab" }?.decision == .approved)
        let later = try await client.callTool("rename_tab", ["tab": .string(handle), "name": "Inbox"])
        #expect(later.status == .ok && service.approvals.pending.isEmpty && suggestedNames[userTab.id] == .some("Inbox"))
        #expect(service.activity.entries.last { $0.tool == "rename_tab" }?.decision == .auto)
    }

    /// Gives the service a runner over a scripted model that renames `t1` to "Named" in each run's first request and finishes in its second, and returns the model.
    private func scriptedRuns(_ service: AgentService, _ harness: Harness) -> ScriptedClient {
        let model = ScriptedClient { index in
            index.isMultiple(of: 2) ? [.event(.toolCall(AIToolCall(id: "r\(index)", name: "rename_tab", arguments: Data(#"{"tab":"t1","name":"Named"}"#.utf8)))), .event(.finished(.toolUse))]
                : [.event(.text("Done.")), .event(.finished(.completed))]
        }
        let provider = provider
        service.runService = AgentRunner(host: harness.host, client: model, activity: service.activity, resolve: { _, _ in [AIModelRef(provider: provider.id, model: "selected")] },
                                         provider: { $0 == provider.id ? provider : nil }, allowsAI: { _ in true }, reserve: { _, _ in true })
        return model
    }

    @Test func agentRunRenamesASharedTabOnlyOnceTheUserAllowedIt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, client) = try await connected(harness, scopes: AgentGrantScopes(startTasks: true))
        _ = scriptedRuns(service, harness)
        _ = try await client.callTool("list_spaces")
        let grant = try #require(service.grants.first)
        let userTab = AgentTabInfo(id: UUID(), spaceID: grant.spaceID, title: "Inbox", url: URL(string: "https://mail.example/inbox"), isLoading: false, engine: .webKit)
        let shared = try await share(userTab, service, client, harness)
        // Before the user allows the tab on P19's card, the run's rename would ask, which a run cannot.
        let refused = try await client.call(AgentControlMethod.agentRun, params: ["prompt": "Name it", "tabs": [.string(shared)]])
        #expect(refused["status"] == "completed" && refused["actions"] == [])
        #expect(suggestedNames[userTab.id] == nil)
        #expect(service.activity.entries.last { $0.tool == "rename_tab" }?.rule == AgentPolicy.wouldAskCode)
        let (card, call) = try await renameCard(shared, "Mail", service, client)
        #expect(await service.approvals.answer(card.id, with: .allowOnTab))
        #expect(try await call.value.status == .ok)
        let allowed = try await client.call(AgentControlMethod.agentRun, params: ["prompt": "Name it", "tabs": [.string(shared)]])
        #expect(allowed["status"] == "completed" && allowed["actions"] == [["renamedTab": ["tab": .string(shared), "name": "Named"]]])
        #expect(suggestedNames[userTab.id] == .some("Named"))
    }

    @Test func agentRunBindsEachTabsCommittedAddress() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, client) = try await connected(harness, scopes: AgentGrantScopes(startTasks: true))
        let model = scriptedRuns(service, harness)
        harness.host.pages[URL(string: "https://docs.example/start")!] = (title: "Docs", text: "Docs")
        let opened = try await client.callTool("open_tab", ["url": "https://docs.example/start"])
        let own = try #require(opened.structured?["tab"]?.stringValue)
        let grant = try #require(service.grants.first)
        let tab = try #require(harness.host.tabs.first { $0.agentOwnerID == grant.id })
        let index = try #require(harness.host.tabs.firstIndex { $0.id == tab.id })
        // While the tab loads another address, the run binds the page it committed, which the tab is leaving, so the tab joins no run.
        harness.host.tabs[index].url = URL(string: "https://docs.example/next")
        committedAddresses[tab.id] = URL(string: "https://docs.example/start")
        let loading = try await client.call(AgentControlMethod.agentRun, params: ["prompt": "Name it", "tabs": [.string(own)]])
        #expect(loading["status"] == "refused" && loading["code"] == "P16")
        #expect(model.requests.isEmpty && suggestedNames[tab.id] == nil)
        // Once the load commits, the run names the page the tab shows.
        committedAddresses[tab.id] = nil
        let committed = try await client.call(AgentControlMethod.agentRun, params: ["prompt": "Name it", "tabs": [.string(own)]])
        #expect(committed["status"] == "completed" && committed["actions"] == [["renamedTab": ["tab": .string(own), "name": "Named"]]])
        #expect(suggestedNames[tab.id] == .some("Named"))
    }

    @Test func agentRunNamesRenamedTabsByTheClientsHandles() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, client) = try await connected(harness)
        harness.host.pages[URL(string: "https://docs.example/start")!] = (title: "Docs", text: "Docs")
        let opened = try await client.callTool("open_tab", ["url": "https://docs.example/start"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let grant = try #require(service.grants.first)
        let tab = try #require(harness.host.tabs.first { $0.agentOwnerID == grant.id })
        let answer = service.clientJSON(of: AgentRunResult(status: .completed, actions: [.renamedTab(tab: tab.id, name: "Docs")]), for: grant)
        #expect(answer["actions"] == [["renamedTab": ["tab": .string(handle), "name": "Docs"]]])
        #expect(answer["status"] == "completed")
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
