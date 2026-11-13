// The cards that wait for the user (docs/agents.md, Approval interface; Tests ▸ Approvals): grouping per page, withdrawal when the page moves on, also before its document finishes, denial on timeout, Touch ID for outside clients' sensitive Allow and Share, the warning line on cards whose text names a secret, ended cards leaving memory, `approvalPending` and `approval_wait`, the tools that wait for the user, the cards a page's download or link to another app opens, one download card per tab, and, through the service and the socket, the ends that deny waiting cards: Stop All Agents, revocation, the client leaving, and quit, and the activity log and panel step of a call that goes on after `approvalPending`; and the posted-click check on a real button.
import AgentControl
import AppKit
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct ApprovalTests {
    nonisolated private static let owner = UUID()

    private static func card(tab: UUID? = UUID(), document: Int? = 0, site: String? = "shop.example", sensitive: Bool = false, outside: Bool = true, deadline: TimeInterval = 60,
                             offers: [AgentApprovalAnswer] = [.allowOnce, .allowOnPage, .allowOnSite, .deny], says: String? = nil, owner: UUID = owner) -> AgentApproval {
        AgentApproval(ownerID: owner, clientName: "claude in Terminal", isOutsideClient: outside, kind: .step, isSensitive: sensitive, offers: offers, action: "Click \u{201C}Next\u{201D} on shop.example",
                      tabID: tab, site: site, agentSays: says, document: document, createdAt: Date(), deadline: Date().addingTimeInterval(deadline))
    }

    /// Opens a card and returns the task that waits for its answer.
    private static func open(_ card: AgentApproval, in approvals: AgentApprovals) async -> Task<AgentApprovalAnswer, Never> {
        let task = Task { await approvals.request(card) }
        for _ in 0 ..< 50 where !approvals.isPending(card.id) { await Task.yield() }
        return task
    }

    @Test func cardsGroupPerPageAndAPagesAllowanceAnswersItsOtherCards() async {
        let approvals = AgentApprovals()
        let tab = UUID(), other = UUID()
        let first = Self.card(tab: tab), second = Self.card(tab: tab), elsewhere = Self.card(tab: other, site: "news.example"), sensitive = Self.card(tab: tab, sensitive: true, offers: [.allowOnce, .deny])
        let tasks = [await Self.open(first, in: approvals), await Self.open(second, in: approvals), await Self.open(elsewhere, in: approvals), await Self.open(sensitive, in: approvals)]
        #expect(approvals.groups(of: Self.owner).map { $0.map(\.id) } == [[first.id, second.id, sensitive.id], [elsewhere.id]])
        #expect(await approvals.answer(first.id, with: .allowOnPage))
        #expect(await tasks[0].value == .allowOnPage)
        #expect(await tasks[1].value == .allowOnPage)
        // Another page's card, and a sensitive card that offers no allowance, still wait.
        #expect(approvals.pending.map(\.id) == [elsewhere.id, sensitive.id])
        #expect(await approvals.answer(elsewhere.id, with: .deny))
        #expect(await tasks[2].value == .deny)
        approvals.end(because: "Arch quit.")
        #expect(await tasks[3].value == .ended("Arch quit."))
        #expect(approvals.outcomes[sensitive.id] == .ended("Arch quit."))
    }

    @Test func aCardIsWithdrawnWhenItsPageMovesOnAndDeniedWhenNobodyAnswers() async throws {
        let approvals = AgentApprovals()
        let tab = UUID()
        let page = Self.card(tab: tab, document: 1), handed = Self.card(tab: tab, document: nil), late = Self.card(tab: UUID(), deadline: 0.2)
        let pageTask = await Self.open(page, in: approvals), handedTask = await Self.open(handed, in: approvals), lateTask = await Self.open(late, in: approvals)
        // The same document keeps the card; the tab's next document withdraws it, but not a card the page moving on does not end.
        approvals.withdraw(tab: tab, owner: Self.owner, document: 1)
        #expect(approvals.isPending(page.id))
        approvals.withdraw(tab: tab, owner: Self.owner, document: 2)
        #expect(await pageTask.value == .withdrawn)
        #expect(approvals.isPending(handed.id))
        // The tab closing withdraws every card about it.
        approvals.withdraw(tab: tab, owner: Self.owner, document: nil)
        #expect(await handedTask.value == .withdrawn)
        #expect(await lateTask.value == .timedOut)
        #expect(approvals.pending.isEmpty)
        // An answer after the end counts for nothing, and an ended card, with its capture, leaves memory.
        #expect(!(await approvals.answer(late.id, with: .allowOnce)))
        #expect(approvals.approval(page.id) == nil && approvals.approval(late.id) == nil)
    }

    @Test func endedCardsKeepOnlyTheLatestOutcomes() async {
        let approvals = AgentApprovals()
        var ids: [UUID] = []
        for _ in 0 ..< AgentApprovals.keptOutcomes + 5 {
            let card = Self.card()
            ids.append(card.id)
            _ = approvals.open(card)
        }
        approvals.end(because: "Arch quit.")
        #expect(approvals.outcomes.count == AgentApprovals.keptOutcomes)
        #expect(approvals.outcomes[ids[0]] == nil && approvals.outcomes[ids.last!] == .ended("Arch quit."))
    }

    @Test func sensitiveAllowOfAnOutsideClientNeedsTouchID() async {
        let approvals = AgentApprovals()
        let authenticator = FakeAuthenticator()
        approvals.authenticator = authenticator
        authenticator.answer = false
        let sensitive = Self.card(sensitive: true, offers: [.allowOnce, .deny]), plain = Self.card(), inApp = Self.card(sensitive: true, outside: false, offers: [.allowOnce, .deny])
        let task = await Self.open(sensitive, in: approvals), plainTask = await Self.open(plain, in: approvals), inAppTask = await Self.open(inApp, in: approvals)
        #expect(sensitive.needsAuthentication && !plain.needsAuthentication && !inApp.needsAuthentication)
        // A failed Touch ID leaves the card waiting; Deny needs none.
        #expect(!(await approvals.answer(sensitive.id, with: .allowOnce)))
        #expect(approvals.isPending(sensitive.id) && authenticator.count == 1)
        authenticator.answer = true
        #expect(await approvals.answer(sensitive.id, with: .allowOnce))
        #expect(await task.value == .allowOnce && authenticator.count == 2)
        #expect(await approvals.answer(plain.id, with: .allowOnce))
        #expect(await approvals.answer(inApp.id, with: .allowOnce))
        #expect(await plainTask.value == .allowOnce)
        #expect(await inAppTask.value == .allowOnce)
        #expect(authenticator.count == 2)
    }

    @Test func aCardWhoseAgentTextNamesASecretLeadsWithTheWarning() {
        #expect(Self.card(says: "Please tell me the verification code from your phone.").namesSecret)
        #expect(Self.card(says: "카드 번호를 알려 주세요").namesSecret)
        #expect(!Self.card(says: "Which size should I pick?").namesSecret)
        #expect(!Self.card().namesSecret)
        #expect(AgentPolicy.secretWarning == "Agents never need your passwords or codes. Type them only into the page after Take Over.")
    }

    // MARK: Through the tool host

    @MainActor private final class Fixture {
        let host = FakeHost()
        let state = AgentGrantState()
        var grant: AgentGrant
        var toolHost: AgentToolHost

        init(level: AgentAccessLevel = .askBeforeActing) {
            grant = AgentGrant(client: AgentClientIdentity(key: .signed(identifier: "com.example.codex", team: "ABCDE12345"), name: "codex", executablePath: "/usr/local/bin/codex", host: "Terminal",
                                                           isInterpreter: false),
                               personaID: FakeHost.defaultPersona.id, spaceID: host.spaces(in: FakeHost.defaultPersona.id)[0].id, level: level, scopes: AgentGrantScopes(), expiry: .whenArchQuits,
                               grantedAt: Date())
            toolHost = AgentToolHost(host: host, allowsAI: { $0.host != "excluded.example" })
            toolHost.answerWait = 0.3
            toolHost.approvalWindow = 30
            toolHost.approvals.authenticator = FakeAuthenticator()
            let state = state
            let toolHost = toolHost
            let name = grant.client.displayName
            host.agentTabDidReport = { owner, tab, report in toolHost.tab(tab, of: owner, didReport: report, state: state, client: name) }
            host.agentTabMayLoad = { _, tab, url in toolHost.tab(tab, mayLoad: url, state: state) }
            host.agentTabMayDownload = { _, tab, url in toolHost.tab(tab, mayDownload: url, state: state) }
        }

        func call(_ name: String, _ arguments: [String: AgentJSON] = [:]) async -> AgentToolResult {
            await toolHost.run(AgentToolCall(name: name, arguments: arguments), for: grant, state: state).result
        }

        func waitForCard() async throws -> AgentApproval {
            try await waitUntil { !self.toolHost.approvals.pending.isEmpty }
            return try #require(toolHost.approvals.pending.first)
        }
    }

    @Test func aCallThatWaitsAnswersApprovalPendingAndApprovalWaitTakesItsResult() async throws {
        let fixture = Fixture()
        let first = await fixture.call("request_approval", ["summary": "Send the reply to Dana", "kind": "send"])
        #expect(first.status == .approvalPending && first.structured?["approval"] == "a1")
        #expect(first.text == "Waiting for the user in Arch; call approval_wait with approval a1.")
        let card = try #require(fixture.toolHost.approvals.pending.first)
        #expect(card.isSensitive && card.rules == [.p15] && card.agentSays == "Send the reply to Dana" && card.action == "Approve the agent's request to send a message")
        #expect(card.offers == [.allowOnce, .deny, .denyAndStop, .reply(""), .takeOver])
        // Still waiting after another answer wait.
        #expect(await fixture.call("approval_wait", ["approval": "a1"]).status == .approvalPending)
        #expect(await fixture.toolHost.approvals.answer(card.id, with: .allowOnce))
        let done = await fixture.call("approval_wait", ["approval": "a1"])
        #expect(done.status == .ok && done.structured?["decision"] == "approved" && done.text == "The user approved: Send the reply to Dana")
        // A handle that waits for nothing, now or ever.
        #expect(await fixture.call("approval_wait", ["approval": "a1"]).code == "notFound")
        #expect(await fixture.call("approval_wait", ["approval": "a9"]).code == "notFound")
        // Read Only refuses request_approval without a card.
        let readOnly = Fixture(level: .readOnly)
        let refused = await readOnly.call("request_approval", ["summary": "Delete it", "kind": "delete"])
        #expect(refused.status == .refused && refused.code == AgentPolicy.readOnlyCode && readOnly.toolHost.approvals.pending.isEmpty)
    }

    @Test func theToolsThatWaitForTheUser() async throws {
        let fixture = Fixture()
        fixture.toolHost.answerWait = 10
        // ask_user, with the warning line when the question names a secret.
        async let asked = fixture.call("ask_user", ["question": "What is your one-time password?", "choices": ["Skip"]])
        let question = try await fixture.waitForCard()
        #expect(question.namesSecret && question.kind == .question(["Skip"]))
        await fixture.toolHost.approvals.answer(question.id, with: .answer("I will type it myself"))
        #expect(await asked.text == "The user answered: I will type it myself")

        // request_tab shares the tab the user picks, for reading or acting, and it is listed as shared. An outside client's Share counts only after Touch ID or the login password.
        let userTab = AgentTabInfo(id: UUID(), spaceID: fixture.grant.spaceID, title: "Inbox", url: URL(string: "https://mail.example/inbox?id=9"), isLoading: false, engine: .webKit)
        fixture.host.tabs.append(userTab)
        fixture.host.userTabIDs = [userTab.id]
        fixture.host.pages[userTab.url!] = ("Inbox", "Three new messages.")
        async let requested = fixture.call("request_tab", ["reason": "To read the latest message", "access": "read"])
        let pick = try await fixture.waitForCard()
        #expect(pick.kind == .requestTab([AgentTabChoice(id: userTab.id, title: "Inbox", host: "mail.example")], acting: false))
        #expect(pick.needsAuthentication(for: .tab(userTab.id)) && !pick.needsAuthentication(for: .deny))
        let authenticator = try #require(fixture.toolHost.approvals.authenticator as? FakeAuthenticator)
        authenticator.answer = false
        #expect(!(await fixture.toolHost.approvals.answer(pick.id, with: .tab(userTab.id))))
        #expect(fixture.toolHost.approvals.isPending(pick.id))
        authenticator.answer = true
        #expect(await fixture.toolHost.approvals.answer(pick.id, with: .tab(userTab.id)))
        #expect(authenticator.count == 2)
        let shared = await requested
        #expect(shared.status == .ok && shared.structured?["tab"] == "t1" && shared.structured?["access"] == "read")
        #expect(await fixture.call("list_tabs", ["scope": "shared"]).text.contains("t1  <untrusted"))
        #expect(await fixture.call("read_text", ["tab": "t1"]).text.contains("Three new messages."))
        // A tab shared for reading refuses actions.
        let action = await fixture.call("scroll", ["tab": "t1", "direction": "down"])
        #expect(action.status != .ok)

        // hand_to_user shows the tab and waits for Done; a denial of request_tab shares nothing.
        let opened = await fixture.call("open_tab", ["url": "https://docs.example/sign-in"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        async let handed = fixture.call("hand_to_user", ["tab": .string(handle), "reason": "sign_in", "message": "Please sign in, then choose Done."])
        let hand = try await fixture.waitForCard()
        #expect(hand.kind == .handToUser("sign_in") && hand.document == nil && fixture.host.shownTabIDs.last == hand.tabID)
        await fixture.toolHost.approvals.answer(hand.id, with: .done("Signed in"))
        let finished = await handed
        #expect(finished.status == .ok && finished.text == "The user finished in \(handle) and wrote: Signed in")
        async let refused = fixture.call("request_tab", ["reason": "More", "access": "act"])
        await fixture.toolHost.approvals.answer(try await fixture.waitForCard().id, with: .deny)
        #expect(await refused.status == .denied)
    }

    @Test func aPagesDownloadAndLinkToAnotherAppAskOnCardsOfTheirOwn() async throws {
        let fixture = Fixture()
        let opened = await fixture.call("open_tab", ["url": "https://docs.example/files"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let tabID = try #require(fixture.state.handles.tabs.id(for: handle))
        let file = URL(string: "https://docs.example/files/report.pdf?token=1")!
        // P6: refused until the user answers; Allow Once lets that address download once, and the tab asks for it again.
        #expect(!fixture.toolHost.tab(tabID, mayDownload: file, state: fixture.state))
        fixture.host.report(.downloadAsked(file), in: tabID)
        let download = try await fixture.waitForCard()
        #expect(download.kind == .download && download.rules == [.p6] && !download.isSensitive && download.offers == [.allowOnce, .allowDownloadsFromSite, .deny])
        #expect(download.exactText == file.absoluteString && download.action == "Download \u{201C}report.pdf\u{201D} from docs.example in \(handle)")
        await fixture.toolHost.approvals.answer(download.id, with: .allowOnce)
        try await waitUntil { fixture.host.navigations.contains(.load(file)) }
        #expect(fixture.toolHost.tab(tabID, mayDownload: file, state: fixture.state))
        #expect(!fixture.toolHost.tab(tabID, mayDownload: file, state: fixture.state))
        // Allow Downloads from This Site covers the next one from it. While a download card waits, the page's further downloads get no card of their own and do not start.
        fixture.host.report(.downloadAsked(file), in: tabID)
        let waiting = try await fixture.waitForCard()
        for number in 1 ... 3 { fixture.host.report(.downloadAsked(URL(string: "https://docs.example/files/file?n=\(number)")!), in: tabID) }
        #expect(fixture.toolHost.approvals.pending.map(\.id) == [waiting.id])
        // The agent hears of each card and of each answer, and of the downloads that got none.
        let downloads = await fixture.call("list_tabs")
        #expect(downloads.text.contains("which waits for the user in Arch (P6)") && downloads.text.contains("The user allowed the download in \(handle). It starts again."))
        #expect(downloads.text.contains("A page in \(handle) started another download while one waits for the user, so Arch did not start it."))
        await fixture.toolHost.approvals.answer(waiting.id, with: .allowDownloadsFromSite)
        try await waitUntil { fixture.state.downloadSites.contains("docs.example") }
        #expect(fixture.toolHost.tab(tabID, mayDownload: URL(string: "https://docs.example/other.zip")!, state: fixture.state))
        #expect(!fixture.toolHost.tab(tabID, mayDownload: URL(string: "https://elsewhere.example/other.zip")!, state: fixture.state))
        // P11: a sensitive card naming the app; the link opens only after Allow.
        let mail = URL(string: "mailto:dana@example.org")!
        fixture.host.report(.externalAppAsked(mail), in: tabID)
        // A page that asks again while the card waits gets no second card.
        fixture.host.report(.externalAppAsked(mail), in: tabID)
        let external = try await fixture.waitForCard()
        #expect(fixture.toolHost.approvals.pending.count == 1)
        #expect(external.kind == .externalApp("Mail") && external.isSensitive && external.needsAuthentication)
        #expect(fixture.host.openedExternally.isEmpty)
        await fixture.toolHost.approvals.answer(external.id, with: .allowOnce)
        try await waitUntil { fixture.host.openedExternally == [mail] }
        // Never the full addresses.
        let events = await fixture.call("list_tabs")
        #expect(events.text.contains("The user opened the link from \(handle) in Mail."))
        #expect(!events.text.contains("token=1") && !events.text.contains("dana@example.org") && !downloads.text.contains("token=1"))
    }

    @Test func aRequestedApprovalEndsWhenThePageChangesOnDenyAndStopAndOnAReply() async throws {
        // Actions in Ask Before Acting are tested on the page script's fixtures (PageScriptTests); here request_approval about a tab stands in for a card the page withdraws.
        let fixture = Fixture()
        fixture.toolHost.answerWait = 10
        let opened = await fixture.call("open_tab", ["url": "https://docs.example/guide"])
        let handle = try #require(opened.structured?["tab"]?.stringValue)
        let tabID = try #require(fixture.state.handles.tabs.id(for: handle))
        async let approval = fixture.call("request_approval", ["summary": "Submit the form", "kind": "submit", "tab": .string(handle)])
        let card = try await fixture.waitForCard()
        // The tab's address changed when its document committed, and again when it finished loading.
        #expect(card.tabID == tabID && card.document == 2 && fixture.state.activity(of: tabID).documents == 1)
        // The page moves on to a document that commits and never finishes: the card goes, and the call is stale.
        let next = URL(string: "https://docs.example/other")!
        fixture.host.committingAddresses.insert(next)
        fixture.host.navigate(tabID, .load(next))
        #expect(await approval.status == .stale)
        #expect(fixture.state.activity(of: tabID).documents == 1)
        // Deny and Stop stops the client.
        var stopped: [UUID] = []
        fixture.toolHost.stopClient = { stopped.append($0) }
        async let second = fixture.call("request_approval", ["summary": "Delete the draft", "kind": "delete", "tab": .string(handle)])
        await fixture.toolHost.approvals.answer(try await fixture.waitForCard().id, with: .denyAndStop)
        #expect(await second.status == .denied && stopped == [fixture.grant.id])
        // A reply is the user's instruction.
        async let third = fixture.call("request_approval", ["summary": "Buy the blue one", "kind": "purchase"])
        await fixture.toolHost.approvals.answer(try await fixture.waitForCard().id, with: .reply("Buy the red one"))
        let replied = await third
        #expect(replied.status == .ok && replied.structured?["decision"] == "instruction" && replied.structured?["reply"] == "Buy the red one")
    }

    // MARK: Through the service

    @Test func stopAllAgentsRevocationTheClientLeavingAndQuitDenyWaitingCards() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.defaultPersona.id), level: .askBeforeActing, duration: .day)]

        // Stop All Agents: the waiting card ends, its client's connection closes, and the grant stays.
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        _ = try await client.callTool("session_info")
        let grant = try #require(service.grants.first)
        let waiting = Task { try? await client.callTool("request_approval", ["summary": "Post the comment", "kind": "send"]) }
        try await waitUntil { !service.approvals.pending.isEmpty }
        let first = try #require(service.approvals.pending.first)
        #expect(harness.host.shownPanels == [grant.id])
        #expect(service.panel.owners[grant.id] == AgentPanelOwner(name: "agent in Agent", access: "Ask Before Acting", place: "Default / Home"))
        service.stopAllAgents()
        #expect(service.approvals.outcomes[first.id] == .ended("The user stopped all agents in Arch."))
        _ = await waiting.value
        #expect(service.grants.map(\.id) == [grant.id])

        // The client leaving ends the cards of its connection: it stops waiting for the answer, and its connection closes.
        var leaving: TestClient? = try TestClient(harness.location)
        _ = try await leaving?.hello()
        _ = try? await leaving?.callTool("request_approval", ["summary": "Send it", "kind": "send"], timeout: 0.5)
        let second = try #require(service.approvals.pending.first)
        leaving = nil
        try await waitUntil { service.approvals.outcomes[second.id] != nil }
        #expect(service.approvals.outcomes[second.id] == .ended("The client left before the user answered."))

        // Revocation ends the grant's cards.
        let third = try TestClient(harness.location)
        _ = try await third.hello()
        let revoked = Task { try? await third.callTool("request_approval", ["summary": "Delete it", "kind": "delete"]) }
        try await waitUntil { !service.approvals.pending.isEmpty }
        let card = try #require(service.approvals.pending.first)
        service.revoke(grant.id)
        #expect(service.approvals.outcomes[card.id] == .ended("The user revoked this client's access in Arch."))
        _ = await revoked.value

        // Quit ends whatever still waits, such as a card a page's download opened.
        let pageCard = AgentApproval(ownerID: grant.id, clientName: "agent", isOutsideClient: true, kind: .download, isSensitive: false, offers: [.allowOnce, .deny], action: "Download",
                                     createdAt: Date(), deadline: Date().addingTimeInterval(60))
        let quitting = Task { await service.approvals.request(pageCard) }
        try await waitUntil { service.approvals.isPending(pageCard.id) }
        service.stop()
        #expect(await quitting.value == .ended("Arch quit."))
        // The service records each ended call before the harness goes.
        try await waitUntil { service.activity.entries.filter { $0.tool == "request_approval" }.count == 3 }
        #expect(service.activity.entries.filter { $0.tool == "request_approval" }.allSatisfy { $0.decision == .denied && $0.outcome == "denied" })
    }

    @Test func aCallThatGoesOnAfterApprovalPendingRecordsItsOwnEntryAndStep() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.answerWait = 0.3
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.defaultPersona.id), level: .askBeforeActing, duration: .day)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        let first = try await client.callTool("request_approval", ["summary": "Send the reply", "kind": "send"])
        #expect(first.status == .approvalPending)
        let grant = try #require(service.grants.first)
        let card = try #require(service.approvals.pending.first)
        #expect(await service.approvals.answer(card.id, with: .allowOnce))
        // The call records what it did when it ends, with the user's decision, whether or not the client asks for its result.
        try await waitUntil { service.activity.entries.contains { $0.tool == "request_approval" && $0.outcome == "ok" } }
        let entries = service.activity.entries.filter { $0.tool == "request_approval" }
        #expect(entries.map(\.decision) == [.pending, .approvedWithTouchID] && entries.map(\.outcome) == ["approvalPending", "ok"])
        #expect(service.panel.steps[grant.id]?.last?.sentence == "You approved: Send the reply")
        // approval_wait takes the result, and the log has it as a plain read.
        #expect(try await client.callTool("approval_wait", ["approval": "a1"]).status == .ok)
        try await waitUntil { service.activity.entries.contains { $0.tool == "approval_wait" } }
        #expect(service.activity.entries.last { $0.tool == "approval_wait" }?.decision == .auto)
        #expect(service.activity.entries.filter { $0.tool == "request_approval" }.count == 2 && service.panel.steps[grant.id]?.count == 1)
    }
}

