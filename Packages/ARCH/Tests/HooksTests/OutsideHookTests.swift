// Hooks from outside programs in the registry (`docs/hooks.md`, Hooks from outside programs; arch-cli hooks): a proposal shows the sheet with its agent's instructions, script, and permissions, adds the hook only after Allow and Touch ID, with the program as its origin and the caps in its grant, and makes the program wait a minute after a decline; a program has one sheet at a time, which closes unanswered when the program leaves, and a program whose access ended while its sheet showed adds nothing without Touch ID; one program adds at most 20 hooks; the user's edits cannot lift the caps; a program's hooks run only after the first report of grants and never on a site excluded from AI; they pause with `grantEnded` when the grant ends, also at the launch after a grant until Arch quits, and Resume needs no Touch ID; and a program lists and removes only its own hooks.
import Agent
import AgentControl
import AI
import Events
import Foundation
import Testing
@testable import Hooks

@MainActor final class FakeProposalPrompt: HookProposalPrompting {
    var answer = true
    private(set) var reviews: [HookProposalReview] = []

    func ask(_ review: HookProposalReview) async -> Bool {
        reviews.append(review)
        return answer
    }

    func cancelAll() {}
}

/// A proposal sheet that stays open until `answer` or until its asking task is cancelled, as when the program leaves.
@MainActor final class WaitingProposalPrompt: HookProposalPrompting {
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private(set) var asked = 0

    var isWaiting: Bool { !waiting.isEmpty }

    func ask(_ review: HookProposalReview) async -> Bool {
        asked += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append($0) }
        } onCancel: {
            Task { @MainActor in self.answer(false) }
        }
    }

    func answer(_ allowed: Bool) {
        let answered = waiting
        waiting = []
        answered.forEach { $0.resume(returning: allowed) }
    }

    func cancelAll() { answer(false) }
}

final class FakeHookAuthenticator: AgentAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer = true
    private var _count = 0

    var answer: Bool {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    var count: Int { lock.withLock { _count } }

    func authenticate(reason: String) async -> Bool {
        lock.withLock {
            _count += 1
            return _answer
        }
    }
}

@MainActor @Suite(.serialized) struct OutsideHookTests {
    private let program = AgentClientIdentity(key: .signed(identifier: "com.example.agent", team: "ABCDE12345"), name: "agent", executablePath: "/Applications/Agent.app/Contents/MacOS/agent",
                                              host: "Agent", isInterpreter: false)
    private let other = AgentClientIdentity(key: .unsigned(path: "/usr/local/bin/other", codeHash: "00"), name: "other", executablePath: "/usr/local/bin/other", host: nil, isInterpreter: false)
    nonisolated private static let script = "arch.events.on(\"pageLoaded\", async (event) => { await arch.agent.run({ ...event.hook.agent, tabs: [event.tab.id] }) })"

    private func grant(for client: AgentClientIdentity) -> AgentGrant {
        AgentGrant(client: client, personaID: HookIDs.persona, spaceID: HookIDs.work, level: .readOnly, scopes: AgentGrantScopes(), expiry: .whenRevoked, grantedAt: Date())
    }

    private func proposal(_ script: String = OutsideHookTests.script) -> AgentHookProposal {
        let options = AgentRunOptions(prompt: "Name the tab.", tabAccess: .title, model: .tier(.fast), record: .activity, tools: ["rename_tab"],
                                      limits: AgentRunLimits(timeout: .seconds(20), rounds: 1, toolCalls: 2))
        return AgentHookProposal(name: "Name tabs", event: .pageLoaded, loads: "first", filter: BrowserEventFilter(kinds: [.pageLoaded], scope: .places([.persona(HookIDs.persona)])),
                                 script: Data(script.utf8), renamesTabs: true, agent: options, record: .activity)
    }

    private func start(_ harness: RegistryHarness) async throws -> (HookRegistry, FakeProposalPrompt, FakeHookAuthenticator) {
        let registry = try await harness.start()
        let prompt = FakeProposalPrompt()
        let authenticator = FakeHookAuthenticator()
        registry.proposalPrompt = prompt
        registry.authenticator = authenticator
        registry.grantsDidChange(inForce: [program.key, other.key])
        return (registry, prompt, authenticator)
    }

