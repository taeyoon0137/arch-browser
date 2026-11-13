// The tools that run the agents' page script (docs/agents.md, Page snapshots and refs): `snapshot` with the host's diff, `screenshot` with its limits and the boxes painted over, and the actions `click`, `type`, `press`, `select_option`, `scroll`, and `hover`, each classified by the policy from the element's facts and asked about on a card when a rule or the mode says so. Each script call has `scriptWait`; a page that does not answer gets `timeout`. Actions use DOM events and say so (`inputKind: dom`).
import AgentControl
import AppKit
import Foundation

extension AgentToolHost {
    // MARK: Running the script

    /// The page script's reply to an operation in the tab, decoded, or the outcome that ends the call: `timeout` when the page does not answer, as while it shows a dialog, and an error when the script fails or its reply does not read.
    func pageScript<Reply: Decodable>(_ operation: AgentPageOperation, in tab: AgentTabInfo, as type: Reply.Type, handle: String = "") async -> Resolved<Reply> {
        let host = host
        let wait = scriptWait
        let source = AgentPageScripts.source(for: operation)
        let answer: Result<String?, any Error>? = await withCheckedContinuation { continuation in
            let once = AgentOnce(continuation)
            host.runPageScript(source, world: AgentPageScripts.world, in: tab.id) { once.resume(with: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { once.resume(with: nil) }
        }
        switch answer {
        case nil:
            return .outcome(Outcome(result: AgentToolResult(status: .timeout, code: "notResponding", text: "\(handle.isEmpty ? "The tab" : handle) shows a dialog or does not respond. It waits for the user.")))
        case .failure?, .success(nil)?:
            return .outcome(Self.error("unreadable", "\(handle.isEmpty ? "The tab" : handle) has no document Arch can read, as while it shows an engine's error page."))
        case .success(let text?)?:
            guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(text.utf8)) else { return .outcome(Self.error("unreadable", "Arch could not read \(handle)'s answer.")) }
            return .value(reply)
        }
    }

    /// A tab the client may read, whose page is one agents read now (P16) and whose handle is still the client's (P17).
    private func pageTab(_ handle: String, _ grant: AgentGrant, state: AgentGrantState) -> Resolved<(AgentTabInfo, String)> {
        switch readableTab(handle, grant, state: state) {
        case .outcome(let failure): return .outcome(failure)
        case .value(let resolved):
            if case .refused(let rule, let sentence) = AgentPolicy.mayRead(resolved.0.url, allowsAI: allowsAI) {
                return .outcome(Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle)))
            }
            return .value(resolved)
        }
    }

    /// After a script ran: the tab's page may have moved on to one agents do not read, and the user may have taken the tab over.
    private func stillReadable(_ tab: AgentTabInfo, handle: String, reportedURL: String, _ grant: AgentGrant, state: AgentGrantState) -> Outcome? {
        if let current = host.tabs(withIDs: [tab.id]).first, !(current.agentOwnerID == grant.id || state.handles.sharedTabIDs.contains(current.id)) {
            return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle))
        }
        if case .refused(let rule, let sentence) = AgentPolicy.mayRead(URL(string: reportedURL), allowsAI: allowsAI) {
            return Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle))
        }
        return nil
    }

    private func isShared(_ tab: AgentTabInfo, state: AgentGrantState) -> Bool {
        tab.agentOwnerID == nil && state.handles.sharedTabIDs.contains(tab.id)
    }

    // MARK: snapshot

    func snapshot(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        let handle = arguments["tab"]?.stringValue ?? ""
        let tab: AgentTabInfo
        switch pageTab(handle, grant, state: state) {
        case .value(let resolved): tab = resolved.0
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let full = arguments["mode"]?.stringValue == "full"
        var target: AgentRefTarget?
        if let ref = arguments["ref"]?.stringValue {
            guard let record = currentSnapshot(of: tab, state: state), let entry = record.refs[ref], let resolved = AgentRefTarget(ref, fingerprint: entry.fingerprint) else {
                return Self.stale(handle)
            }
            target = resolved
        }
        let shared = isShared(tab, state: state)
        let reply: AgentSnapshotReply
        switch await pageScript(.snapshot(full: full, ref: target, shared: shared), in: tab, as: AgentSnapshotReply.self, handle: handle) {
        case .value(let value): reply = value
        case .outcome(var failure):
            failure.site = site
            return failure
        }
        if let refusal = stillReadable(tab, handle: handle, reportedURL: reply.url, grant, state: state) { return refusal }
        if reply.stale == true { return Self.stale(handle) }
        guard let url = URL(string: reply.url) else { return Self.error("unreadable", "\(handle) has no document Arch can read.") }
        let lines = outline(reply.nodes, full: full, shared: shared, pageURL: url)
        // A new document's snapshot starts the record again; a subtree's adds its refs to the record of the same document.
        let documents = state.activity(of: tab.id).documents
        var record = state.snapshots[tab.id].flatMap { $0.url == url && $0.document == documents ? $0 : nil } ?? AgentSnapshotRecord(url: url, document: documents, refs: [:], lines: [])
        if target == nil { record.refs = [:] }
        for node in reply.nodes {
            guard let ref = node.ref, let fingerprint = node.fingerprint else { continue }
            record.refs[ref] = AgentSnapshotRecord.Ref(fingerprint: fingerprint, href: node.href.flatMap(URL.init(string:)))
        }
        let previous = state.snapshots[tab.id]?.lines
        let number = (state.snapshotCounts[tab.id] ?? 0) + 1
        state.snapshotCounts[tab.id] = number
        if target == nil { record.lines = lines }
        state.snapshots[tab.id] = record

        var shown = lines
        var note: String?
        if arguments["diff"] == .bool(true) {
            if let previous {
                let difference = lines.difference(from: previous)
                shown = difference.removals.map { if case .remove(_, let line, _) = $0 { return "- " + line } else { return "" } }
                    + difference.insertions.map { if case .insert(_, let line, _) = $0 { return "+ " + line } else { return "" } }
                if shown.isEmpty { note = "Nothing changed since the last snapshot of \(handle)." }
            } else {
                note = "This is the first snapshot of \(handle), so it shows the whole outline."
            }
        }
        let limit = arguments["max_chars"].flatMap(Self.integer) ?? AgentLimits.snapshotDefaultCharacters
        var kept: [String] = []
        var characters = 0
        var bytes = 0
        for line in shown {
            guard characters + line.count + 1 <= limit, bytes + line.utf8.count + 1 <= AgentLimits.resultTextBytes - Self.resultRoom - 400 else { break }
            kept.append(line)
            characters += line.count + 1
            bytes += line.utf8.count + 1
        }
        let header = "page \u{201C}\(Self.quoted(reply.title))\u{201D} \(Self.shortAddress(url))"
        let block = AgentUntrusted.wrap(([header] + kept).joined(separator: "\n"), url: url)
        var text = ["\(handle) \u{00B7} \(tab.engine.rawValue) \u{00B7} snapshot \(number)\(full ? " \u{00B7} full" : "")\(target.map { " \u{00B7} \($0.ref)" } ?? "")\(shared ? " \u{00B7} shared by the user: every action here asks" : "")", block]
        var structured: [String: AgentJSON] = ["tab": .string(handle), "url": .string(AgentAddress.reduced(url).absoluteString), "snapshot": .number(Double(number)),
                                               "mode": .string(full ? "full" : "interactive"), "refs": .number(Double(record.refs.count)), "outline": .string(block)]
        if let note { text.append(note) }
        if kept.count < shown.count {
            text.append("The outline was cut at \(Self.number(characters)) characters after \(kept.count) of \(shown.count) lines. Ask for less with mode interactive or a ref, raise max_chars up to \(Self.number(AgentLimits.snapshotMaximumCharacters)), or read the text with read_text.")
            structured["limits"] = ["snapshotCharacters": .number(Double(limit)), "leftOutLines": .number(Double(shown.count - kept.count))]
        }
        let warns = AgentPolicy.addressesAgents(block)
        if warns { structured["addressesAgents"] = true }
        return Outcome(result: AgentToolResult(status: .ok, text: text.joined(separator: "\n"), structured: .object(structured)), site: site,
                       step: "Read the outline of \(handle) on \(site ?? "a page")" + (warns ? ". This page contains text addressed to AI agents." : ""))
    }

    /// The outline's lines from the script's nodes, with the policy's annotations. Interactive mode leaves out landmarks that hold nothing; a subtree starts at depth 0.
    func outline(_ nodes: [AgentOutlineNode], full: Bool, shared: Bool, pageURL: URL) -> [String] {
        let base = nodes.first?.depth ?? 0
        var lines: [String] = []
        for (index, node) in nodes.enumerated() {
            let isContainer = node.ref == nil && node.role != "text" && node.role != "heading" && node.role != "img" && node.role != "frame"
            if isContainer, !full {
                let next = nodes.dropFirst(index + 1).first
                if next == nil || next!.depth <= node.depth { continue }
            }
            lines.append(String(repeating: "  ", count: max(0, node.depth - base)) + "- " + line(for: node, shared: shared, pageURL: pageURL))
        }
        return lines
    }

    private func line(for node: AgentOutlineNode, shared: Bool, pageURL: URL) -> String {
        if node.role == "text" { return "text \u{201C}\(Self.quoted(node.text ?? ""))\u{201D}" }
        var line = node.role
        if let name = node.name, !name.isEmpty { line += " \u{201C}\(Self.quoted(name))\u{201D}" }
        if let ref = node.ref { line += " [\(ref)]" }
        if let level = node.level { line += " level=\(level)" }
        switch node.valueClass {
        case .hidden?: line += " value hidden"
        case .personal?: line += " value=<personal>"
        case nil: if let value = node.value { line += " value=\u{201C}\(Self.quoted(value))\u{201D}" }
        }
        if let checked = node.checked { line += checked ? " checked" : " not checked" }
        if node.disabled == true { line += " disabled" }
        if let href = node.href.flatMap(URL.init(string:)) { line += " \u{2192} \(Self.shortAddress(href))" }
        if node.submits == true { line += " submits form" }
        if node.role == "frame" {
            if let frame = node.frameURL.flatMap(URL.init(string:)), AgentPolicy.isChallengeFrame(frame) { return line + " (CAPTCHA: hand to the user)" }
            if node.otherSite == true { line += " (another site; not read)" }
        }
        if let annotation = annotation(for: node, shared: shared) { line += " " + annotation }
        return line
    }

    /// What the policy says of an element before the agent tries: P1's fields, file inputs, CAPTCHAs, and the elements a rule asks about. The mode's own cards are named once in `session_info`.
    private func annotation(for node: AgentOutlineNode, shared: Bool) -> String? {
        guard node.ref != nil else { return nil }
        let facts = AgentElementFacts(tag: "", role: node.role, name: node.name ?? "", inputType: node.inputType, valueClass: node.valueClass, isEditable: node.isEditable ?? false,
                                      isFileInput: node.isFileInput ?? false, submitsForm: node.submits ?? false, formFields: node.formFields ?? [])
        if facts.isFileInput { return "(agents do not choose files)" }
        if AgentPolicy.isChallenge(facts) { return "(CAPTCHA: hand to the user)" }
        if facts.isEditable, facts.valueClass == .hidden { return "(agents do not type here)" }
        if shared { return "(asks the user)" }
        let asks = (facts.isEditable && facts.valueClass == .personal)
            || (facts.submitsForm && !Set(facts.formFields).isDisjoint(with: [.password, .oneTimeCode, .payment, .personal]))
            || ((node.role == "button" || node.role == "link") && AgentPolicy.readsAsIrreversible(facts.name))
        return asks ? "(asks the user)" : nil
    }

    /// Text a page chose, inside the outline's quotes.
    static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{201D}", with: "\u{201D}\u{201D}").replacingOccurrences(of: "\n", with: " ")
    }

    /// An address as the outline shows it: host and path, without scheme, query, or fragment.
    static func shortAddress(_ url: URL) -> String {
        let reduced = AgentAddress.reduced(url)
        guard let host = reduced.host else { return reduced.absoluteString }
        return host + (reduced.port.map { ":\($0)" } ?? "") + (reduced.path.isEmpty ? "/" : reduced.path)
    }

    // MARK: screenshot

    func screenshot(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        let handle = arguments["tab"]?.stringValue ?? ""
        let tab: AgentTabInfo
        switch pageTab(handle, grant, state: state) {
        case .value(let resolved): tab = resolved.0
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let area = arguments["area"]?.stringValue ?? "viewport"
        var element: AgentBox?
        if area != "viewport", area != "full" {
            guard let record = currentSnapshot(of: tab, state: state), let entry = record.refs[area], let target = AgentRefTarget(area, fingerprint: entry.fingerprint) else {
                return AgentRefTarget(area) == nil ? Self.error("invalidArguments", "area must be viewport, full, or a ref such as e5.") : Self.stale(handle)
            }
            switch await pageScript(.element(target), in: tab, as: AgentElementReply.self, handle: handle) {
            case .outcome(var failure):
                failure.site = site
                return failure
            case .value(let reply):
                if reply.problem == "stale" || reply.problem == "notFound" { return Self.stale(handle) }
                element = reply.facts?.box
            }
        }
        let full = area == "full"
        var capture: AgentScreenshot.Capture?
        // The boxes are read before and after each capture; a page whose private fields moved meanwhile gets one more capture, then no screenshot.
        for _ in 0 ..< 2 {
            let before: AgentBoxesReply
            switch await pageScript(.boxes, in: tab, as: AgentBoxesReply.self, handle: handle) {
            case .value(let reply): before = reply
            case .outcome(var failure):
                failure.result.content.append(.text("A tab whose page does not answer gets no screenshot."))
                failure.site = site
                return failure
            }
            if let refusal = stillReadable(tab, handle: handle, reportedURL: before.url, grant, state: state) { return refusal }
            let image: NSImage? = await withCheckedContinuation { continuation in host.capture(tab.id, fullPage: full) { continuation.resume(returning: $0) } }
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), !AgentScreenshot.isBlank(cgImage) else {
                return Outcome(result: AgentToolResult(status: .error, code: "notVisible", text: "\(handle) cannot be captured while no window shows it. Read it with snapshot.",
                                                       structured: ["tab": .string(handle)]), site: site)
            }
            guard case .value(let after) = await pageScript(.boxes, in: tab, as: AgentBoxesReply.self, handle: handle) else { break }
            if after == before {
                capture = AgentScreenshot.Capture(image: cgImage, boxes: before, fullPage: full)
                break
            }
        }
        guard let capture else {
            return Outcome(result: AgentToolResult(status: .error, code: "notStable", text: "\(handle)'s page kept moving while Arch captured it, so it gives no screenshot. Try again once the page is still.",
                                                   structured: ["tab": .string(handle)]), site: site)
        }
        guard let shot = AgentScreenshot.encode(capture, element: element) else { return Self.error("unreadable", "Arch could not encode \(handle)'s screenshot.") }
        let what = full ? "the full page" : element != nil ? "the element \(area)" : "the viewport"
        var text = "\(handle): a screenshot of \(what), \(Self.number(shot.width)) \u{00D7} \(Self.number(shot.height)) pixels, JPEG."
        if shot.painted > 0 { text += " Arch painted over \(shot.painted == 1 ? "1 private field or frame" : "\(shot.painted) private fields and frames")." }
        if shot.cutAtCSSHeight { text += " The page is taller than \(Self.number(AgentLimits.screenshotFullPageCSSHeight)) CSS pixels, so the image ends there." }
        var result = AgentToolResult(status: .ok, text: text, structured: ["tab": .string(handle), "area": .string(area), "width": .number(Double(shot.width)), "height": .number(Double(shot.height)),
                                                                          "painted": .number(Double(shot.painted)), "cut": .bool(shot.cutAtCSSHeight), "mimeType": "image/jpeg"])
        result.content.append(.image(shot.data, mimeType: "image/jpeg"))
        return Outcome(result: result, site: site, step: "Took a screenshot of \(handle) on \(site ?? "a page")")
    }

    // MARK: Actions

    func act(_ tool: String, _ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let handle = arguments["tab"]?.stringValue ?? ""
        var tab: AgentTabInfo
        switch pageTab(handle, grant, state: state) {
        case .value(let resolved): tab = resolved.0
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        if tool == "scroll", (arguments["ref"] == nil) == (arguments["direction"] == nil) { return Self.error("invalidArguments", "scroll takes ref or direction.") }
        if tool == "scroll", arguments["amount"] != nil, arguments["direction"] == nil { return Self.error("invalidArguments", "scroll takes amount only with direction.") }
        await keepActionRate(state)
        var target: AgentRefTarget?
        if let ref = arguments["ref"]?.stringValue {
            guard let record = currentSnapshot(of: tab, state: state), let entry = record.refs[ref], let resolved = AgentRefTarget(ref, fingerprint: entry.fingerprint) else { return Self.stale(handle) }
            target = resolved
        }
        // The element's facts, which the policy reads; `press` without a ref reads the focused element.
        var facts: AgentElementFacts?
        if target != nil || tool == "press" {
            switch await pageScript(.element(target), in: tab, as: AgentElementReply.self, handle: handle) {
            case .outcome(var failure):
                failure.site = site
                return failure
            case .value(let reply):
                if let problem = reply.problem, let failure = Self.unreachable(problem, cover: reply.cover, ref: target?.ref ?? "", handle: handle, tool: tool) {
                    var outcome = failure
                    outcome.site = site
                    return outcome
                }
                facts = reply.facts
            }
        }
        let text = tool == "type" ? arguments["text"]?.stringValue : tool == "press" ? arguments["keys"]?.stringValue : nil
        let keys = arguments["keys"]?.stringValue ?? ""
        let submits = (tool == "click" && facts?.submitsForm == true) || (tool == "type" && arguments["submit"] == .bool(true) && facts?.tag == "input" && facts?.formKey != nil)
            || (tool == "press" && keys == "Enter" && facts?.tag == "input" && facts?.formKey != nil)
        let documents = state.activity(of: tab.id).documents
        let typed = state.typedForms[tab.id].flatMap { $0.document == documents ? $0.keys : nil } ?? []
        let shared = isShared(tab, state: state)
        let access: AgentTabAccess = shared ? .shared(acting: state.handles.actingSharedTabIDs.contains(tab.id)) : .agentTab
        let step = AgentInteraction(tool: tool, tab: access, element: facts, text: text, submits: submits, typedIntoForm: facts?.formKey.map(typed.contains) ?? false, pageHost: tab.url?.host)
        let allowances = AgentAllowances(page: state.pageAllowances[tab.id] == documents, site: site.map(state.siteAllowances.contains) ?? false)
        let sentence = Self.actionSentence(tool, arguments: arguments, facts: facts, site: site)
        var decision: AgentActivityEntry.Decision = .auto
        switch AgentPolicy.decide(.interaction(step), client: clientKind, mode: grant.level, allowances: allowances) {
        case .allow: break
        case .refuse(let rule, let sentence):
            guard let rule else {
                return Outcome(result: AgentToolResult(status: .refused, code: AgentPolicy.readOnlyCode, text: sentence, structured: ["tab": .string(handle), "rule": .string(AgentPolicy.readOnlyCode)]), site: site)
            }
            return Outcome(result: Self.refusal(rule, sentence, handle: handle), site: site)
        case .deny(let rule), .leaveToUser(let rule), .dismiss(let rule):
            return Outcome(result: Self.refusal(rule, AgentPolicy.entry(rule).sentence, handle: handle), site: site)
        case .ask(let ask):
            let card = await stepCard(sentence, ask: ask, tab: tab, handle: handle, grant: grant, state: state, element: facts?.box,
                                      exactText: tool == "type" ? text : nil, typing: tool == "type")
            box.approvalID = card.id
            let answer = await approvals.request(card)
            if let ended = answerOutcome(answer, card: card, handle: handle, grant: grant) {
                var outcome = ended
                outcome.site = site
                outcome.step = "\(answer.allows ? "Allowed" : "Not allowed"): \(sentence)"
                return outcome
            }
            decision = card.needsAuthentication ? .approvedWithTouchID : .approved
            if answer == .allowOnPage { state.pageAllowances[tab.id] = documents }
            if answer == .allowOnSite, let site { state.siteAllowances.insert(site) }
            // The page may have moved on, or the user taken the tab over, while the card waited.
            guard case .value(let current) = pageTab(handle, grant, state: state) else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle), site: site) }
            tab = current.0
            if state.activity(of: tab.id).documents != documents { return Self.stale(handle) }
        }
        let action = AgentPageAction(kind: tool == "select_option" ? "select" : tool, ref: target, text: arguments["text"]?.stringValue, replace: arguments["replace"] == .bool(true) ? true : nil,
                                     submit: arguments["submit"] == .bool(true) ? true : nil, keys: arguments["keys"]?.stringValue,
                                     values: Self.strings(arguments["values"]), count: arguments["count"].flatMap(Self.integer),
                                     modifiers: Self.strings(arguments["modifiers"]), direction: arguments["direction"]?.stringValue,
                                     amount: arguments["amount"].flatMap(Self.integer))
        let reply: AgentActionReply
        switch await pageScript(.act(action), in: tab, as: AgentActionReply.self, handle: handle) {
        case .value(let value): reply = value
        case .outcome(var failure):
            failure.site = site
            return failure
        }
        if let problem = reply.problem {
            var outcome = Self.unreachable(problem, cover: reply.cover, ref: target?.ref ?? "", handle: handle, tool: tool, missing: reply.missing) ?? Self.error("notInteractable", "\(handle) could not \(tool) there.")
            outcome.site = site
            return outcome
        }
        if tool == "type", let key = facts?.formKey { state.typedForms[tab.id] = (documents, typed.union([key])) }
        await settle(tab.id)
        return actionOutcome(tool, reply: reply, handle: handle, ref: target?.ref, tab: tab, site: site, step: sentence, decision: decision)
    }

    /// At most `AgentLimits.actionsPerSecond` actions a second: a faster one waits for its turn.
    private func keepActionRate(_ state: AgentGrantState) async {
        let now = Date()
        state.actionTimes.removeAll { now.timeIntervalSince($0) >= 1 }
        if state.actionTimes.count >= AgentLimits.actionsPerSecond, let oldest = state.actionTimes.first {
            try? await Task.sleep(for: .seconds(max(0, 1 - now.timeIntervalSince(oldest))))
        }
        state.actionTimes.append(Date())
    }

    /// Waits for a load the action started to finish, at most `settleWait`, then `settlePause`, so that the result's events include what followed.
    private func settle(_ tabID: UUID) async {
        try? await Task.sleep(for: .milliseconds(50))
        _ = await Self.poll(for: settleWait) { host.tabs(withIDs: [tabID]).first?.isLoading != true }
        try? await Task.sleep(for: .seconds(settlePause))
    }

    /// Why an action cannot reach an element, as the result says it; nil for a scroll, which reaches what it can.
    static func unreachable(_ problem: String, cover: String?, ref: String, handle: String, tool: String, missing: String? = nil) -> Outcome? {
        let name = ref.isEmpty ? "The focused element" : ref
        switch problem {
        case "stale", "notFound": return stale(handle)
        case "covered" where tool == "scroll": return nil
        case "hidden", "offscreen", "detached":
            return tool == "scroll" && problem != "detached" ? nil : error("notInteractable", "\(name) in \(handle) is not visible on the page.")
        case "disabled": return tool == "scroll" ? nil : error("notInteractable", "\(name) in \(handle) is disabled.")
        case "covered": return error("notInteractable", "\(name) in \(handle) is covered by \(cover.map { AgentUntrusted.wrap($0, url: nil) } ?? "another element"). Close or scroll past what covers it first.")
        case "notEditable": return error("notInteractable", "\(name) in \(handle) is not a field Arch can type into. Use click or select_option.")
        case "notSelect": return error("notInteractable", "\(name) in \(handle) is not a select element. Use click.")
        case "single": return error("invalidArguments", "\(name) in \(handle) takes one value.")
        case "noOption": return error("notFound", "\(name) in \(handle) has no option \(missing.map { AgentUntrusted.wrap($0, url: nil) } ?? "with that value or label").")
        default: return error("notInteractable", "\(name) in \(handle) cannot be reached.")
        }
    }

    /// The step in a sentence for the card and the panel, from the facts the host has: the element as the page names it, and the site.
    static func actionSentence(_ tool: String, arguments: [String: AgentJSON], facts: AgentElementFacts?, site: String?) -> String {
        let element = facts.map { $0.name.isEmpty ? $0.role : "\u{201C}\($0.name)\u{201D}" } ?? "the page"
        let place = site.map { " on \($0)" } ?? ""
        switch tool {
        case "click": return "Click \(element)\(place)"
        case "type": return "Type into \(element)\(place)"
        case "press": return "Press \(arguments["keys"]?.stringValue ?? "keys") in \(element)\(place)"
        case "select_option": return "Choose \((strings(arguments["values"]) ?? []).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")) in \(element)\(place)"
        case "scroll": return facts == nil ? "Scroll \(arguments["direction"]?.stringValue ?? "the page")\(place)" : "Scroll to \(element)\(place)"
        default: return "Hover over \(element)\(place)"
        }
    }

    private func actionOutcome(_ tool: String, reply: AgentActionReply, handle: String, ref: String?, tab: AgentTabInfo, site: String?, step: String, decision: AgentActivityEntry.Decision) -> Outcome {
        let hit = reply.hit.map { AgentUntrusted.wrap($0, url: tab.url) } ?? "the page"
        var structured: [String: AgentJSON] = ["tab": .string(handle), "inputKind": "dom"]
        if let ref { structured["ref"] = .string(ref) }
        if reply.hit != nil { structured["hit"] = .string(hit) }
        let done: String
        switch tool {
        case "click": done = "Clicked \(hit) in \(handle)."
        case "type": done = "Typed into \(hit) in \(handle)."
        case "press": done = "Pressed keys in \(hit) in \(handle)."
        case "select_option":
            let selected = (reply.selected ?? []).map { AgentUntrusted.wrap($0, url: tab.url) }
            structured["selected"] = .array(selected.map(AgentJSON.string))
            done = "Selected \(selected.joined(separator: ", ")) in \(hit) in \(handle)."
        case "scroll":
            structured["scrollX"] = .number(reply.scrollX ?? 0)
            structured["scrollY"] = .number(reply.scrollY ?? 0)
            done = "Scrolled \(handle) to \(Self.number(Int(reply.scrollX ?? 0))), \(Self.number(Int(reply.scrollY ?? 0)))."
        default: done = "Moved the pointer over \(hit) in \(handle)."
        }
        let text = done + " Arch sent DOM events (inputKind dom), which some sites ignore."
        return Outcome(result: AgentToolResult(status: .ok, text: text, structured: .object(structured)), site: site, reportedTabID: nil, step: step, decision: decision)
    }

    /// A list argument's strings.
    static func strings(_ value: AgentJSON?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap(\.stringValue)
    }

    // MARK: Cards

    /// A card for a step the policy asks about, with the host's facts: the step, the tab and site, the element marked on a fresh capture of the viewport when the tab can be captured, and the exact text that would be sent.
    func stepCard(_ sentence: String, ask: AgentAsk, tab: AgentTabInfo, handle: String, grant: AgentGrant, state: AgentGrantState, element: AgentBox?, exactText: String?, typing: Bool,
                  agentSays: String? = nil, kind: AgentApprovalKind = .step) async -> AgentApproval {
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        var exact = exactText
        if typing, !ask.isSensitive, let text = exactText { exact = text + "\n\nAllow on This Page or Allow on \(site ?? "this site") lets the site receive whatever the agent types there without asking again." }
        let capture = await markedCapture(of: tab, element: element)
        return AgentApproval(ownerID: grant.id, clientName: grant.client.displayName, isOutsideClient: clientKind == .outside, kind: kind, rules: ask.rules, isSensitive: ask.isSensitive,
                             offers: AgentApproval.offers(for: ask), action: sentence, tabID: tab.id, tabHandle: handle, site: site, exactText: exact, agentSays: agentSays,
                             capture: capture, connectionID: connectionID, document: state.activity(of: tab.id).documents, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
    }

    /// The viewport with the element's box marked, for the user's card only, so nothing is painted over; nil when the tab cannot be captured.
    private func markedCapture(of tab: AgentTabInfo, element: AgentBox?) async -> NSImage? {
        let image: NSImage? = await withCheckedContinuation { continuation in host.capture(tab.id, fullPage: false) { continuation.resume(returning: $0) } }
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), !AgentScreenshot.isBlank(cgImage) else { return nil }
        var viewport: AgentSize?
        if element != nil, case .value(let boxes) = await pageScript(.boxes, in: tab, as: AgentBoxesReply.self) { viewport = boxes.viewport }
        return AgentScreenshot.marked(cgImage, element: element, viewport: viewport)
    }

    /// The result of a card that did not allow the step: denied, the user's reply, Take Over, timed out, withdrawn, or ended. Nil when the user allowed it.
    func answerOutcome(_ answer: AgentApprovalAnswer, card: AgentApproval, handle: String, grant: AgentGrant) -> Outcome? {
        let structured: AgentJSON = ["tab": .string(handle), "approval": .string(answer.title(site: card.site))]
        switch answer {
        case .allowOnce, .allowOnPage, .allowOnSite, .allowDownloadsFromSite: return nil
        case .deny: return Outcome(result: AgentToolResult(status: .denied, text: "The user denied this step in Arch.", structured: structured), decision: .denied)
        case .denyAndStop:
            stopClient?(grant.id)
            return Outcome(result: AgentToolResult(status: .denied, text: "The user denied this step and stopped this client's work in Arch.", structured: structured), decision: .denied)
        case .reply(let text), .answer(let text):
            return Outcome(result: AgentToolResult(status: .denied, text: "The user did not allow this step and wrote instead: \(text)", structured: ["tab": .string(handle), "reply": .string(text)]), decision: .denied)
        case .takeOver:
            if let tabID = card.tabID { host.showTab(tabID) }
            return Outcome(result: AgentToolResult(status: .denied, text: "The user chose to do this step in \(handle) in Arch. Wait, then take a new snapshot.", structured: structured), decision: .denied)
        case .timedOut: return Outcome(result: AgentToolResult(status: .timeout, code: "notAnswered", text: "The user did not answer in Arch in time, so the step did not run.", structured: structured), decision: .timedOut)
        case .withdrawn: return Self.stale(handle)
        case .ended(let reason): return Outcome(result: AgentToolResult(status: .denied, code: "ended", text: "\(reason) The step did not run.", structured: structured), decision: .denied)
        case .done, .cancel, .tab: return Outcome(result: AgentToolResult(status: .denied, text: "The user did not allow this step.", structured: structured), decision: .denied)
        }
    }
}

