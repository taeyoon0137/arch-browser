// The tools that wait for the user (docs/agents.md, Tools ▸ Catalog; Approval interface): `request_tab`, `ask_user`, `request_approval` (P15), and `hand_to_user`, each a card in the agent panel, and the cards for a download (P6) or a link to another app (P11) that a page in an agent tab starts. The agent's words on a card are marked as the agent's, and a card whose words name a secret leads with Arch's warning. The user's answers are the user's own words and reach the agent as they are.
import AgentControl
import Foundation

extension AgentToolHost {
    func requestTab(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let acting = arguments["access"]?.stringValue == "act"
        let reason = arguments["reason"]?.stringValue ?? ""
        let choices = host.userTabs(in: grant.personaID).filter { $0.canShareWithAgent(allowsAI: allowsAI) }
        let card = AgentApproval(ownerID: grant.id, clientName: grant.client.displayName, isOutsideClient: clientKind == .outside, kind: .requestTab(choices, acting: acting),
                                 isSensitive: false, offers: [.deny], action: acting ? "Share one of your tabs for the agent to read and act in" : "Share one of your tabs for the agent to read",
                                 agentSays: reason, connectionID: connectionID, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        box.approvalID = card.id
        let answer = await approvals.request(card)
        guard case .tab(let tabID) = answer else {
            return userEnded(answer, ask: "share a tab", decision: answer == .timedOut ? .timedOut : .denied)
        }
        guard let choice = choices.first(where: { $0.id == tabID }),
              let tab = host.userTabs(in: grant.personaID).first(where: { $0.showsSameDocument(as: choice) && $0.canShareWithAgent(allowsAI: allowsAI) }) else {
            return Outcome(result: AgentToolResult(status: .stale, code: "stale", text: "The reviewed tab changed. No tab was shared."), decision: .refused)
        }
        let handle = state.handles.tabs.handle(for: tab.id)
        if !state.handles.sharedTabIDs.contains(tab.id) { state.handles.sharedTabIDs.append(tab.id) }
        if acting { state.handles.actingSharedTabIDs.insert(tab.id) } else { state.handles.actingSharedTabIDs.remove(tab.id) }
        let title = Self.pageName(tab.title, url: tab.url)
        let text = "The user shared \(handle): \(title) on \(tab.url?.host ?? "a page"), for \(acting ? "reading and acting; every action there asks the user (P12)" : "reading only")."
        let structured: [String: AgentJSON] = ["tab": .string(handle), "access": .string(acting ? "act" : "read"),
                                                "title": .string(title), "host": tab.url?.host.map(AgentJSON.string) ?? .null]
        // An outside client's Share counted only after Touch ID or the login password (`AgentApproval.needsAuthentication(for:)`).
        return Outcome(result: AgentToolResult(status: .ok, text: text, structured: .object(structured)), site: tab.url.flatMap(AgentActivityEntry.site(of:)),
                       step: "You shared \(handle) for \(acting ? "reading and acting" : "reading")", decision: card.needsAuthentication(for: answer) ? .approvedWithTouchID : .approved)
    }

    func askUser(_ arguments: [String: AgentJSON], ownerID: UUID, name: String, box: AgentCallBox? = nil) async -> Outcome {
        let question = arguments["question"]?.stringValue ?? ""
        let choices = Self.strings(arguments["choices"]) ?? []
        let card = AgentApproval(ownerID: ownerID, clientName: name, isOutsideClient: clientKind == .outside, kind: .question(choices), isSensitive: false,
                                 offers: [.cancel("")], action: "The agent asks you a question", agentSays: question, connectionID: connectionID, createdAt: now(),
                                 deadline: now().addingTimeInterval(approvalWindow))
        box?.approvalID = card.id
        let answer = await approvals.request(card)
        guard case .answer(let text) = answer else { return userEnded(answer, ask: "answer", decision: answer == .timedOut ? .timedOut : .denied) }
        return Outcome(result: AgentToolResult(status: .ok, text: "The user answered: \(text)", structured: ["answer": .string(text)]), step: "You answered the agent's question", decision: .approved)
    }

    func requestApproval(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let summary = arguments["summary"]?.stringValue ?? ""
        let kind = arguments["kind"]?.stringValue ?? "other"
        switch AgentPolicy.decide(.approvalRequest, client: clientKind, mode: grant.level) {
        case .refuse(_, let sentence):
            return Outcome(result: AgentToolResult(status: .refused, code: AgentPolicy.readOnlyCode, text: sentence, structured: ["rule": .string(AgentPolicy.readOnlyCode)]))
        case .ask(let ask):
            var tab: AgentTabInfo?
            var handle: String?
            if let given = arguments["tab"]?.stringValue {
                switch readableTab(given, grant, state: state) {
                case .value(let resolved): (tab, handle) = (resolved.0, resolved.1)
                case .outcome(let failure): return failure
                }
            }
            let what = Self.approvalKinds[kind] ?? "take a step"
            let sentence = "Approve the agent's request to \(what)" + (tab.flatMap { $0.url?.host }.map { " on \($0)" } ?? "")
            let card: AgentApproval
            if let tab, let handle, AgentPolicy.showsTitle(of: tab.url, allowsAI: allowsAI) {
                card = await stepCard(sentence, ask: ask, tab: tab, handle: handle, grant: grant, state: state, element: nil, exactText: nil, typing: false, agentSays: summary, kind: .requested(kind))
            } else {
                card = AgentApproval(ownerID: grant.id, clientName: grant.client.displayName, isOutsideClient: clientKind == .outside, kind: .requested(kind), rules: ask.rules,
                                     isSensitive: true, offers: AgentApproval.offers(for: ask), action: sentence, tabID: tab?.id, tabHandle: handle, agentSays: summary,
                                     connectionID: connectionID, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
            }
            box.approvalID = card.id
            let answer = await approvals.request(card)
            let decision: AgentActivityEntry.Decision = card.needsAuthentication ? .approvedWithTouchID : .approved
            switch answer {
            case .allowOnce:
                return Outcome(result: AgentToolResult(status: .ok, text: "The user approved: \(summary)", structured: ["decision": "approved"]), step: "You approved: \(summary)", decision: decision)
            case .reply(let text):
                return Outcome(result: AgentToolResult(status: .ok, text: "The user did not approve the step as asked and wrote instead: \(text)", structured: ["decision": "instruction", "reply": .string(text)]),
                               step: "You replied to the agent's request", decision: .denied)
            default:
                var outcome = answerOutcome(answer, card: card, handle: handle ?? "", grant: grant)
                    ?? Outcome(result: AgentToolResult(status: .denied, text: "The user denied the step."))
                if var structured = outcome.result.structured?.objectValue {
                    structured["decision"] = answer == .timedOut ? "timedOut" : "denied"
                    outcome.result.structured = .object(structured)
                }
                outcome.step = "Not approved: \(summary)"
                return outcome
            }
        default:
            return Self.error("notAvailable", "Arch cannot ask for this approval.")
        }
    }

    func handToUser(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let given = arguments["tab"]?.stringValue ?? ""
        let tab: AgentTabInfo, handle: String
        switch readableTab(given, grant, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        let reason = arguments["reason"]?.stringValue ?? "other"
        let message = arguments["message"]?.stringValue ?? ""
        let needs = ["sign_in": "sign in", "verification": "enter a verification code", "payment": "enter payment details"][reason] ?? "take a step"
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        // The user acts in the page, which may load other documents meanwhile, so the card ends only when the tab closes or leaves the client.
        let card = AgentApproval(ownerID: grant.id, clientName: grant.client.displayName, isOutsideClient: clientKind == .outside, kind: .handToUser(reason), isSensitive: false,
                                 offers: [.done(""), .cancel("")], action: "The agent hands you \(handle)\(site.map { " on \($0)" } ?? "") to \(needs)", tabID: tab.id, tabHandle: handle, site: site,
                                 agentSays: message, connectionID: connectionID, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        box.approvalID = card.id
        host.showTab(tab.id)
        let answer = await approvals.request(card)
        switch answer {
        case .done(let text):
            return Outcome(result: AgentToolResult(status: .ok, text: "The user finished in \(handle)" + (text.isEmpty ? "." : " and wrote: \(text)"), structured: ["tab": .string(handle), "done": true, "message": .string(text)]),
                           site: site, step: "You finished the step in \(handle)", decision: .approved)
        case .cancel(let text):
            return Outcome(result: AgentToolResult(status: .denied, text: "The user cancelled the step in \(handle)" + (text.isEmpty ? "." : " and wrote: \(text)"), structured: ["tab": .string(handle), "done": false, "message": .string(text)]),
                           site: site, step: "You cancelled the step in \(handle)", decision: .denied)
        default:
            var outcome = userEnded(answer, ask: "finish the step", decision: answer == .timedOut ? .timedOut : .denied)
            outcome.site = site
            return outcome
        }
    }

    /// What `request_approval`'s kinds ask for, in the card's sentence.
    static let approvalKinds = ["submit": "submit a form", "purchase": "make a purchase", "send": "send a message", "delete": "delete something", "download": "download a file", "other": "take a step"]

    /// The result of a question or a handed tab that the user did not answer.
    private func userEnded(_ answer: AgentApprovalAnswer, ask: String, decision: AgentActivityEntry.Decision) -> Outcome {
        switch answer {
        case .timedOut: return Outcome(result: AgentToolResult(status: .timeout, code: "notAnswered", text: "The user did not \(ask) in Arch in time."), decision: decision)
        case .withdrawn: return Outcome(result: AgentToolResult(status: .stale, code: "stale", text: "The tab closed or left the client before the user answered."), decision: decision)
        case .ended(let reason): return Outcome(result: AgentToolResult(status: .denied, code: "ended", text: "\(reason) The user did not \(ask)."), decision: decision)
        default: return Outcome(result: AgentToolResult(status: .denied, text: "The user chose not to \(ask)."), decision: decision)
        }
    }

    // MARK: Cards a page starts

    /// P6: a card about a download a page in an agent tab started, while no other download card of the tab waits (`tab(_:of:didReport:state:client:)`). Allow Once lets that address download once, and Allow Downloads from This Site for the session; the tab then asks for the address again, which a link's plain download repeats.
    func askAboutDownload(_ url: URL, in tabID: UUID, of ownerID: UUID, state: AgentGrantState, client: String) {
        guard let tab = host.tabs(withIDs: [tabID]).first else { return }
        let handle = state.handles.tabs.handle(for: tabID)
        let site = url.host?.lowercased()
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "a file") : url.lastPathComponent
        let card = AgentApproval(ownerID: ownerID, clientName: client, isOutsideClient: clientKind == .outside, kind: .download, rules: [.p6], isSensitive: false,
                                 offers: [.allowOnce, .allowDownloadsFromSite, .deny], action: "Download \u{201C}\(Self.quoted(name))\u{201D}\(site.map { " from \($0)" } ?? "") in \(handle)",
                                 tabID: tabID, tabHandle: handle, site: site, exactText: url.absoluteString, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        let host = host
        approvals.open(card) { answer in
            switch answer {
            case .allowOnce: state.allowedDownloads.insert(url)
            case .allowDownloadsFromSite: if let site { state.downloadSites.insert(site) }
            default: break
            }
            state.record(.decided("The user \(answer.allows ? "allowed" : "did not allow") the download in \(handle).\(answer.allows ? " It starts again." : "")"), tab: tabID)
            if answer.allows, host.tabs(withIDs: [tab.id]).first?.agentOwnerID == ownerID { host.navigate(tab.id, .load(url)) }
        }
    }

    /// Whether a page's link to another app gets a card: one at a time per tab, so that a page cannot pile them up, and only when an app opens it. Otherwise the agent hears what Arch decided instead.
    func asksAboutExternalApp(_ url: URL, in tabID: UUID, state: AgentGrantState) -> Bool {
        let handle = state.handles.tabs.handle(for: tabID)
        if approvals.pending.contains(where: { if case .externalApp = $0.kind { return $0.tabID == tabID } else { return false } }) {
            state.record(.decided("A page in \(handle) tried to open another link in another app while one waits for the user, so Arch did not ask again."), tab: tabID)
            return false
        }
        guard host.appName(forOpening: url) != nil else {
            state.record(.decided("No app on this Mac opens the link that \(handle) tried to open."), tab: tabID)
            return false
        }
        return true
    }

    /// P11: a sensitive card about a link to another app that a page in an agent tab opened, naming the app; the link opens there only after Allow. No call carries a reply, so the card offers none.
    func askAboutExternalApp(_ url: URL, in tabID: UUID, of ownerID: UUID, state: AgentGrantState, client: String) {
        let handle = state.handles.tabs.handle(for: tabID)
        guard let app = host.appName(forOpening: url) else { return }
        let site = host.tabs(withIDs: [tabID]).first?.url?.host?.lowercased()
        let card = AgentApproval(ownerID: ownerID, clientName: client, isOutsideClient: clientKind == .outside, kind: .externalApp(app), rules: [.p11], isSensitive: true,
                                 offers: [.allowOnce, .deny, .denyAndStop, .takeOver], action: "Open a link in \(app) from \(handle)\(site.map { " on \($0)" } ?? "")",
                                 tabID: tabID, tabHandle: handle, site: site, exactText: url.absoluteString, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        let host = host
        let stopClient = stopClient
        approvals.open(card) { answer in
            switch answer {
            case .allowOnce: host.openExternally(url)
            case .denyAndStop: stopClient?(ownerID)
            case .takeOver: host.showTab(tabID)
            default: break
            }
            state.record(.decided("The user \(answer.allows ? "opened" : "did not open") the link from \(handle) in \(app)."), tab: tabID)
        }
    }
}
