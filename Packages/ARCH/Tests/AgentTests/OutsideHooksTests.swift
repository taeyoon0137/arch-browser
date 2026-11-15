// Hooks from outside programs on the service's side (`docs/hooks.md`, Hooks from outside programs; arch-cli hooks; Control methods and the registrar): `hooks/add` checks a proposal against the caps before the registrar sees it, refusing `tabs`, tab access `page`, Keep Nothing, agent tabs, and places outside the grant's Persona, says that it waits for the user, and answers with the registrar's decision; `hooks/list` and `hooks/remove` reach the registrar with the client's identity; and a grant's end tells the registrar which programs still have one.
import AgentControl
import Events
import Foundation
import Testing
@testable import Agent

/// The registry as the service sees it, answering each proposal with `decision`.
@MainActor final class FakeRegistrar: AgentHookRegistrar {
    var decision = AgentHookDecision.added(UUID())
    private(set) var proposals: [AgentHookProposal] = []
    private(set) var removed: [(UUID, AgentClientIdentity.Key)] = []
    private(set) var inForce: [Set<AgentClientIdentity.Key>] = []
    var listed: [AgentHookSummary] = []

    func hooks(addedBy client: AgentClientIdentity.Key) -> [AgentHookSummary] { listed }

    func propose(_ proposal: AgentHookProposal, from client: AgentClientIdentity, grant: AgentGrant) async -> AgentHookDecision {
        proposals.append(proposal)
        return decision
    }

    func remove(_ id: UUID, addedBy client: AgentClientIdentity.Key) -> Bool {
        removed.append((id, client))
        return true
    }

    func grantsDidChange(inForce clients: Set<AgentClientIdentity.Key>) {
        inForce.append(clients)
    }
}