/// Screenshots as agents get them (docs/agents.md, Fields the script never reveals; Tools ▸ Limits): the boxes of hidden and personal fields, other sites' frames, and extension frames painted over before scaling and encoding, a full page cut at `AgentLimits.screenshotFullPageCSSHeight` CSS pixels, the longest side at most `AgentLimits.screenshotLongestSide` pixels, and JPEG at `AgentLimits.screenshotJPEGQuality` within `AgentLimits.screenshotBytes`, lower in quality and then in size when needed. The capture on a card, which only the user sees, is marked instead.
enum AgentScreenshot {
    struct Capture {
        var image: CGImage
        var boxes: AgentBoxesReply
        var fullPage: Bool
    }

    struct Shot {
        var data: Data
        var width: Int
        var height: Int
        var painted: Int
        var cutAtCSSHeight: Bool
    }

    /// Whether an engine's capture holds nothing: no pixels, or every sampled pixel transparent, as an empty capture of a tab that no window shows can be.
    static func isBlank(_ image: CGImage) -> Bool {
        guard image.width > 0, image.height > 0 else { return true }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 }
    }

    /// The image with its private boxes painted over, cut, cropped to `element` when given, scaled, and encoded.
    static func encode(_ capture: Capture, element: AgentBox?) -> Shot? {
        let image = capture.image
        let width = image.width, height = image.height
        let cssWidth = capture.fullPage ? capture.boxes.page.w : capture.boxes.viewport.w
        guard cssWidth > 0, let context = context(width: width, height: height) else { return nil }
        let scale = Double(width) / cssWidth
        // JPEG keeps no transparency, so the page sits on white.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1))
        var painted = 0
        for box in capture.boxes.boxes {
            let x = (box.x + (capture.fullPage ? capture.boxes.scrollX : 0)) * scale, y = (box.y + (capture.fullPage ? capture.boxes.scrollY : 0)) * scale
            let rect = CGRect(x: x - 2, y: Double(height) - (y + box.h * scale) - 2, width: box.w * scale + 4, height: box.h * scale + 4)
            guard rect.intersects(CGRect(x: 0, y: 0, width: width, height: height)) else { continue }
            context.fill(rect)
            painted += 1
        }
        guard var result = context.makeImage() else { return nil }
        var cut = false
        let maximumHeight = Int(Double(AgentLimits.screenshotFullPageCSSHeight) * scale)
        if capture.fullPage, result.height > maximumHeight, let top = result.cropping(to: CGRect(x: 0, y: 0, width: result.width, height: maximumHeight)) {
            result = top
            cut = true
        }
        if let element, !capture.fullPage {
            let rect = CGRect(x: element.x * scale - 8, y: element.y * scale - 8, width: element.w * scale + 16, height: element.h * scale + 16)
                .intersection(CGRect(x: 0, y: 0, width: result.width, height: result.height))
            if !rect.isEmpty, let cropped = result.cropping(to: rect.integral) { result = cropped }
        }
        var longest = Double(AgentLimits.screenshotLongestSide)
        var quality = AgentLimits.screenshotJPEGQuality
        while true {
            guard let scaled = scaled(result, longestSide: longest), let data = jpeg(scaled, quality: quality) else { return nil }
            if data.count <= AgentLimits.screenshotBytes { return Shot(data: data, width: scaled.width, height: scaled.height, painted: painted, cutAtCSSHeight: cut) }
            if quality > 0.45 { quality -= 0.15 } else { longest *= 0.75 }
            if longest < 64 { return nil }
        }
    }

    /// The viewport with the element's box outlined, at most 900 pixels wide, for a card.
    static func marked(_ image: CGImage, element: AgentBox?, viewport: AgentSize?) -> NSImage? {
        guard let context = context(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let element, let viewport, viewport.w > 0 {
            let scale = Double(image.width) / viewport.w
            context.setStrokeColor(NSColor.systemOrange.cgColor)
            context.setLineWidth(max(3, scale * 2))
            context.stroke(CGRect(x: element.x * scale - 3, y: Double(image.height) - (element.y + element.h) * scale - 3, width: element.w * scale + 6, height: element.h * scale + 6))
        }
        guard let drawn = context.makeImage(), let small = scaled(drawn, longestSide: 900) else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height))
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func scaled(_ image: CGImage, longestSide: Double) -> CGImage? {
        let longest = Double(max(image.width, image.height))
        guard longest > longestSide else { return image }
        let factor = longestSide / longest
        let width = max(1, Int((Double(image.width) * factor).rounded())), height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = context(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
