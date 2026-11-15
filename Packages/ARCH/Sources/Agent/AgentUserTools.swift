// The tools that wait for the user (docs/agents.md, Tools ▸ Catalog; Approval interface): `request_tab`, `ask_user`, `request_approval` (P15), and `hand_to_user`, each a card in the agent panel, an outside client's `rename_tab`, whose first rename of a tab the user shared asks on P19's card, and the cards for a download (P6), a file chooser (P7), or a link to another app (P11) that a page in an agent tab starts. The agent's words on a card are marked as the agent's, and a card whose words name a secret leads with Arch's warning. The user's answers are the user's own words and reach the agent as they are.
import AgentControl
import AppKit
import ARCHEngine
import Foundation

extension AgentToolHost {
    func requestTab(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let acting = arguments["access"]?.stringValue == "act"
        let reason = arguments["reason"]?.stringValue ?? ""
        let choices = host.userTabs(in: client.personaID).filter { $0.canShareWithAgent(allowsAI: allowsAI) }
        let card = AgentApproval(ownerID: client.id, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: .requestTab(choices, acting: acting),
                                 isSensitive: false, offers: [.deny], action: acting ? "Share one of your tabs for the agent to read and act in" : "Share one of your tabs for the agent to read",
                                 agentSays: reason, connectionID: connectionID, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        box.approvalID = card.id
        let answer = await request(card, for: client)
        guard case .tab(let tabID) = answer else {
            return userEnded(answer, ask: "share a tab", decision: answer == .timedOut ? .timedOut : .denied)
        }
        guard let choice = choices.first(where: { $0.id == tabID }),
              let tab = host.userTabs(in: client.personaID).first(where: { $0.showsSameDocument(as: choice) && $0.canShareWithAgent(allowsAI: allowsAI) }) else {
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

    func askUser(_ arguments: [String: AgentJSON], _ client: AgentToolClient, box: AgentCallBox? = nil) async -> Outcome {
        let question = arguments["question"]?.stringValue ?? ""
        let choices = Self.strings(arguments["choices"]) ?? []
        let card = AgentApproval(ownerID: client.id, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: .question(choices), isSensitive: false,
                                 offers: [.cancel("")], action: "The agent asks you a question", agentSays: question, connectionID: connectionID, createdAt: now(),
                                 deadline: now().addingTimeInterval(approvalWindow))
        box?.approvalID = card.id
        let answer = await request(card, for: client)
        guard case .answer(let text) = answer else { return userEnded(answer, ask: "answer", decision: answer == .timedOut ? .timedOut : .denied) }
        return Outcome(result: AgentToolResult(status: .ok, text: "The user answered: \(text)", structured: ["answer": .string(text)]), step: "You answered the agent's question", decision: .approved)
    }

    func requestApproval(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let summary = arguments["summary"]?.stringValue ?? ""
        let kind = arguments["kind"]?.stringValue ?? "other"
        switch AgentPolicy.decide(.approvalRequest, client: client.kind, mode: client.level) {
        case .refuse(_, let sentence):
            return Outcome(result: AgentToolResult(status: .refused, code: AgentPolicy.readOnlyCode, text: sentence, structured: ["rule": .string(AgentPolicy.readOnlyCode)]))
        case .ask(let ask):
            var tab: AgentTabInfo?
            var handle: String?
            if let given = arguments["tab"]?.stringValue {
                switch readableTab(given, client, state: state) {
                case .value(let resolved): (tab, handle) = (resolved.0, resolved.1)
                case .outcome(let failure): return failure
                }
            }
            let what = Self.approvalKinds[kind] ?? "take a step"
            let sentence = "Approve the agent's request to \(what)" + (tab.flatMap { $0.url?.host }.map { " on \($0)" } ?? "")
            let card: AgentApproval
            if let tab, let handle, AgentPolicy.showsTitle(of: tab.url, allowsAI: allowsAI) {
                card = await stepCard(sentence, ask: ask, tab: tab, handle: handle, client: client, state: state, element: nil, exactText: nil, typing: false, agentSays: summary, kind: .requested(kind))
            } else {
                card = AgentApproval(ownerID: client.id, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: .requested(kind), rules: ask.rules,
                                     isSensitive: true, offers: AgentApproval.offers(for: ask), action: sentence, tabID: tab?.id, tabHandle: handle, agentSays: summary,
                                     connectionID: connectionID, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
            }
            box.approvalID = card.id
            let answer = await request(card, for: client)
            let decision: AgentActivityEntry.Decision = card.needsAuthentication ? .approvedWithTouchID : .approved
            switch answer {
            case .allowOnce:
                return Outcome(result: AgentToolResult(status: .ok, text: "The user approved: \(summary)", structured: ["decision": "approved"]), step: "You approved: \(summary)", decision: decision)
            case .reply(let text):
                return Outcome(result: AgentToolResult(status: .ok, text: "The user did not approve the step as asked and wrote instead: \(text)", structured: ["decision": "instruction", "reply": .string(text)]),
                               step: "You replied to the agent's request", decision: .denied)
            default:
                var outcome = answerOutcome(answer, card: card, handle: handle ?? "", client: client)
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

    func handToUser(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let given = arguments["tab"]?.stringValue ?? ""
        let tab: AgentTabInfo, handle: String
        switch readableTab(given, client, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        let reason = arguments["reason"]?.stringValue ?? "other"
        let message = arguments["message"]?.stringValue ?? ""
        let needs = ["sign_in": "sign in", "verification": "enter a verification code", "payment": "enter payment details"][reason] ?? "take a step"
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        // The user acts in the page, which may load other documents meanwhile, so the card ends only when the tab closes or leaves the client.
        let card = AgentApproval(ownerID: client.id, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: .handToUser(reason), isSensitive: false,
                                 offers: [.done(""), .cancel("")], action: "The agent hands you \(handle)\(site.map { " on \($0)" } ?? "") to \(needs)", tabID: tab.id, tabHandle: handle, site: site,
                                 agentSays: message, connectionID: connectionID, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        box.approvalID = card.id
        guard !client.deniesApprovals else { return userEnded(.ended(Self.deniedApprovalsReason), ask: "finish the step", decision: .denied) }
        // The user acts in the tab once the agent's trusted action there ends, and the target check of one that ended `stale` cancels none of the user's input.
        while state.inputTabs.contains(tab.id) {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return Self.ended }
        }
        releaseInputCheck(in: tab.id)
        host.showTab(tab.id)
        let answer = await request(card, for: client)
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

    /// An outside client's `rename_tab` (`docs/hooks.md`, Tools; rule P19): its own agent tab renames freely, and a tab the user shared once the user allows it on P19's card, which is not sensitive, so Allow for This Tab asks for no Touch ID. The allowance lasts while the tab stays shared, so the client's later renames of the tab ask nothing. Any other tab is refused with P17, and a tab on a site excluded from AI with P16. A name the tab would not take, since the user named the tab or turned the name down, answers `userNamed` without a card. A name belongs to the document the tab has committed, ignoring the fragment: a tab that loads another address answers `stale`, and so does a shared tab whose document ends or that closes while its card waits, which withdraws the card. After Allow for This Tab, the call renames nothing once it was cancelled, and the tab is checked again: a tab moved into the client's own agent folder renames as its agent tabs do, and any other that left the client is refused with P17. The name's first line is trimmed and cut to 60 characters, and an empty name clears a suggested name, through `BrowserAgentHost`'s suggested names (`AgentTabNaming`) with the grant as the cause.
    func renameTab(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let handle = arguments["tab"]?.stringValue ?? ""
        guard let id = state.handles.tabs.id(for: handle), let tab = host.tabs(withIDs: [id]).first else { return Self.error("tabNotFound", "This client has no tab \(handle).") }
        func refused(_ code: String, _ text: String) -> Outcome {
            Outcome(result: AgentToolResult(status: .refused, code: code, text: text, structured: ["rule": .string(code), "tab": .string(handle)]))
        }
        func stale(_ text: String) -> Outcome {
            Outcome(result: AgentToolResult(status: .stale, code: "stale", text: text, structured: ["tab": .string(handle)]))
        }
        var userNamed: Outcome { refused("userNamed", "The user's own name for this tab, or a name the user turned down, keeps the tab's name.") }
        let tabAccess = access(to: tab, client, state: state)
        let decision = AgentPolicy.renameDecision(client: client.kind, tab: tabAccess, allowedOnce: state.handles.renamingSharedTabIDs.contains(id))
        if case .refuse(let rule, let sentence) = decision { return refused(rule?.rawValue ?? AgentPolicy.wouldAskCode, sentence) }
        guard let naming = host as? AgentTabNaming else { return Self.notAvailable("This build of Arch cannot name tabs.") }
        // A name belongs to the document the tab has committed, which a tab that loads another address is leaving.
        guard let url = naming.committedAddress(ofTab: id), AgentRunner.sameDocument(tab.url, url) else {
            return stale("\(handle) is loading another page. Rename it once the page has loaded.")
        }
        guard AgentPolicy.showsTitle(of: url, allowsAI: allowsAI) else { return refused(AgentRule.p16.rawValue, AgentPolicy.entry(.p16).sentence) }
        let given = arguments["name"]?.stringValue ?? ""
        let name = String(given.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces).prefix(60)).trimmingCharacters(in: .whitespaces)
        let site = AgentActivityEntry.site(of: url)
        var decided: AgentActivityEntry.Decision?
        if case .ask(let ask) = decision {
            // A card asks only for a name the tab would take, which the user's own name or a refused name rules out.
            guard naming.suggestName(name.isEmpty ? nil : name, forTab: id, showing: url, byGrant: client.id, applying: false) else { return userNamed }
            // The tab's title is the page's, so it stands on one line in quotes whose closing quote inside is doubled, cut as other names a page gives are.
            let title = Self.oneLine(tab.title).trimmingCharacters(in: .whitespaces)
            let cut = title.count > AgentLimits.pageNameCharacters ? String(title.prefix(AgentLimits.pageNameCharacters)) + "\u{2026}" : title
            let named = title.isEmpty ? handle : "\u{201C}\(Self.quoted(cut))\u{201D}"
            var card = AgentApproval(ownerID: client.id, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: .renameSharedTab, rules: ask.rules, isSensitive: ask.isSensitive,
                                     offers: [.allowOnTab, .deny, .denyAndStop, .reply("")],
                                     action: (name.isEmpty ? "Clear the suggested name of your tab \(named)" : "Rename your tab \(named)") + (site.map { " on \($0)" } ?? ""),
                                     tabID: id, tabHandle: handle, site: site, exactText: name.isEmpty ? nil : name, connectionID: connectionID,
                                     document: state.activity(of: id).pages, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
            // The page count groups the card with the tab's other cards of its page, as theirs do (`stepCard`). The user's tab reports no pages, so the card is about its document, whose end withdraws it.
            card.documentID = tab.documentID
            box.approvalID = card.id
            let answer = await request(card, for: client)
            if answer == .withdrawn {
                // The tab's close withdraws the card too.
                guard let current = host.tabs(withIDs: [id]).first, access(to: current, client, state: state) != .notTheClients else {
                    return stale("\(handle) closed or left the client before the user answered.")
                }
                return stale("\(handle) showed another page before the user answered, so it kept its name.")
            }
            if var ended = answerOutcome(answer, card: card, handle: handle, client: client) {
                ended.site = site
                return ended
            }
            decided = .approved
            state.handles.renamingSharedTabIDs.insert(id)
            // Stop All Agents, a revocation, or the client's leaving while the answer came ends the call before it renames.
            if Task.isCancelled { return Self.ended }
            // While the card waited, the tab may have left the client, which ends the allowance, moved into the client's own agent folder, whose tabs rename freely, or committed another document; another fragment of the same document keeps the name's page.
            guard let current = host.tabs(withIDs: [id]).first, access(to: current, client, state: state) != .notTheClients else {
                return refused(AgentRule.p17.rawValue, AgentPolicy.entry(.p17).sentence)
            }
            guard current.documentID == tab.documentID, AgentRunner.sameDocument(naming.committedAddress(ofTab: id), url), AgentRunner.sameDocument(current.url, url) else {
                return stale("\(handle) showed another page before the user answered, so it kept its name.")
            }
            guard AgentPolicy.showsTitle(of: url, allowsAI: allowsAI) else { return refused(AgentRule.p16.rawValue, AgentPolicy.entry(.p16).sentence) }
        }
        guard naming.suggestName(name.isEmpty ? nil : name, forTab: id, showing: url, byGrant: client.id, applying: true) else { return userNamed }
        let text = name.isEmpty ? "Cleared the suggested name of \(handle)." : "Suggested the name \u{201C}\(name)\u{201D} for \(handle)."
        return Outcome(result: AgentToolResult(status: .ok, text: text, structured: ["tab": .string(handle), "name": .string(name), "applied": true]),
                       site: site, step: name.isEmpty ? "Cleared the name of \(handle)" : "Named \(handle) \u{201C}\(name)\u{201D}", decision: decided)
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
    func askAboutDownload(_ url: URL, in tabID: UUID, of ownerID: UUID, state: AgentGrantState, client: AgentToolClient?) {
        guard let tab = host.tabs(withIDs: [tabID]).first else { return }
        let handle = state.handles.tabs.handle(for: tabID)
        guard client?.deniesApprovals != true else {
            return state.record(.decided("Arch did not start the download in \(handle): this task was started with approvals denied."), tab: tabID)
        }
        let site = url.host?.lowercased()
        let name = url.lastPathComponent.isEmpty ? (url.host ?? "a file") : url.lastPathComponent
        let card = AgentApproval(ownerID: ownerID, clientName: client?.name ?? "", isOutsideClient: client?.isOutsideClient ?? true, kind: .download, rules: [.p6], isSensitive: false,
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
    func askAboutExternalApp(_ url: URL, in tabID: UUID, of ownerID: UUID, state: AgentGrantState, client: AgentToolClient?) {
        let handle = state.handles.tabs.handle(for: tabID)
        guard let app = host.appName(forOpening: url) else { return }
        guard client?.deniesApprovals != true else {
            return state.record(.decided("Arch did not open the link from \(handle) in \(app): this task was started with approvals denied."), tab: tabID)
        }
        let site = host.tabs(withIDs: [tabID]).first?.url?.host?.lowercased()
        let card = AgentApproval(ownerID: ownerID, clientName: client?.name ?? "", isOutsideClient: client?.isOutsideClient ?? true, kind: .externalApp(app), rules: [.p11], isSensitive: true,
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

    /// P7: a card about a file chooser that a page in an agent tab opened, whatever started it: a trusted click, a DOM `click()`, or the page's own script after an earlier activation. It comes before any panel, in every mode, and one chooser at a time per tab, while its card waits or Arch's panel shows for it. It names who asks as Arch's panel does, from the request's origins and never from the tab's address, what the page asks for, and its accepted types. Allow Once opens Arch's panel as a sheet on the window of the card that the user answered, or else the front main window, and the page receives only what the user picks there. Deny, Deny and Stop, and the card's timeout give the page no file, and so do Stop and Take Over while the card waits. `Browsing` ends the chooser with no file at a new document, a change of engine, the tab's close, and quit, also while its panel shows (`AgentFileChooser.end()`), so a load or an address change within the document leaves the card waiting. The agent learns that the page asked, then only how many items the user chose, or that the user cancelled, never a name or a path.
    func askAboutFileChooser(_ chooser: AgentFileChooser, in tabID: UUID, of ownerID: UUID, state: AgentGrantState?, client: AgentToolClient?) {
        guard let state, let client, host.tabs(withIDs: [tabID]).first?.agentOwnerID == ownerID,
              case .ask(let ask) = AgentPolicy.decide(.fileChooser, client: client.kind, mode: client.level) else { return chooser.deny() }
        let handle = state.handles.tabs.handle(for: tabID)
        guard state.fileChoosers[tabID].map(\.hasEnded) ?? true else {
            chooser.deny()
            return state.record(.decided("A page in \(handle) opened another file chooser while one waits for the user, so Arch gave it no file."), tab: tabID)
        }
        guard !client.deniesApprovals else {
            chooser.deny()
            return state.record(.decided("Arch gave the page in \(handle) no file: this task was started with approvals denied."), tab: tabID)
        }
        let request = chooser.request
        state.record(.fileChooserAsked(request.mode), tab: tabID)
        state.fileChoosers[tabID] = chooser
        // No document number: `Browsing` ends the chooser, and with it the card, when the tab commits another document.
        var card = AgentApproval(ownerID: ownerID, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: .fileChooser, rules: ask.rules, isSensitive: ask.isSensitive,
                                 offers: [.allowOnce, .deny, .denyAndStop], action: "\(Self.chooserAction(request.mode, asker: chooser.asker)) (\(handle))", tabID: tabID, tabHandle: handle,
                                 site: (request.origin ?? request.pageOrigin)?.host?.lowercased(), createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        card.exactTextNote = Self.chooserNote(request)
        let cardID = card.id
        let host = host
        let stopClient = stopClient
        let approvals = approvals
        let release = { if state.fileChoosers[tabID] === chooser { state.fileChoosers[tabID] = nil } }
        chooser.didEnd = { [weak approvals] in approvals?.withdraw(cardID) }
        approvals.open(card, onAnswerInWindow: { answer, window in
            let ended = chooser.hasEnded
            guard answer.allows, !ended, let window = window ?? host.windowForSheet() else {
                if answer == .denyAndStop { stopClient?(ownerID) }
                chooser.deny()
                release()
                let sentence: String
                if answer == .deny || answer == .denyAndStop {
                    sentence = "The user did not allow the file chooser in \(handle), so the page received no file (P7)."
                } else if answer.allows, !ended {
                    sentence = "The user allowed the file chooser in \(handle), but no window could show Arch's panel, so the page received no file (P7)."
                } else {
                    sentence = "The file chooser in \(handle) ended without the user's answer, so the page received no file (P7)."
                }
                return state.record(.decided(sentence), tab: tabID)
            }
            chooser.choose(on: window) { chosen in
                release()
                state.record(.fileChooserEnded(request.mode, chosen: chosen), tab: tabID)
            }
        })
    }

    /// A P7 card's step, as Arch's panel words it.
    static func chooserAction(_ mode: EngineFileChooserRequest.Mode, asker: String) -> String {
        switch mode {
        case .openFile: return "Choose a file for \(asker)"
        case .openFiles: return "Choose files for \(asker)"
        case .openFolder: return "Choose a folder for \(asker)"
        case .save: return "Choose where \(asker) saves a file"
        }
    }

    /// How many accepted types a P7 card lists.
    static let listedChooserTypes = 8

    /// A P7 card's note: the types the page accepts, what a folder gives it, the name it suggests for saving, and what the agent learns. It lists the types only when each has a declared file type, as the panel offers them (`allowedContentTypes`), so that no page text reaches the card as a type. The request has no types when the page accepts any file, and also when the engine cannot tell, as WebKit cannot with its private API flag off.
    static func chooserNote(_ request: EngineFileChooserRequest) -> String {
        var sentences: [String] = []
        switch request.mode {
        case .openFile, .openFiles:
            let types = request.acceptedTypes
            if types.isEmpty {
                sentences.append("Arch has no file types from the page, so the panel offers every file.")
            } else if request.allowedContentTypes == nil {
                sentences.append("The page names file types that macOS does not know, so the panel offers every file.")
            } else {
                let more = types.count - listedChooserTypes
                sentences.append("The page accepts \(types.prefix(listedChooserTypes).joined(separator: ", "))\(more > 0 ? " and \(more) more" : "").")
            }
        case .openFolder: sentences.append("The page receives every file in the folder.")
        case .save:
            // The page chooses the name, which shows on one line and is cut as other names a page gives are.
            if let name = request.suggestedName.map({ oneLine($0).trimmingCharacters(in: .whitespaces) }), !name.isEmpty {
                let cut = name.count > AgentLimits.pageNameCharacters ? String(name.prefix(AgentLimits.pageNameCharacters)) + "\u{2026}" : name
                sentences.append("The page suggests the name \u{201C}\(quoted(cut))\u{201D}.")
            }
        }
        sentences.append("You pick in Arch's panel. The agent learns only how many items you chose.")
        return sentences.joined(separator: " ")
    }

    /// Text a page chose, as one line in the card's own words: control characters and line and paragraph separators become spaces, and format characters, such as bidirectional overrides, are dropped, so that the text cannot break the card's sentence or reorder it.
    static func oneLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            case .format: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