    @Test func aProposalAddsACappedHookAfterTheSheetAndTouchID() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let (registry, prompt, authenticator) = try await start(harness)
        guard case .added(let id) = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("The hook was not added."); return }
        let review = try #require(prompt.reviews.first)
        #expect(review.script == Self.script && review.clientName == "agent in Agent" && review.clientPath == program.executablePath)
        #expect(review.situation == "When a new tab loads its first page \u{00B7} Personal \u{00B7} all sites")
        #expect(review.agent.first == "Model: Fast tier \u{00B7} Test \u{2014} model-a")
        #expect(review.prompt == "Name the tab.")
        #expect(review.permissions.contains { $0.contains("never its page") })
        #expect(HookProposalReview.tabNamesSentence == catalogText("Names this hook gives your tabs are saved in Arch's session file, which other programs on this Mac can read."))
        #expect(authenticator.count == 1)
        let hook = try #require(registry.hooks.first { $0.id == id })
        #expect(hook.origin == .outsideClient(program.key, name: "agent in Agent"))
        #expect(hook.grant.permissions == [.tabsRename, .agent])
        #expect(hook.grant.agent?.tabAccess == .title && hook.grant.agent?.minimumRecord == .activity && hook.grant.agent?.returnsReply == false)
        #expect(hook.timing.timeout == .seconds(25) && hook.timing.runsPerDay == 200)
        #expect(hook.state == .active)
        #expect(registry.hooks(addedBy: program.key).map(\.id) == [id])
        #expect(registry.hooks(addedBy: other.key).isEmpty)
    }

    @Test func aDeclineWaitsAMinuteAndAScriptMustParse() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let (registry, prompt, authenticator) = try await start(harness)
        prompt.answer = false
        guard case .declined = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("Don't Allow must decline."); return }
        guard case .declined = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("A minute must pass."); return }
        #expect(prompt.reviews.count == 1)
        // Another program is not held up, and Touch ID that fails declines too.
        prompt.answer = true
        authenticator.answer = false
        guard case .declined = await registry.propose(proposal(), from: other, grant: grant(for: other)) else { Issue.record("Touch ID must confirm."); return }
        harness.clock.now = harness.clock.now.addingTimeInterval(61)
        authenticator.answer = true
        guard case .added = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("After a minute the sheet shows again."); return }
        guard case .refused = await registry.propose(proposal("arch.events.on(\"pageLoaded\", ("), from: program, grant: grant(for: program)) else { Issue.record("A script that does not parse is refused."); return }
        #expect(registry.hooks.count == 1)
    }

    @Test func aProgramHasOneSheetAtATimeAndOnlyWhileItHasAccess() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let registry = try await harness.start()
        let prompt = WaitingProposalPrompt()
        let authenticator = FakeHookAuthenticator()
        registry.proposalPrompt = prompt
        registry.authenticator = authenticator
        registry.grantsDidChange(inForce: [program.key, other.key])
        let first = Task { await registry.propose(proposal(), from: program, grant: grant(for: program)) }
        #expect(await eventually { prompt.isWaiting })
        // The program's next proposal does not show while its first one does.
        guard case .declined = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("A second sheet must not show."); return }
        #expect(prompt.asked == 1)
        // The program leaves: its sheet closes unanswered, without Touch ID.
        first.cancel()
        guard case .declined = await first.value else { Issue.record("A program that left must add nothing."); return }
        #expect(authenticator.count == 0)
        // Another program's access ends while its sheet shows: Allow adds nothing and asks for no Touch ID.
        let second = Task { await registry.propose(proposal(), from: other, grant: grant(for: other)) }
        #expect(await eventually { prompt.isWaiting })
        registry.grantsDidChange(inForce: [program.key])
        prompt.answer(true)
        guard case .refused = await second.value else { Issue.record("A program without access must add nothing."); return }
        #expect(authenticator.count == 0)
        #expect(registry.hooks.isEmpty)
    }

    @Test func aProgramsHooksRunOnlyAfterTheFirstReportAndNeverOnExcludedSites() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let registry = try await harness.start()
        var hook = instantHook("Name tabs", .tabOpened, filter: BrowserEventFilter(kinds: [.tabOpened], scope: .places([.persona(HookIDs.persona)])),
                               grant: HookGrant(permissions: [.tabsRename]))
        hook.origin = .outsideClient(program.key, name: "agent in Agent")
        let programs = try harness.add(hook)
        let users = try harness.add(instantHook("Mine", .tabOpened))
        func open(_ host: String = "example.org") {
            let tab = harness.tab(host: host)
            harness.host.show(tab)
            harness.bus.post(.tabOpened(tab: tab, openerTabID: nil))
        }
        // Until the agents' service has checked agent.json and said which programs keep a grant, a program's hook does not run.
        open()
        #expect(await eventually { harness.javaScript.invocations(of: users.id).count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.javaScript.invocations(of: programs.id).isEmpty)
        registry.grantsDidChange(inForce: [program.key])
        open()
        #expect(await eventually { harness.javaScript.invocations(of: programs.id).count == 1 })
        // A site excluded from AI keeps its events from a program's hook without agent, so that its last runs do not tell the program of the visit.
        harness.service.settings.excludedSites.append(AISitePattern("excluded.example"))
        open("excluded.example")
        #expect(await eventually { harness.javaScript.invocations(of: users.id).count == 3 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.javaScript.invocations(of: programs.id).count == 1)
    }

    @Test func oneProgramAddsAtMostTwentyHooks() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let (registry, _, _) = try await start(harness)
        for _ in 0 ..< HookRegistry.hooksPerProgram {
            guard case .added = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("A hook within the cap was not added."); return }
        }
        guard case .refused = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("The 21st hook must be refused."); return }
        guard case .added = await registry.propose(proposal(), from: other, grant: grant(for: other)) else { Issue.record("Another program has its own cap."); return }
    }

    @Test func theUsersEditsCannotLiftTheCaps() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let (registry, _, _) = try await start(harness)
        guard case .added(let id) = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("The hook was not added."); return }
        let hook = try #require(registry.hooks.first { $0.id == id })
        var titles = hook
        titles.grant.permissions.insert(.tabs)
        var reply = hook
        reply.grant.agent?.returnsReply = true
        var elsewhere = hook
        elsewhere.filter.scope = .places([.persona(HookIDs.otherPersona)])
        var everywhere = hook
        everywhere.filter.scope = .everywhere
        var nothing = hook
        nothing.record = .none
        for edit in [titles, reply, elsewhere, everywhere, nothing] {
            #expect(throws: HookRegistryError.self) { try registry.update(edit, script: nil) }
        }
        var renamed = hook
        renamed.name = "Tidy names"
        renamed.filter.scope = .places([.space(HookIDs.home)])
        try registry.update(renamed, script: nil)
        #expect(registry.hooks.first { $0.id == id }?.name == "Tidy names")
    }

    @Test func aProgramsHooksPauseWhenItsGrantEndsAndResumeWithoutTouchID() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let (registry, _, authenticator) = try await start(harness)
        guard case .added(let id) = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("The hook was not added."); return }
        guard case .added(let kept) = await registry.propose(proposal(), from: other, grant: grant(for: other)) else { Issue.record("The hook was not added."); return }
        registry.grantsDidChange(inForce: [other.key])
        #expect(registry.hooks.first { $0.id == id }?.state == .paused(.grantEnded))
        #expect(registry.hooks.first { $0.id == kept }?.state == .active)
        let touches = authenticator.count
        registry.resume(id)
        #expect(registry.hooks.first { $0.id == id }?.state == .active)
        #expect(authenticator.count == touches)
        // A later change that ends no grant of the program leaves the resumed hook alone.
        registry.grantsDidChange(inForce: [])
        #expect(registry.hooks.first { $0.id == id }?.state == .active)
        #expect(registry.hooks.first { $0.id == kept }?.state == .paused(.grantEnded))
        // At the next launch, a program with no grant in force, as after a grant until Arch quits, has its hooks paused.
        registry.resume(kept)
        #expect(await eventually { FileManager.default.fileExists(atPath: harness.folder.appendingPathComponent("hooks.json").path) })
        let relaunch = RegistryHarness(folder: harness.folder, keys: harness.keys)
        let reopened = try await relaunch.start()
        try #require(await eventually { reopened.hooks.count == 2 })
        reopened.grantsDidChange(inForce: [program.key])
        #expect(reopened.hooks.first { $0.id == id }?.state == .active)
        #expect(reopened.hooks.first { $0.id == kept }?.state == .paused(.grantEnded))
    }

    @Test func aProgramRemovesOnlyItsOwnHooks() async throws {
        let harness = RegistryHarness()
        defer { harness.cleanUp() }
        let (registry, _, _) = try await start(harness)
        guard case .added(let id) = await registry.propose(proposal(), from: program, grant: grant(for: program)) else { Issue.record("The hook was not added."); return }
        let users = try harness.add(instantHook("Mine", .tabOpened))
        #expect(!registry.remove(id, addedBy: other.key))
        #expect(!registry.remove(users.id, addedBy: program.key))
        #expect(registry.remove(id, addedBy: program.key))
        #expect(registry.hooks.map(\.id) == [users.id])
    }
}
