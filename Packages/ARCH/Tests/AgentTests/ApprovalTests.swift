// The cards that wait for the user (docs/agents.md, Approval interface; Tests ▸ Approvals): grouping per page, withdrawal when the page moves on, also before its document finishes, denial on timeout, Touch ID for outside clients' sensitive Allow and Share, the warning line on cards whose text names a secret, ended cards leaving memory, `approvalPending` and `approval_wait`, the tools that wait for the user, the cards a page's download or link to another app opens, one download card per tab, and, through the service and the socket, the ends that deny waiting cards: Stop All Agents, revocation, the client leaving, and quit, a client's `tools/cancel` of a call and of an `approval_wait`, which withdraws the card of the call it waits on, the connected state of a grant allowed after its only call was cancelled, and the activity log and panel step of a call that goes on after `approvalPending`; and the posted-click check on a real button.
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
        var delivered: [UUID: AgentApprovalAnswer] = [:]
        for _ in 0 ..< AgentApprovals.keptOutcomes + 5 {
            let card = Self.card()
            ids.append(card.id)
            approvals.open(card) { delivered[card.id] = $0 }
        }
        approvals.end(because: "Arch quit.")
        #expect(ids.allSatisfy { delivered[$0] == .ended("Arch quit.") })
        #expect(approvals.outcomes.count == AgentApprovals.keptOutcomes)
        #expect(approvals.outcomes[ids[0]] == nil && approvals.outcomes[ids.last!] == .ended("Arch quit."))
    }

    @Test func draftsBelongToTheirPendingQuestionAndAreClearedWhenItEnds() async {
        let approvals = AgentApprovals()
        var first = Self.card(), second = Self.card()
        first.kind = .question([])
        second.kind = .question(["Other"])
        let firstTask = await Self.open(first, in: approvals)
        let secondTask = await Self.open(second, in: approvals)
        approvals.setDraftAnswer("Partial answer", to: first.id)
        approvals.setDraftAnswer("Other draft", to: second.id)
        #expect(approvals.draftAnswer(to: first.id) == "Partial answer")
        #expect(approvals.draftAnswer(to: second.id) == "Other draft")
        #expect(approvals.isPending(first.id) && approvals.isPending(second.id))
        _ = await approvals.answer(first.id, with: .answer("Submitted text"))
        #expect(await firstTask.value == .answer("Submitted text"))
        approvals.setDraftAnswer("Late edit", to: first.id)
        #expect(approvals.draftAnswer(to: first.id).isEmpty)
        #expect(approvals.draftAnswer(to: second.id) == "Other draft")
        approvals.end(second.id, because: "Stopped")
        #expect(await secondTask.value == .ended("Stopped"))
        #expect(approvals.draftAnswer(to: second.id).isEmpty)
    }

    @Test func endedCardReleasesItsCaptureBeforeTheDeadline() {
        let approvals = AgentApprovals()
        weak var releasedCapture: NSImage?
        do {
            var card = Self.card(deadline: 600)
            card.capture = NSImage(size: NSSize(width: 2, height: 2))
            releasedCapture = card.capture
            approvals.open(card) { _ in }
            approvals.end(card.id, because: "Stopped")
        }
        #expect(releasedCapture == nil)
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

        init(level: AgentAccessLevel = .askBeforeActing, allowsAI: @escaping (URL) -> Bool = { $0.host != "excluded.example" }) {
            grant = AgentGrant(client: AgentClientIdentity(key: .signed(identifier: "com.example.codex", team: "ABCDE12345"), name: "codex", executablePath: "/usr/local/bin/codex", host: "Terminal",
                                                           isInterpreter: false),
                               personaID: FakeHost.defaultPersona.id, spaceID: host.spaces(in: FakeHost.defaultPersona.id)[0].id, level: level, scopes: AgentGrantScopes(), expiry: .whenArchQuits,
                               grantedAt: Date())
            toolHost = AgentToolHost(host: host, allowsAI: allowsAI)
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
        // The protocol's approval names what approval_wait waits on, for arch-mcp and API-key sessions, and structured names it for arch-cli --json.
        #expect(first.status == .approvalPending && first.approval == "a1" && first.structured?["approval"] == "a1")
        #expect(first.text == "request_approval waits for the user in Arch; call approval_wait with approval a1.")
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
        #expect(pick.kind == .requestTab([userTab], acting: false))
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

    enum SharedTabChange: CaseIterable { case reload, address, excluded, unloaded, owner, leftPersona, unoffered }

    @Test(arguments: SharedTabChange.allCases) func anOutsideShareRequiresTheReviewedEligibleDocument(_ change: SharedTabChange) async throws {
        struct ExcludeDuringAuthentication: AgentAuthenticating {
            let siteAllowed: Shared<Bool>

            func authenticate(reason: String) async -> Bool {
                siteAllowed.value = false
                return true
            }
        }
        let siteAllowed = Shared(true)
        let fixture = Fixture(allowsAI: { _ in siteAllowed.value })
        fixture.toolHost.answerWait = 10
        let tab = AgentTabInfo(id: UUID(), spaceID: fixture.grant.spaceID, title: "Source", url: URL(string: "https://docs.example/report?id=1"),
                               isLoading: false, engine: .webKit)
        fixture.host.tabs = [tab]
        fixture.host.userTabIDs = [tab.id]
        async let request = fixture.call("request_tab", ["access": "act", "reason": "Review a source"])
        let card = try await fixture.waitForCard()
        #expect(card.kind == .requestTab([tab], acting: true))
        var chosenID = tab.id
        switch change {
        case .reload: fixture.host.tabs[0].documentID = UUID()
        case .address: fixture.host.tabs[0].url = URL(string: "https://docs.example/report?id=2")
        case .excluded: fixture.toolHost.approvals.authenticator = ExcludeDuringAuthentication(siteAllowed: siteAllowed)
        case .unloaded: fixture.host.tabs[0].isLoaded = false
        case .owner: fixture.host.tabs[0].agentOwnerID = UUID()
        case .leftPersona: fixture.host.userTabIDs.remove(tab.id)
        case .unoffered:
            var later = tab
            later.id = UUID()
            fixture.host.tabs.append(later)
            fixture.host.userTabIDs.insert(later.id)
            chosenID = later.id
        }
        #expect(await fixture.toolHost.approvals.answer(card.id, with: .tab(chosenID)))
        let refused = await request
        #expect(refused.status == .stale && refused.code == "stale" && refused.structured == nil)
        #expect(fixture.state.handles.sharedTabIDs.isEmpty && fixture.state.handles.actingSharedTabIDs.isEmpty)
        #expect(fixture.state.handles.tabs.id(for: "t1") == nil)
    }

    @Test func anOutsidePickerOnlyOffersEligiblePagesAndSharesTheChosenTabAfterReordering() async throws {
        let fixture = Fixture()
        fixture.toolHost.answerWait = 10
        let tabs = ["https://docs.example/report?id=first", "https://docs.example/report?id=second",
                    "https://excluded.example", "arch://settings", "https://unloaded.example", "https://agent.example"].map {
            AgentTabInfo(id: UUID(), spaceID: fixture.grant.spaceID, title: "Report", url: URL(string: $0), isLoading: false, engine: .webKit)
        }
        fixture.host.tabs = tabs
        fixture.host.tabs[4].isLoaded = false
        fixture.host.tabs[5].agentOwnerID = UUID()
        fixture.host.userTabIDs = Set(tabs.map(\.id))
        async let request = fixture.call("request_tab", ["access": "act", "reason": "Use the chosen page"])
        let card = try await fixture.waitForCard()
        #expect(card.kind == .requestTab(Array(fixture.host.tabs.prefix(2)), acting: true))
        let chosen = tabs[1]
        fixture.host.tabs.reverse()
        #expect(await fixture.toolHost.approvals.answer(card.id, with: .tab(chosen.id)))
        let allowed = await request
        #expect(allowed.status == .ok && allowed.structured?["access"] == "act" && allowed.structured?["host"] == "docs.example")
        #expect(!allowed.text.contains("?id=") && !String(describing: allowed.structured).contains("?id="))
        #expect(fixture.state.handles.tabs.id(for: "t1") == chosen.id)
        #expect(fixture.state.handles.sharedTabIDs == [chosen.id] && fixture.state.handles.actingSharedTabIDs == [chosen.id])
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
        #expect(external.offers == [.allowOnce, .deny, .denyAndStop, .takeOver])
        #expect(fixture.host.openedExternally.isEmpty)
        await fixture.toolHost.approvals.answer(external.id, with: .allowOnce)
        try await waitUntil { fixture.host.openedExternally == [mail] }
        // Never the full addresses.
        let events = await fixture.call("list_tabs")
        #expect(events.text.contains("The user opened the link from \(handle) in Mail."))
        #expect(events.text.contains("tried to open another link in another app while one waits for the user"))
        #expect(!events.text.contains("token=1") && !events.text.contains("dana@example.org") && !downloads.text.contains("token=1"))
        // Deny and Stop stops the client, as on other sensitive cards; the host is a value, so this copy reports with its own stop.
        var stopped: [UUID] = []
        var toolHost = fixture.toolHost
        toolHost.stopClient = { stopped.append($0) }
        toolHost.tab(tabID, of: fixture.grant.id, didReport: .externalAppAsked(mail), state: fixture.state)
        let again = try await fixture.waitForCard()
        await fixture.toolHost.approvals.answer(again.id, with: .denyAndStop)
        try await waitUntil { !stopped.isEmpty }
        #expect(stopped == [again.ownerID] && fixture.host.openedExternally == [mail])
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

    @Test func aWaitingApprovalRecordsADenialWhenItsCallerEndsFirst() async throws {
        let fixture = Fixture()
        let call = AgentToolCall(name: "request_approval", arguments: ["summary": "Send it", "kind": "send"])
        var waiting: Task<AgentToolHost.Outcome, Never>?
        fixture.toolHost.approvals.didAdd = { _ in waiting?.cancel() }
        waiting = Task { await fixture.toolHost.run(call, for: fixture.grant, state: fixture.state) }

        let task = try #require(waiting)
        let outcome = await task.value
        #expect(outcome.result.status == .denied && outcome.result.code == "ended")
        #expect(outcome.decision == .denied)
        try await waitUntil { fixture.toolHost.approvals.pending.isEmpty && fixture.state.runningCalls.isEmpty }
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

    @Test func aClientsToolsCancelEndsTheCallAsCancelledWithdrawsItsCardOrLeavesTheSheetOpenAndFreesItsSlot() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.holdsAnswers = true
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.defaultPersona.id), level: .askBeforeActing, duration: .day)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        let connection = client.connection
        /// The answer to the call with this ID, past the progress and list notifications.
        func answer(to id: Int) async throws -> AgentJSON? {
            try await Task.detached {
                while true {
                    if case .result(.number(id), let result) = try connection.receive(timeout: 5) { return result }
                }
            }.value
        }
        func cancelled(_ result: AgentJSON?) -> Bool {
            guard let result = try? result?.decode(as: AgentToolResult.self) else { return false }
            return result.status == .error && result.code == "cancelled"
        }

        // A call that waits on the grant sheet stops waiting, and the sheet stays open for the client's next call.
        try connection.send(.request(id: .number(41), method: "tools/call", params: AgentToolCall(name: "session_info").params))
        try await waitUntil { harness.prompt.requests.count == 1 }
        try connection.send(.notification(method: "tools/cancel", params: AgentToolCancel(call: 41).params))
        #expect(cancelled(try await answer(to: 41)))
        let next = Task { try await client.callTool("session_info") }
        harness.prompt.release()
        #expect(try await next.value.status == .ok)
        #expect(harness.prompt.requests.count == 1)
        // The cancelled call ran nothing once the user allowed the client.
        try await waitUntil { service.activity.entries.contains { $0.tool == "session_info" } }
        #expect(service.activity.entries.filter { $0.tool == "session_info" }.count == 1)

        // A call that waits on its card: the card is withdrawn, and the slot frees, so the connection's fifth call runs while three others wait.
        for id in 42 ... 45 {
            try connection.send(.request(id: .number(id), method: "tools/call", params: AgentToolCall(name: "request_approval", arguments: ["summary": .string("Send reply \(id)"), "kind": "send"]).params))
        }
        try await waitUntil { service.approvals.pending.count == 4 }
        let card = try #require(service.approvals.pending.first { $0.agentSays == "Send reply 42" })
        try connection.send(.notification(method: "tools/cancel", params: AgentToolCancel(call: 42).params))
        #expect(cancelled(try await answer(to: 42)))
        #expect(service.approvals.outcomes[card.id] == .ended("The client cancelled the call."))
        #expect(service.approvals.pending.count == 3)
        #expect(try await client.callTool("list_tabs").status == .ok)
        // A call that has ended, or one that never ran, is left alone.
        try connection.send(.notification(method: "tools/cancel", params: AgentToolCancel(call: 42).params))
        try connection.send(.notification(method: "tools/cancel", params: AgentToolCancel(call: 99).params))
        #expect(service.approvals.pending.count == 3)
        service.stopAllAgents()
    }

    @Test func aClientsToolsCancelOfApprovalWaitWithdrawsTheCardOfTheCallItWaitsOn() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        harness.answerWait = 1
        let service = try await harness.makeOpenService()
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.defaultPersona.id), level: .askBeforeActing, duration: .day)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        let connection = client.connection
        let first = try await client.callTool("request_approval", ["summary": "Send the reply", "kind": "send"])
        #expect(first.status == .approvalPending && first.approval == "a1")
        let card = try #require(service.approvals.pending.first)
        // The agent waits on a1, and the user interrupts that wait in the client.
        try connection.send(.request(id: .number(50), method: "tools/call", params: AgentToolCall(name: "approval_wait", arguments: ["approval": "a1"]).params))
        try connection.send(.notification(method: "tools/cancel", params: AgentToolCancel(call: 50).params))
        let answer = try await Task.detached {
            while true {
                if case .result(.number(50), let result) = try connection.receive(timeout: 5) { return result }
            }
        }.value
        let cancelled = try answer.decode(as: AgentToolResult.self)
        #expect(cancelled.status == .error && cancelled.code == "cancelled")
        // The card is withdrawn, so a later Allow runs nothing, and the call it waited on ends and records so.
        #expect(service.approvals.outcomes[card.id] == .ended("The client cancelled the call."))
        #expect(service.approvals.pending.isEmpty)
        #expect(!(await service.approvals.answer(card.id, with: .allowOnce)))
        try await waitUntil { service.activity.entries.filter { $0.tool == "request_approval" }.count == 2 }
        #expect(service.activity.entries.last { $0.tool == "request_approval" }?.outcome != "ok")
    }

    @Test func aGrantAllowedAfterItsOnlyCallWasCancelledShowsItsClientConnected() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService()
        harness.prompt.holdsAnswers = true
        harness.prompt.answers = [AgentGrantChoice(persona: .existing(FakeHost.defaultPersona.id), level: .askBeforeActing, duration: .day)]
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        let connection = client.connection
        try connection.send(.request(id: .number(41), method: "tools/call", params: AgentToolCall(name: "session_info").params))
        try await waitUntil { harness.prompt.requests.count == 1 }
        try connection.send(.notification(method: "tools/cancel", params: AgentToolCancel(call: 41).params))
        _ = try await Task.detached {
            while true {
                if case .result(.number(41), _) = try connection.receive(timeout: 5) { return }
            }
        }.value
        // The user allows the client with no call left waiting: the indicator and Settings show it as connected at once.
        harness.prompt.release()
        try await waitUntil { !service.grants.isEmpty }
        #expect(service.connectedGrantIDs == Set(service.grants.map(\.id)))
        #expect(service.isAnyAgentActing)
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
        // The button reads the app's current event; its tracking loop, which takes events from the window server, is regression check 76's.
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
