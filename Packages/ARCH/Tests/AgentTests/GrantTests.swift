// Grants for outside clients (docs/agents.md, Outside clients: identity, grants, revocation): the first tool call asks with the sheet and `hello` then names the grant, and the client's connections get `tools/changed`; the Agents Persona is made on demand, recorded, and agent-only; Touch ID or the login password guards every grant except Read Only in the Agents Persona with no scope until quit; Don't Allow asks again only after a minute; revocation, release, expiry, a grant's process ending, and its Persona's deletion end the grant and close its connections with `revoked`.
import AgentControl
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct GrantTests {
    @Test func theFirstCallAsksAndHelloThenNamesTheGrant() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice()]
        let client = try TestClient(harness.location)
        #expect(try await client.hello().status == .noGrant)
        #expect(harness.prompt.requests.isEmpty)
        let result = try await client.callTool("list_spaces")
        #expect(result.status == .ok)
        #expect(result.text.hasPrefix("The Agents Persona has 1 space."))
        #expect(result.structured == ["spaces": [["handle": "s1", "name": "Personal", "agentTabs": 0]]])
        // The sheet offered the user's own Personas, and no Agents Persona existed yet.
        #expect(harness.prompt.requests.map(\.personas) == [[FakeHost.defaultPersona, FakeHost.workPersona]])
        #expect(harness.prompt.requests.first?.agentsSpaces.isEmpty == true)
        #expect(harness.authenticator.count == 0)
        // The Agents Persona was made once, recorded, and made agent-only before any of its profiles could start.
        let agentsID = try #require(service.settings.agentsPersonaID)
        #expect(harness.host.madeAgentsPersonas == 1)
        #expect(harness.host.agentOnlyPersonaID == agentsID)
        #expect(service.launchGrants.count == 1 && service.settings.grants.isEmpty)
        #expect(try await TestClient(harness.location).hello().status == .granted(AgentGrantSummary(level: .readOnly, persona: "Agents", space: "Personal", expiry: .whenArchQuits)))
        // A later call uses the grant without asking, and so does a call for another grant in the existing Agents Persona.
        #expect(try await client.callTool("session_info").status == .ok)
        #expect(harness.prompt.requests.count == 1)
        #expect(service.activity.entries.map(\.event) == [.granted, .firstUse, .toolCall, .toolCall])
    }

    @Test func toolsListFollowsTheLevel() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await harness.makeOpenService()
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        // Before a grant, the list names every served tool, since the sheet may allow any of them.
        let names = try await client.call("tools/list").decode(as: AgentToolList.self).tools
        let acting = ["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "navigate", "close_tab", "snapshot", "read_text", "screenshot", "click", "type", "press",
                      "select_option", "scroll", "hover", "wait_for", "list_downloads", "search_history", "ask_user", "request_approval", "hand_to_user", "approval_wait", "guide"]
        #expect(names == acting)
        #expect(AgentToolHost.toolsBeforeGrant.map(\.name) == acting)
        // Read Only leaves out the actions that change data and the sensitive request_approval; the others come with Ask Before Acting, and search_history with its scope.
        let readOnly = ["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "navigate", "close_tab", "snapshot", "read_text", "screenshot", "scroll", "hover", "wait_for",
                        "list_downloads", "ask_user", "hand_to_user", "approval_wait", "guide"]
        #expect(AgentToolHost.tools(for: .readOnly, scopes: AgentGrantScopes()).map(\.name) == readOnly)
        #expect(AgentToolHost.tools(for: .actInAgentTabs, scopes: AgentGrantScopes(searchHistory: true)).map(\.name) == acting)
    }

    @Test func aGrantSendsToolsChangedToTheClientsConnections() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice()]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        let idle = try TestClient(harness.location)
        _ = try await idle.hello()
        #expect(try await client.callTool("list_tabs").status == .ok)
        // The connection that made no call learns that its list changed, and lists again for the grant.
        #expect(try await idle.receive() == .notification(method: "tools/changed", params: nil))
        let names = try await idle.call("tools/list").decode(as: AgentToolList.self).tools
        #expect(names == AgentToolHost.tools(for: .readOnly, scopes: AgentGrantScopes()).map(\.name))
    }

    @Test(arguments: [
        (AgentGrantChoice(), false),
        (AgentGrantChoice(level: .askBeforeActing), true),
        (AgentGrantChoice(level: .actInAgentTabs), true),
        (AgentGrantChoice(scopes: AgentGrantScopes(searchHistory: true)), true),
        (AgentGrantChoice(scopes: AgentGrantScopes(startTasks: true)), true),
        (AgentGrantChoice(duration: .day), true),
        (AgentGrantChoice(duration: .untilRevoked), true),
        (AgentGrantChoice(persona: .existing(FakeHost.workPersona.id)), true),
    ])
    func touchIDGuardsEveryGrantButReadOnlyInTheAgentsPersonaUntilQuit(choice: AgentGrantChoice, asks: Bool) {
        #expect(choice.needsAuthentication == asks)
    }

    @Test func aGrantThatNeedsTouchIDIsGivenOnlyAfterIt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let work = try #require(harness.host.spacesByPersona[FakeHost.workPersona.id]?.first)
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.workPersona.id), level: .askBeforeActing, duration: .untilRevoked),
                                  AgentGrantChoice(persona: .existing(FakeHost.workPersona.id), level: .askBeforeActing, duration: .untilRevoked)]
        harness.authenticator.answer = false
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        await #expect(throws: AgentClientError.noGrant("You did not allow agent in Agent to use Arch.")) { try await client.callTool("session_info") }
        #expect(harness.authenticator.count == 1)
        #expect(service.grants.isEmpty)
        harness.now += AgentService.askInterval + 1
        harness.authenticator.answer = true
        let result = try await client.callTool("session_info")
        #expect(result.text.hasPrefix("This client has Ask Before Acting access in Work / Office (s1)."))
        #expect(harness.authenticator.count == 2)
        #expect(service.settings.grants.map(\.personaID) == [FakeHost.workPersona.id])
        #expect(service.settings.grants.first?.spaceID == work.id)
        #expect(service.activity.entries.first { $0.event == .granted }?.decision == .approvedWithTouchID)
        // A grant in the user's own Persona makes no Agents Persona.
        #expect(harness.host.madeAgentsPersonas == 0)
        #expect(harness.host.agentOnlyPersonaID == nil)
    }

    @Test func dontAllowAsksAgainOnlyAfterAMinute() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        await #expect(throws: AgentClientError.noGrant("You did not allow agent in Agent to use Arch.")) { try await client.callTool("list_tabs") }
        await #expect(throws: AgentClientError.noGrant("You did not allow agent in Agent to use Arch a moment ago. Arch asks again after a minute.")) { try await client.callTool("list_tabs") }
        #expect(harness.prompt.requests.count == 1)
        harness.now += AgentService.askInterval + 1
        harness.prompt.answers = [AgentGrantChoice()]
        #expect(try await client.callTool("list_tabs").status == .ok)
        #expect(harness.prompt.requests.count == 2)
        #expect(service.activity.entries.filter { $0.event == .declined }.count == 1)
        #expect(AgentClientError.noGrant("").exitCode.rawValue == 6)
    }

    @Test func disconnectEmptiesTheSidebarAndKeepsTheGrantForReconnect() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice()]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("session_info")
        let grant = try #require(service.connectedGrants.first)
        service.stopClient(grant.id)
        try await waitUntil { service.connectedGrants.isEmpty }
        #expect(service.grants.map(\.id) == [grant.id])
        let next = try TestClient(harness.location)
        _ = try await next.hello()
        #expect(try await next.callTool("list_spaces").status == .ok)
        #expect(service.connectedGrants.map(\.id) == [grant.id])
        #expect(harness.prompt.requests.count == 1)
    }

    @Test func revocationSendsRevokedAndClosesTheConnection() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice()]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("session_info")
        try await waitUntil { !service.connectedGrantIDs.isEmpty }
        service.revoke(try #require(service.grants.first?.id))
        #expect(service.grants.isEmpty)
        #expect(try await client.receive() == .notification(method: "revoked", params: ["message": "The user revoked this client's access in Arch."]))
        await #expect(throws: AgentClientError.closed) { try await client.receive() }
        #expect(service.activity.entries.last?.event == .revoked)
        // The next client of the same program asks again.
        #expect(try await TestClient(harness.location).hello().status == .noGrant)
    }

    @Test func expiryAndAnEndedProcessEndAGrant() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(duration: .day)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("list_spaces")
        #expect(service.settings.grants.count == 1)
        harness.now += 23 * 60 * 60
        service.expireGrants()
        #expect(service.settings.grants.count == 1)
        harness.now += 2 * 60 * 60
        service.expireGrants()
        #expect(service.grants.isEmpty)
        #expect(try await client.receive() == .notification(method: "revoked", params: ["message": "This client's access to Arch expired."]))
        await #expect(throws: AgentClientError.closed) { try await client.receive() }
        #expect(service.activity.entries.last?.event == .expired)

        // A grant bound to a process ends once that process does.
        let start = AgentProcessStart(seconds: 1_900_000_000, microseconds: 5)
        harness.identity.value = AgentClientIdentity(key: .process(path: "/bin/zsh", codeHash: "ab", processID: 4242, start: start), name: "zsh", executablePath: "/bin/zsh", host: "Arch\u{2019}s terminal", isInterpreter: false)
        harness.processStarts.value = [4242: start]
        harness.prompt.answers = [AgentGrantChoice()]
        harness.now += AgentService.askInterval + 1
        let shell = try TestClient(harness.location)
        _ = try await shell.hello()
        _ = try await shell.callTool("list_spaces")
        service.expireGrants()
        #expect(service.grants.count == 1)
        harness.processStarts.value = [4242: AgentProcessStart(seconds: 1_900_000_100, microseconds: 0)]
        service.expireGrants()
        #expect(service.grants.isEmpty)
        #expect(try await shell.receive() == .notification(method: "revoked", params: ["message": "This client's access to Arch expired."]))
        await #expect(throws: AgentClientError.closed) { try await shell.receive() }
    }

    @Test func aReleasedGrantAsksAgain() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(duration: .untilRevoked)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("session_info")
        let other = try TestClient(harness.location)
        _ = try await other.hello()
        #expect(try await client.call("grant/release") == ["released": true])
        #expect(service.grants.isEmpty)
        #expect(try await other.receive() == .notification(method: "revoked", params: ["message": "This client gave up its access to Arch."]))
        #expect(try await client.call("grant/release") == ["released": false])
        #expect(try await TestClient(harness.location).hello().status == .noGrant)
        #expect(service.activity.entries.last?.event == .released)
    }

    @Test func aDeletedPersonaTakesItsGrantsAndTheRecordedAgentsPersona() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(duration: .untilRevoked)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("session_info")
        let agentsID = try #require(service.settings.agentsPersonaID)
        harness.host.deletePersona(agentsID)
        #expect(service.grants.isEmpty)
        #expect(service.settings.agentsPersonaID == nil)
        #expect(harness.host.agentOnlyPersonaID == nil)
        #expect(try await client.receive() == .notification(method: "revoked", params: ["message": "The Persona of this client's access was deleted."]))
    }

    @Test func turningOutsideAccessOffClosesClientsAndKeepsGrants() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(duration: .untilRevoked)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("session_info")
        try await service.setAllowsOutsideClients(false)
        await #expect(throws: AgentClientError.closed) { try await client.receive() }
        #expect(service.grants.count == 1)
        #expect(!harness.socketExists)
    }
}
