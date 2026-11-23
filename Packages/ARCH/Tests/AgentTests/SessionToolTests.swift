// An in-app session's calls on the tool host's grant path (docs/agents.md, Site scope and navigation; Approval interface), through a fake host and the session's `AgentSessionTools`: the mode's tools; rule P13 at `open_tab`, `navigate`, and the redirect hops of a written address, at most three a call, in Read Only too, with a sensitive card that shows the full address with its unseen parts marked and whose Allow adds the address to the scope and is the activity entry's decision; hops checked per navigation, not per call: a popup is none, a hop once no call waits is refused with an event, and a commit ends the checks; the cards of one call ending at its deadline; agent tabs in the session's own folder and their limit after a card; a call held while the user has taken the session over until Hand Back, and no card from a call running then; Take Over on a card pausing the session; the 150 calls of a message; each call a step and an activity entry; a call waiting on a card withdrawn as denied, with nothing run, when its task is cancelled, at Stop All Agents, and at Deny and Stop; a dragged-out tab refused under P17; and the verified client's name, Touch ID, and `--deny-approvals` for a session an outside client started.
import AgentControl
import AI
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct SessionToolTests {
    nonisolated static let model = AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet")
    nonisolated static let readOnlyTools = ["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "navigate", "close_tab", "snapshot", "read_text", "screenshot",
                                            "scroll", "hover", "wait_for", "list_downloads", "ask_user", "hand_to_user", "guide"]
    nonisolated static let askingTools = ["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "navigate", "close_tab", "snapshot", "read_text", "screenshot",
                                          "click", "type", "press", "select_option", "scroll", "hover", "wait_for", "list_downloads", "ask_user", "request_approval", "hand_to_user", "guide"]

    /// The user's tab at `https://docs.example/guide`, which a session attaches, so that docs.example is in its scope and that address is seen.
    private func userTab(_ harness: Harness) throws -> AgentTabInfo {
        let space = try #require(harness.host.spaces(in: FakeHost.defaultPersona.id).first)
        let tab = AgentTabInfo(id: UUID(), spaceID: space.id, title: "Guide", url: URL(string: "https://docs.example/guide"), isLoading: false, engine: .webKit)
        harness.host.tabs.append(tab)
        harness.host.userTabIDs.insert(tab.id)
        return tab
    }

    /// A session on the fake CLI whose model gave its first output, so that its calls run, and its tools as an HTTP session's loop runs them.
    private func start(_ service: AgentService, _ harness: Harness, task: String = "Read this", attaching tabs: [UUID] = [], mode: AgentAccessLevel,
                       origin: AgentSession.Origin = .app) async throws -> (AgentSession, FakeRunner, any AgentSessionTools) {
        service.setNewSessionMode(.actInAgentTabs)
        let persona = FakeHost.defaultPersona.id
        let space = try #require(harness.host.spaces(in: persona).first)
        var start = AgentService.SessionStart(task: task, personaID: persona, spaceID: space.id, attachedTabIDs: tabs, mode: mode, model: nil, effort: nil)
        start.origin = origin
        let session = try service.startSession(start)
        let runner = try #require(harness.runners.last)
        runner.emit(.ready(Self.model))
        try await waitUntil { session.model != nil }
        return (session, runner, service.sessionTools(for: session))
    }

    private func call(_ tools: any AgentSessionTools, _ name: String, _ arguments: [String: AgentJSON] = [:]) async -> AgentToolResult {
        await tools.run(AgentToolCall(name: name, arguments: arguments))
    }

    /// The card the session waits on, once it opens.
    private func waitingCard(_ service: AgentService, of session: AgentSession) async throws -> AgentApproval {
        try await waitUntil { service.approvals.pending.contains { $0.ownerID == session.id } }
        return try #require(service.approvals.pending.first { $0.ownerID == session.id })
    }

    @Test func theSessionListsTheToolsOfItsMode() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, _, tools) = try await start(service, harness, mode: .readOnly)
        #expect(tools.tools.map(\.name) == Self.readOnlyTools)
        session.setMode(.askBeforeActing)
        #expect(tools.tools.map(\.name) == Self.askingTools)
        // A session an outside client started opens agent tabs of its own but asks for none of the user's.
        let (outside, _, outsideTools) = try await start(service, harness, mode: .readOnly, origin: .outsideClient(grantID: UUID(), clientName: "agent", deniesApprovals: false))
        #expect(outsideTools.tools.map(\.name) == Self.readOnlyTools.filter { $0 != "request_tab" })
        await service.deleteSession(outside.id)
        await service.deleteSession(session.id)
    }

    @Test func writtenAddressesOpenOnlyWhenSeenOrABareOriginInScopeAndAskOtherwiseEvenInReadOnly() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let attached = try userTab(harness)
        let (session, _, tools) = try await start(service, harness, attaching: [attached.id], mode: .readOnly)
        #expect(session.siteScope == ["docs.example"])
        // The bare origin of a site in scope and an address a tab showed open without a card, in the session's own agent folder.
        let origin = await call(tools, "open_tab", ["url": "https://docs.example/"])
        #expect(origin.status == .ok && service.approvals.pending.isEmpty)
        let space = try #require(harness.host.spaces(in: FakeHost.defaultPersona.id).first)
        #expect(harness.host.openedOwners == [AgentTabOwner(id: session.id, spaceID: space.id, folderName: session.title)])
        #expect(await call(tools, "open_tab", ["url": "https://docs.example/guide"]).status == .ok)
        #expect(harness.host.agentTabs(of: session.id).count == 2)

        // The same site with a query no page showed asks, in Read Only too; the card leads with the step and shows the full address with its query marked.
        let carrying = "https://docs.example/guide?d=secret"
        let denied = Task { await call(tools, "open_tab", ["url": .string(carrying)]) }
        let card = try await waitingCard(service, of: session)
        #expect(card.rules == [.p13] && card.isSensitive && card.kind == .step)
        #expect(card.action == "Open an address in a new agent tab" && card.exactText == carrying)
        #expect(card.exactTextNote == "The agent wants to open \(carrying) \u{2014} an address no page showed.")
        #expect(card.addressQuestion?.unseenParts == [.query] && card.addressQuestion?.isOutsideScope == false)
        let marked = try #require(card.addressQuestion?.markedAddress)
        #expect(marked.unseen.map { String(marked.text[$0]) } == ["d=secret"])
        #expect(!card.offers.contains(.takeOver) && !card.offers.contains(.allowOnPage) && !card.needsAuthentication)
        #expect(session.state == .waitingForUser)
        #expect(await service.approvals.answer(card.id, with: .deny))
        let deniedResult = await denied.value
        #expect(deniedResult.status == .denied && harness.host.agentTabs(of: session.id).count == 2)
        #expect(session.state == .running && service.activity.entries.last?.decision == .denied)
        // The transcript names the step the user turned down as what the agent asked for.
        let deniedStep = session.items.compactMap { item -> AgentStep? in if case .step(let step) = item.kind { return step } else { return nil } }.last
        #expect(deniedStep?.sentence == "Open a tab: you said no")

        // A site outside the scope asks and says so; Allow opens it and adds it to the scope.
        let outside = "https://elsewhere.example/collect?d=1"
        let allowed = Task { await call(tools, "open_tab", ["url": .string(outside)]) }
        let outsideCard = try await waitingCard(service, of: session)
        #expect(outsideCard.addressQuestion?.isOutsideScope == true && outsideCard.exactTextNote?.hasSuffix("on a site you did not name.") == true)
        #expect(await service.approvals.answer(outsideCard.id, with: .allowOnce))
        let allowedResult = await allowed.value
        #expect(allowedResult.status == .ok && session.siteScope == ["docs.example", "elsewhere.example"])
        #expect(harness.host.agentTabs(of: session.id).count == 3)
        // The activity log keeps the user's Allow, not a step that ran without asking.
        #expect(service.activity.entries.last?.tool == "open_tab" && service.activity.entries.last?.decision == .approved)
        await service.deleteSession(session.id)
    }

    @Test func navigateAsksForAnUnseenPathAndOpensACommittedAddressAgainWithoutAsking() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let attached = try userTab(harness)
        let (session, _, tools) = try await start(service, harness, attaching: [attached.id], mode: .actInAgentTabs)
        let opened = await call(tools, "open_tab", ["url": "https://docs.example/"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let address = "https://docs.example/plans/next"
        let navigation = Task { await call(tools, "navigate", ["tab": .string(handle), "url": .string(address)]) }
        let card = try await waitingCard(service, of: session)
        #expect(card.action == "Open an address in \(handle)" && card.tabHandle == handle && card.offers.contains(.takeOver))
        #expect(card.addressQuestion?.unseenParts == [.path])
        #expect(await service.approvals.answer(card.id, with: .allowOnce))
        let result = await navigation.value
        #expect(result.status == .ok && harness.host.agentTabs(of: session.id).first?.url?.absoluteString == address)
        // The address the tab committed is seen, so writing it again asks nothing.
        _ = await call(tools, "navigate", ["tab": .string(handle), "url": "https://docs.example/"])
        #expect(await call(tools, "navigate", ["tab": .string(handle), "url": .string(address)]).status == .ok)
        #expect(service.approvals.pending.isEmpty)
        await service.deleteSession(session.id)
    }

    @Test func aRedirectOfAWrittenAddressOffTheScopeStopsAndAsksWithTheHopsAddress() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let written = try #require(URL(string: "https://docs.example/out"))
        let hop = try #require(URL(string: "https://tracker.example/hop?d=1"))
        harness.host.redirects[written] = hop
        harness.host.redirects[URL(string: "https://docs.example/bad")!] = URL(string: "https://excluded.example/")
        // The user wrote the address, so it opens without asking; its redirect to another site does not.
        let (session, _, tools) = try await start(service, harness, task: "Open https://docs.example/out and https://docs.example/bad", mode: .readOnly)
        let opening = Task { await call(tools, "open_tab", ["url": .string(written.absoluteString)]) }
        let card = try await waitingCard(service, of: session)
        #expect(card.rules == [.p13] && card.exactText == hop.absoluteString && card.addressQuestion?.isOutsideScope == true)
        let handle = try #require(card.tabHandle)
        #expect(card.action == "Follow a redirect in \(handle) to a site outside the session's scope")
        // The hop's request never went: the tab stayed on no page while the card waited.
        #expect(harness.host.agentTabs(of: session.id).first?.url == nil)
        #expect(await service.approvals.answer(card.id, with: .allowOnce))
        let opened = await opening.value
        #expect(opened.status == .ok && harness.host.agentTabs(of: session.id).first?.url == hop)
        #expect(session.siteScope.contains("tracker.example"))

        // A hop to an excluded site is refused (P16), with no card.
        let refused = await call(tools, "navigate", ["tab": .string(handle), "url": "https://docs.example/bad"])
        #expect(refused.status == .refused && refused.code == "P16" && service.approvals.pending.isEmpty)

        // A reload is no written address, so its redirect to another site goes on without asking.
        let reloading = try #require(URL(string: "https://docs.example/out"))
        _ = await call(tools, "navigate", ["tab": .string(handle), "url": .string(reloading.absoluteString)])
        harness.host.redirects[hop] = URL(string: "https://third.example/")
        let reloaded = await call(tools, "navigate", ["tab": .string(handle), "action": "reload"])
        #expect(reloaded.status == .ok && service.approvals.pending.isEmpty)
        await service.deleteSession(session.id)
    }

    @Test func aCallAsksAboutAtMostThreeRedirectsOffTheScope() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let chain = ["https://docs.example/chain", "https://one.example/", "https://two.example/", "https://three.example/", "https://four.example/"].compactMap(URL.init(string:))
        for (from, to) in zip(chain, chain.dropFirst()) { harness.host.redirects[from] = to }
        let (session, _, tools) = try await start(service, harness, task: "Open https://docs.example/chain", mode: .readOnly)
        let opening = Task { await call(tools, "open_tab", ["url": .string(chain[0].absoluteString)]) }
        for hop in chain[1 ... 3] {
            let card = try await waitingCard(service, of: session)
            #expect(card.exactText == hop.absoluteString)
            #expect(await service.approvals.answer(card.id, with: .allowOnce))
            try await waitUntil { !service.approvals.isPending(card.id) }
        }
        let result = await opening.value
        #expect(result.status == .error && result.code == "navigationFailed" && service.approvals.pending.isEmpty)
        // Each allowed hop redirected again before it committed, so the tab shows no page, and the fourth site never joined the scope.
        #expect(session.siteScope == ["docs.example", "one.example", "two.example", "three.example"] && harness.host.agentTabs(of: session.id).first?.url == nil)
        await service.deleteSession(session.id)
    }

    @Test func callsWaitWhileTakenOverCountAgainstTheMessageAndBecomeStepsAndActivity() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let attached = try userTab(harness)
        let (session, runner, tools) = try await start(service, harness, attaching: [attached.id], mode: .askBeforeActing)
        // Each call is a step in the transcript and an entry in the activity log, with the site of the page it opened.
        #expect(await call(tools, "open_tab", ["url": "https://docs.example/"]).status == .ok)
        let step = try #require(session.items.compactMap { item -> AgentStep? in if case .step(let step) = item.kind { return step } else { return nil } }.last)
        #expect(step.tool == "open_tab" && step.sentence == catalogText("Opened a tab") && step.tabHandle == "t2" && step.status == .ok)
        let entry = try #require(service.activity.entries.last)
        #expect(entry.sessionID == session.id && entry.tool == "open_tab" && entry.site == "docs.example" && entry.decision == .auto)

        // While the user has taken the session over, a call waits until Hand Back.
        session.takeOver()
        var finished = false
        let held = Task {
            let result = await call(tools, "list_tabs")
            finished = true
            return result
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!finished && runner.activeToolCalls == 0)
        session.handBack()
        #expect(await held.value.status == .ok)

        // A message has 150 calls; the next one is refused with limitReached, and it is a step and an entry too.
        while session.callsLeftThisTurn > 0 { _ = await call(tools, "list_spaces") }
        let refused = await call(tools, "list_spaces")
        #expect(refused.status == .error && refused.code == "limitReached")
        #expect(service.activity.entries.filter { $0.sessionID == session.id && $0.event == .toolCall }.count == AgentLimits.toolCallsPerTurn + 1)
        #expect(session.items.filter { if case .step = $0.kind { return true } else { return false } }.count == AgentLimits.toolCallsPerTurn + 1)
        await service.deleteSession(session.id)
    }

    @Test func aCallWaitingOnACardIsWithdrawnAsDeniedWithNothingRunWhenItsTaskIsCancelled() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, _, tools) = try await start(service, harness, mode: .askBeforeActing)
        let waiting = Task { await call(tools, "open_tab", ["url": "https://shop.example/cart?d=1"]) }
        let card = try await waitingCard(service, of: session)
        let cancelledAt = ContinuousClock.now
        waiting.cancel()
        let result = await waiting.value
        #expect(ContinuousClock.now - cancelledAt < .seconds(1))
        #expect(result.status == .denied && result.code == "ended")
        try await waitUntil { !service.approvals.isPending(card.id) }
        guard case .ended? = service.approvals.outcomes[card.id] else { Issue.record("The card was not withdrawn as denied."); return }
        // Nothing opened, and a later Allow on the withdrawn card runs nothing.
        #expect(!(await service.approvals.answer(card.id, with: .allowOnce)))
        #expect(harness.host.openedOwners.isEmpty)
        try await waitUntil { session.toolState.runningCalls.isEmpty }

        await service.deleteSession(session.id)
    }

    @Test func stopAllAgentsAndDenyAndStopEndTheSessionsCallsAndCards() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, runner, tools) = try await start(service, harness, mode: .askBeforeActing)
        // Stop All Agents stops the turn, cancels the call that waits, and denies its card; nothing opens.
        let stopped = Task { await call(tools, "open_tab", ["url": "https://shop.example/cart?d=2"]) }
        let card = try await waitingCard(service, of: session)
        service.stopAllAgents()
        let stoppedResult = await stopped.value
        #expect(stoppedResult.status == .refused && stoppedResult.code == "stopped")
        #expect(!service.approvals.isPending(card.id) && harness.host.openedOwners.isEmpty && runner.stops == 1)
        // Deny and Stop on a session's card stops its turn, as its panel's Stop does.
        let denied = Task { await call(tools, "open_tab", ["url": "https://shop.example/cart?d=3"]) }
        let second = try await waitingCard(service, of: session)
        #expect(await service.approvals.answer(second.id, with: .denyAndStop))
        #expect(await denied.value.status != .ok)
        #expect(runner.stops == 2 && harness.host.openedOwners.isEmpty)
        await service.deleteSession(session.id)
    }

    @Test func aTabDraggedOutOfTheSessionsFolderIsTheUsersAndItsCardIsWithdrawn() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let attached = try userTab(harness)
        let (session, _, tools) = try await start(service, harness, attaching: [attached.id], mode: .askBeforeActing)
        let opened = await call(tools, "open_tab", ["url": "https://docs.example/"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let tabID = try #require(session.handles.tabs.id(for: handle))
        let navigation = Task { await call(tools, "navigate", ["tab": .string(handle), "url": "https://docs.example/unseen"]) }
        let card = try await waitingCard(service, of: session)
        harness.host.takeOver(tabID)
        // The card is withdrawn, the agent hears of the take-over, and its handle is refused from then on (P17).
        let withdrawn = await navigation.value
        #expect(withdrawn.status == .stale && withdrawn.text.contains("The user took over \(handle)"))
        #expect(!service.approvals.isPending(card.id))
        #expect(await call(tools, "read_text", ["tab": .string(handle)]).code == "P17")
        #expect(await call(tools, "navigate", ["tab": .string(handle), "action": "reload"]).code == "P17")
        await service.deleteSession(session.id)
        // The tab stays the user's after the session ends.
        #expect(harness.host.tabs.contains { $0.id == tabID })
    }

    @Test func aSessionAnOutsideClientStartedAuthenticatesSensitiveAllowsOrDeniesThemAtOnce() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let (session, _, tools) = try await start(service, harness, mode: .readOnly, origin: .outsideClient(grantID: UUID(), clientName: "agent", deniesApprovals: false))
        let opening = Task { await call(tools, "open_tab", ["url": "https://shop.example/?d=1"]) }
        let card = try await waitingCard(service, of: session)
        // The card and Touch ID name the client as Arch verified it, not the words of its task, which make the session's title.
        #expect(card.isOutsideClient && card.needsAuthentication && card.clientName == "agent" && session.title == "Read this")
        harness.authenticator.answer = false
        #expect(!(await service.approvals.answer(card.id, with: .allowOnce)))
        #expect(service.approvals.isPending(card.id))
        harness.authenticator.answer = true
        #expect(await service.approvals.answer(card.id, with: .allowOnce))
        #expect(await opening.value.status == .ok && harness.authenticator.count == 2)
        #expect(harness.authenticator.reasons == Array(repeating: "allow agent to open an address in a new agent tab", count: 2))
        #expect(service.activity.entries.last?.decision == .approvedWithTouchID)
        await service.deleteSession(session.id)

        // With --deny-approvals, each card is denied at once and none opens.
        let (denying, _, denyingTools) = try await start(service, harness, mode: .readOnly, origin: .outsideClient(grantID: UUID(), clientName: "agent", deniesApprovals: true))
        let result = await call(denyingTools, "open_tab", ["url": "https://shop.example/?d=2"])
        #expect(result.status == .denied && result.code == "ended" && result.text.contains("approvals denied"))
        #expect(service.approvals.pending.isEmpty && harness.host.openedOwners.count == 1)
        await service.deleteSession(denying.id)
    }

    @Test func hopsAreCheckedPerNavigationNotPerCall() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let slow = try #require(URL(string: "https://docs.example/slow"))
        harness.host.hangingAddresses = [slow]
        let (session, _, tools) = try await start(service, harness, task: "Open https://docs.example/ and https://docs.example/slow", mode: .readOnly)
        let opened = await call(tools, "open_tab", ["url": "https://docs.example/"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let tabID = try #require(session.handles.tabs.id(for: handle))

        // While a written address's navigation loads, a popup the page opens is no hop of it and opens without a card; a redirect off the scope is, and the call asks.
        let loading = Task { await call(tools, "navigate", ["tab": .string(handle), "url": .string(slow.absoluteString)]) }
        try await waitUntil { session.toolState.writtenLoads[tabID].map { $0.url == slow && $0.documentID != nil } == true }
        #expect(harness.host.openPopup(from: tabID, at: URL(string: "https://tracker.example/window")!) != nil)
        #expect(service.approvals.pending.isEmpty)
        #expect(!harness.host.redirect(tabID, to: URL(string: "https://tracker.example/hop?d=1")!))
        let card = try await waitingCard(service, of: session)
        #expect(card.action == "Follow a redirect in \(handle) to a site outside the session's scope" && card.addressQuestion?.unseenParts == [.host, .path, .query])
        #expect(await service.approvals.answer(card.id, with: .deny))
        #expect(await loading.value.status == .denied)

        // Once no call waits, as after Stop, the navigation goes on, but a hop of it off the scope is refused without a card, and the agent hears so.
        let again = Task { await call(tools, "navigate", ["tab": .string(handle), "url": .string(slow.absoluteString)]) }
        try await waitUntil { session.toolState.writtenLoads[tabID].map { $0.url == slow && $0.documentID != nil } == true }
        session.stop()
        _ = await again.value
        #expect(!harness.host.redirect(tabID, to: URL(string: "https://tracker.example/later?d=2")!))
        #expect(service.approvals.pending.isEmpty && session.toolState.writtenLoads[tabID] == nil)
        #expect(session.toolState.events.contains { $0.tabID == tabID && $0.kind == .hopStopped })

        // A written address's navigation that committed is over, so a redirect of the page's next navigation goes on.
        #expect(await call(tools, "navigate", ["tab": .string(handle), "url": "https://docs.example/"]).status == .ok)
        #expect(harness.host.redirect(tabID, to: URL(string: "https://tracker.example/next")!))
        #expect(session.toolState.writtenLoads[tabID] == nil && service.approvals.pending.isEmpty)
        await service.deleteSession(session.id)
    }

    @Test func aCallOpensNoCardOnceTheUserTookTheSessionOverAndTakeOverOnACardPausesIt() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let slow = try #require(URL(string: "https://docs.example/slow"))
        harness.host.hangingAddresses = [slow]
        let (session, _, tools) = try await start(service, harness, task: "Open https://docs.example/ and https://docs.example/slow", mode: .actInAgentTabs)
        let opened = await call(tools, "open_tab", ["url": "https://docs.example/"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let tabID = try #require(session.handles.tabs.id(for: handle))
        // A hop held after the user took the session over asks nothing: the call ends without a card.
        let loading = Task { await call(tools, "navigate", ["tab": .string(handle), "url": .string(slow.absoluteString)]) }
        try await waitUntil { session.toolState.writtenLoads[tabID].map { $0.url == slow && $0.documentID != nil } == true }
        session.takeOver()
        #expect(!harness.host.redirect(tabID, to: URL(string: "https://tracker.example/hop?d=1")!))
        let held = await loading.value
        #expect(held.status == .refused && held.code == "stopped" && service.approvals.pending.isEmpty)
        session.handBack()

        // Take Over on a card shows its tab and pauses the session, as the panel's Take Over does.
        let navigation = Task { await call(tools, "navigate", ["tab": .string(handle), "url": "https://docs.example/plans?d=1"]) }
        let card = try await waitingCard(service, of: session)
        #expect(await service.approvals.answer(card.id, with: .takeOver))
        #expect(await navigation.value.status != .ok)
        #expect(session.isTakenOver && harness.host.shownTabIDs.last == tabID)
        session.handBack()
        await service.deleteSession(session.id)
    }

    @Test func aCallsCardsShareItsDeadlineAndATabOpensOnlyWithinTheLimitAfterItsCard() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        let start = harness.now
        let written = try #require(URL(string: "https://docs.example/out?d=1"))
        harness.host.redirects[written] = URL(string: "https://tracker.example/hop")
        let attached = try userTab(harness)
        let (session, _, tools) = try await self.start(service, harness, attaching: [attached.id], mode: .readOnly)
        // A hop's card after the written address's card waits only for what is left of the call's time.
        let opening = Task { await call(tools, "open_tab", ["url": .string(written.absoluteString)]) }
        let first = try await waitingCard(service, of: session)
        #expect(first.deadline == start.addingTimeInterval(service.sessionQuestionWindow))
        harness.now = start.addingTimeInterval(100)
        #expect(await service.approvals.answer(first.id, with: .allowOnce))
        try await waitUntil { service.approvals.pending.contains { $0.ownerID == session.id && $0.id != first.id } }
        let hop = try #require(service.approvals.pending.first { $0.ownerID == session.id })
        #expect(hop.deadline == first.deadline)
        #expect(await service.approvals.answer(hop.id, with: .deny))
        _ = await opening.value
        harness.now = start

        // Other calls may fill the agent tabs while a card waits: the tab opens only if there is still room for it.
        while harness.host.agentTabs(of: session.id).count < AgentLimits.agentTabs - 1 { _ = await call(tools, "open_tab", ["url": "https://docs.example/"]) }
        let one = Task { await call(tools, "open_tab", ["url": "https://docs.example/a?d=1"]) }
        let oneCard = try await waitingCard(service, of: session)
        let two = Task { await call(tools, "open_tab", ["url": "https://docs.example/b?d=2"]) }
        try await waitUntil { service.approvals.pending.filter { $0.ownerID == session.id }.count == 2 }
        let twoCard = try #require(service.approvals.pending.first { $0.ownerID == session.id && $0.id != oneCard.id })
        #expect(await service.approvals.answer(oneCard.id, with: .allowOnce))
        #expect(await one.value.status == .ok)
        #expect(await service.approvals.answer(twoCard.id, with: .allowOnce))
        let full = await two.value
        #expect(full.code == "limitReached" && harness.host.agentTabs(of: session.id).count == AgentLimits.agentTabs)
        #expect(service.activity.entries.last?.decision == .approved)
        await service.deleteSession(session.id)
    }
}