@MainActor @Suite(.serialized) struct OutsideHooksTests {
    private func connected(_ harness: Harness) async throws -> (AgentService, FakeRegistrar, TestClient) {
        let service = try await harness.makeOpenService()
        let registrar = FakeRegistrar()
        service.hookRegistrar = registrar
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.defaultPersona.id))]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        return (service, registrar, client)
    }

    nonisolated static let script = "arch.events.on(\"pageLoaded\", async (event) => { await arch.tabs.rename(event.tab.id, \"Read\") })"

    nonisolated static func add(permissions: [String] = ["tabs.rename"], agent: AgentJSON? = nil, record: String? = nil, filter: AgentEventFilter = AgentEventFilter()) -> AgentHookAdd {
        AgentHookAdd(name: "Name tabs", event: "pageLoaded", loads: "first", filter: filter, script: script, permissions: permissions, agent: agent, record: record)
    }

    /// `hooks/add` and its progress sentences, from a thread of its own.
    private func propose(_ add: AgentHookAdd, on client: TestClient) async throws -> (AgentHookAddResult, [String]) {
        let params = try AgentJSON(encoding: add)
        return try await Task.detached {
            let progress = Shared<[String]>([])
            let result = try client.connection.call(AgentControlMethod.hooksAdd, params: params, timeout: 5) { progress.value.append($0) }
            return (try result.decode(as: AgentHookAddResult.self), progress.value)
        }.value
    }

    @Test func aProposalWithinTheCapsReachesTheRegistrarAndAnswersWithItsDecision() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (_, registrar, client) = try await connected(harness)
        let id = UUID()
        registrar.decision = .added(id)
        let agent: AgentJSON = ["prompt": "Name the tab.", "model": ["tier": "fast"], "limits": ["timeout": 20, "rounds": 1, "toolCalls": 2]]
        let (added, progress) = try await propose(Self.add(permissions: ["tabs.rename", "agent"], agent: agent, filter: AgentEventFilter(spaces: ["Home"])), on: client)
        #expect(added == AgentHookAddResult(status: .added, hook: id))
        #expect(progress.contains("Waiting for your approval in Arch\u{2026}"))
        let proposal = try #require(registrar.proposals.first)
        #expect(proposal.event == .pageLoaded && proposal.loads == "first" && proposal.renamesTabs)
        #expect(proposal.record == .activity)
        #expect(proposal.agent?.tabAccess == .title && proposal.agent?.tools == ["rename_tab"] && proposal.agent?.record == .activity)
        let home = try #require(harness.host.spaces(in: FakeHost.defaultPersona.id).first { $0.name == "Home" })
        #expect(proposal.filter.scope == .places([.space(home.id)]) && proposal.filter.kinds == [.pageLoaded])
        let grant = AgentHookProposal.agentGrant(for: try #require(proposal.agent))
        #expect(grant.tabAccess == .title && grant.minimumRecord == .activity && !grant.returnsReply && grant.runsPerDay == 200)
        // Without places, the hook covers the grant's Persona alone.
        registrar.decision = .declined("You did not allow it.")
        let (declined, _) = try await propose(Self.add(), on: client)
        #expect(declined.status == .declined)
        #expect(registrar.proposals.last?.filter.scope == .places([.persona(FakeHost.defaultPersona.id)]))
    }

    @Test(arguments: [
        ("tabs", OutsideHooksTests.add(permissions: ["tabs.rename", "tabs"])),
        ("page", OutsideHooksTests.add(permissions: ["agent"], agent: ["prompt": "Read it.", "model": ["tier": "fast"], "tabAccess": "page", "tools": ["read_text"]])),
        ("none", OutsideHooksTests.add(record: "none")),
        ("run none", OutsideHooksTests.add(permissions: ["agent"], agent: ["prompt": "Name it.", "model": ["tier": "fast"], "record": "none"])),
        ("agent tabs", OutsideHooksTests.add(filter: AgentEventFilter(tabKinds: ["agent"]))),
        ("another space", OutsideHooksTests.add(filter: AgentEventFilter(spaces: ["Office"]))),
        ("options without agent", OutsideHooksTests.add(agent: ["prompt": "Name it.", "model": ["tier": "fast"]])),
        ("agent without options", OutsideHooksTests.add(permissions: ["agent"])),
        ("unknown event", AgentHookAdd(name: "x", event: "tabMoved", script: OutsideHooksTests.script)),
        ("unknown tool", OutsideHooksTests.add(permissions: ["agent"], agent: ["prompt": "Name it.", "model": ["tier": "fast"], "tools": ["click"]])),
    ])
    func proposalsOutsideTheCapsAreRefusedBeforeTheSheet(case name: String, add: AgentHookAdd) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (_, registrar, client) = try await connected(harness)
        let (result, _) = try await propose(add, on: client)
        #expect(result.status == .refused, "\(name)")
        #expect(result.message?.isEmpty == false, "\(name)")
        #expect(registrar.proposals.isEmpty, "\(name)")
    }

    @Test func listAndRemoveReachTheRegistrarWithTheClientsIdentity() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (_, registrar, client) = try await connected(harness)
        let summary = AgentHookSummary(id: UUID(), name: "Name tabs", trigger: "When a new tab loads its first page", state: "active")
        registrar.listed = [summary]
        #expect(try await client.call(AgentControlMethod.hooksList).decode(as: AgentHookListing.self) == AgentHookListing(hooks: [summary]))
        #expect(try await client.call(AgentControlMethod.hooksRemove, params: ["hook": .string(summary.id.uuidString)])["removed"] == .bool(true))
        #expect(registrar.removed.first?.0 == summary.id && registrar.removed.first?.1 == harness.identity.value.key)
    }

    @Test func theRegistrarLearnsWhichProgramsKeepAGrant() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let (service, registrar, client) = try await connected(harness)
        _ = try await client.callTool("list_spaces")
        let key = harness.identity.value.key
        #expect(registrar.inForce.last == [key])
        service.revoke(try #require(service.grants.first).id)
        #expect(registrar.inForce.last == [])
    }
}