/// The click check on sensitive cards' Allow, Share, Done, and the grant sheet's Allow (docs/agents.md, Approval interface): a click that another program of this user posted names that program as its source, which Arch reads by its running code and refuses unless it is one of the system's programs that click for a person; a click whose source is no process, Arch, or another user's process counts; and only the click the button tracks counts, never an accessibility press or `performClick`, whatever event came last.
@MainActor @Suite struct PointerCheckTests {
    @Test func clicksPostedByOtherProgramsAreRefusedByTheirRunningCode() {
        let me = getuid()
        let sources: [pid_t: AgentPointerCheck.Source] = [
            // Programs of this user: one Apple did not sign, whatever path it was started with, Apple's scripting hosts, and the system's own programs that click for a person.
            501: .init(userID: me, appleIdentifier: nil), 502: .init(userID: me, appleIdentifier: "com.apple.osascript"), 503: .init(userID: me, appleIdentifier: "com.apple.systemevents"),
            504: .init(userID: me, appleIdentifier: "com.apple.ScriptEditor2"), 505: .init(userID: me, appleIdentifier: "com.apple.automatorCLI"),
            510: .init(userID: me, appleIdentifier: "com.apple.universalcontrol"), 511: .init(userID: me, appleIdentifier: "com.apple.VoiceOver"),
            // Another user's processes, such as the window server's and the HID service's.
            520: .init(userID: 88, appleIdentifier: nil), 521: .init(userID: 0, appleIdentifier: nil),
        ]
        let read: (pid_t) -> AgentPointerCheck.Source? = { sources[$0] }
        for source in [501, 502, 503, 504, 505] as [pid_t] { #expect(AgentPointerCheck.isPostedByAnotherProgram(source: source, read: read), "\(source)") }
        for source in [510, 511, 520, 521] as [pid_t] { #expect(!AgentPointerCheck.isPostedByAnotherProgram(source: source, read: read), "\(source)") }
        // No source and Arch itself count; a source that cannot be read, as one that exited after it posted, does not.
        #expect(!AgentPointerCheck.isPostedByAnotherProgram(source: 0, read: read))
        let anyProgram: (pid_t) -> AgentPointerCheck.Source? = { _ in .init(userID: me, appleIdentifier: nil) }
        #expect(!AgentPointerCheck.isPostedByAnotherProgram(source: getpid(), read: anyProgram))
        #expect(AgentPointerCheck.isPostedByAnotherProgram(source: 600, read: read))
    }

    @Test func theSystemsReaderReadsTheRunningCode() throws {
        // This test process: this user's, and not signed by Apple. A process of another user, launchd, gives its owner only.
        let own = try #require(AgentPointerCheck.readSource(getpid()))
        #expect(own.userID == getuid() && own.appleIdentifier == nil)
        #expect(AgentPointerCheck.readSource(1)?.userID == 0)
        #expect(AgentPointerCheck.readSource(pid_t(Int32.max)) == nil)
    }

    @Test func onlyTheClickTheButtonTracksCounts() async throws {
        // The button reads the app's current event; its tracking loop, which takes events from the window server, is regression check 61's.
        _ = NSApplication.shared
        var pressed = 0
        let button = AgentPointerButton(title: "Allow", requiresPointer: true) { pressed += 1 }
        let coordinator = button.makeCoordinator()
        let view = AgentPointerNSButton(title: "Allow", target: coordinator, action: #selector(AgentPointerButton.Coordinator.press(_:)))
        // A window that never shows, which the events name.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 20, y: 20, width: 100, height: 30)
        // An accessibility press and performClick send the action without a mouse-down the button tracks, so they press nothing, whatever event the app handled last, such as a mouse-up from a real click elsewhere in Arch.
        view.performClick(nil)
        _ = view.accessibilityPerformPress()
        #expect(pressed == 0 && !view.isPressedByPointer)
        // A click counts only as the mouse-down the button tracks, in its window and within its bounds, with its mouse-up.
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 50, y: 30), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 30), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 190, y: 90), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let own: (pid_t) -> AgentPointerCheck.Source? = { _ in .init(userID: getuid(), appleIdentifier: nil) }
        #expect(AgentPointerCheck.isPointerClick(down: down, up: up, in: view, read: own))
        #expect(!AgentPointerCheck.isPointerClick(down: outside, up: up, in: view, read: own))
        #expect(!AgentPointerCheck.isPointerClick(down: nil, up: up, in: view, read: own))
        #expect(!AgentPointerCheck.isPointerClick(down: up, up: up, in: view, read: own))
        withExtendedLifetime(coordinator) {}
    }
}
