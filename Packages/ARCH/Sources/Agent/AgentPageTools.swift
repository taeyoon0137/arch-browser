// The tools that run the agents' page script (docs/agents.md, Page snapshots and refs): `snapshot` with the host's diff, `screenshot` with its limits and the boxes painted over, and the actions `click`, `type`, `press`, `select_option`, `scroll`, and `hover`, each classified by the policy from the element's facts and asked about on a card when a rule or the mode says so. Each script call and capture has `scriptWait`; a page that does not answer gets `timeout`, and a card whose capture does not answer opens without one. Actions go as trusted input where the agent tab offers it (`AgentTrustedInput.swift`) and through DOM events otherwise, and say which (`inputKind`).
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
        let pending = AgentOnce<Result<String?, any Error>>()
        let timeout = Task {
            try await Task.sleep(for: .seconds(wait))
            pending.resume(with: nil)
        }
        defer { timeout.cancel() }
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending.begin(continuation) else { return }
                host.runPageScript(source, world: AgentPageScripts.world, in: tab.id) { pending.resume(with: $0) }
            }
        } onCancel: {
            pending.resume(with: nil)
        }
        guard !Task.isCancelled else { return .outcome(Self.ended) }
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
    private func pageTab(_ handle: String, _ client: AgentToolClient, state: AgentGrantState) -> Resolved<(AgentTabInfo, String)> {
        switch readableTab(handle, client, state: state) {
        case .outcome(let failure): return .outcome(failure)
        case .value(let resolved):
            if case .refused(let rule, let sentence) = AgentPolicy.mayRead(resolved.0.url, allowsAI: allowsAI) {
                return .outcome(Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle)))
            }
            return .value(resolved)
        }
    }

    /// After a script ran: the tab's page may have moved on to one agents do not read, and the user may have taken the tab over.
    private func stillReadable(_ tab: AgentTabInfo, handle: String, reportedURL: String, _ client: AgentToolClient, state: AgentGrantState) -> Outcome? {
        stillReadable(tab, handle: handle, reportedURL: reportedURL) { mayStillRead($0, as: tab, handle: handle, client, state: state) }
    }

    private func stillReadable(_ tab: AgentTabInfo, handle: String, reportedURL: String, mayRead: (AgentTabInfo) -> Bool) -> Outcome? {
        guard let current = host.tabs(withIDs: [tab.id]).first else { return Self.error("tabNotFound", "\(handle) is closed.") }
        guard mayRead(current) else {
            return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle))
        }
        let address = URL(string: reportedURL)
        for url in [current.url, address] {
            if case .refused(let rule, let sentence) = AgentPolicy.mayRead(url, allowsAI: allowsAI) {
                return Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle))
            }
        }
        guard tab.documentID == current.documentID, tab.url == current.url, tab.url == address else {
            return Self.error("pageChanged", "\(handle) changed pages. Read the current page again.")
        }
        return nil
    }

    private func isShared(_ tab: AgentTabInfo, _ client: AgentToolClient, state: AgentGrantState) -> Bool {
        if case .shared = access(to: tab, client, state: state) { return true }
        return false
    }

    /// The engine's capture of the tab, `.some(nil)` when the engine gives no image, and nil when it does not answer within `scriptWait`, as a busy page or a tab no window shows may not.
    private func capture(_ tab: AgentTabInfo, fullPage: Bool) async -> NSImage?? {
        let host = host
        let wait = scriptWait
        return await withCheckedContinuation { continuation in
            let once = AgentOnce<NSImage?>(continuation)
            host.capture(tab.id, fullPage: fullPage) { once.resume(with: .some($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { once.resume(with: nil) }
        }
    }

    // MARK: snapshot

    func snapshot(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState) async -> Outcome {
        let handle = arguments["tab"]?.stringValue ?? ""
        let tab: AgentTabInfo
        switch pageTab(handle, client, state: state) {
        case .value(let resolved): tab = resolved.0
        case .outcome(let failure): return failure
        }
        let shared = isShared(tab, client, state: state)
        let pages = state.activity(of: tab.id).pages
        // A session's Stop and Take Over replace its store, so that an outline begun before them leaves no refs or diff.
        let store = state.snapshots
        return await snapshot(arguments, tab: tab, handle: handle, access: shared ? .shared : .owned, store: store, pages: pages) { current in
            state.snapshots === store && state.activity(of: tab.id).pages == pages && isShared(current, client, state: state) == shared
                && mayStillRead(current, as: tab, handle: handle, client, state: state)
        }
    }

    /// How the client may use the tab that an outline describes, which the outline's header says.
    enum OutlineAccess {
        /// `run` is a hook's agent run, which reads and never acts or asks.
        case owned, shared, run

        var description: String {
            switch self {
            case .owned: return ""
            case .shared: return " \u{00B7} shared by the user: every action here asks"
            case .run: return " \u{00B7} read-only for this hook run"
            }
        }
    }

    func snapshot(_ arguments: [String: AgentJSON], tab: AgentTabInfo, handle: String, access: OutlineAccess, store: AgentSnapshotStore, pages: Int,
                  mayRead: (AgentTabInfo) -> Bool) async -> Outcome {
        guard !Task.isCancelled else { return Self.ended }
        guard mayRead(tab) else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle)) }
        if case .refused(let rule, let sentence) = AgentPolicy.mayRead(tab.url, allowsAI: allowsAI) {
            return Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle))
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let full = arguments["mode"]?.stringValue == "full"
        var target: AgentRefTarget?
        if let ref = arguments["ref"]?.stringValue {
            guard let record = store.current(tab, pages: pages), let entry = record.refs[ref], let resolved = AgentRefTarget(ref, fingerprint: entry.fingerprint) else {
                return Self.stale(handle)
            }
            target = resolved
        }
        let reply: AgentSnapshotReply
        switch await pageScript(.snapshot(full: full, ref: target, shared: access != .owned), in: tab, as: AgentSnapshotReply.self, handle: handle) {
        case .value(let value): reply = value
        case .outcome(var failure):
            failure.site = site
            return failure
        }
        guard !Task.isCancelled else { return Self.ended }
        if let refusal = stillReadable(tab, handle: handle, reportedURL: reply.url, mayRead: mayRead) { return refusal }
        if reply.stale == true { return Self.stale(handle) }
        guard let url = URL(string: reply.url) else { return Self.error("unreadable", "\(handle) has no document Arch can read.") }
        let lines = outline(reply.nodes, full: full, access: access, pageURL: url)
        // A new page's snapshot starts the record again; a subtree's adds its refs to the record of the same page.
        let prior = store.current(tab, pages: pages)
        var record = prior ?? AgentSnapshotRecord(url: url, documentID: tab.documentID, ownerID: tab.agentOwnerID, document: pages, refs: [:], lines: [])
        if target == nil { record.refs = [:] }
        for node in reply.nodes {
            guard let ref = node.ref, let fingerprint = node.fingerprint else { continue }
            record.refs[ref] = AgentSnapshotRecord.Ref(fingerprint: fingerprint, href: node.href.flatMap(URL.init(string:)))
        }
        let previous = prior?.lines
        let number = (store.counts[tab.id] ?? 0) + 1
        store.counts[tab.id] = number
        if target == nil { record.lines = lines }

        var shown = lines
        var note: String?
        if arguments["diff"] == .bool(true) {
            if let previous {
                let difference = lines.difference(from: previous)
                shown = difference.removals.map { if case .remove(_, let line, _) = $0 { return "- " + line } else { return "" } }
                    + difference.insertions.map { if case .insert(_, let line, _) = $0 { return "+ " + line } else { return "" } }
                if shown.isEmpty { note = "Nothing changed since the last snapshot of \(handle)." }
            } else {
                note = "This is the first snapshot of the current document in \(handle), so it shows the whole outline."
            }
        }
        let limit = arguments["max_chars"].flatMap(Self.integer) ?? AgentLimits.snapshotDefaultCharacters
        // The page's title is cut as other page names are, and the header counts toward the result's bytes.
        let title = reply.title.count > AgentLimits.pageNameCharacters ? String(reply.title.prefix(AgentLimits.pageNameCharacters)) + "\u{2026}" : reply.title
        let header = "page \u{201C}\(Self.quoted(title))\u{201D} \(Self.shortAddress(url))"
        var kept: [String] = []
        var characters = 0
        var bytes = header.utf8.count
        for line in shown {
            guard characters + line.count + 1 <= limit, bytes + line.utf8.count + 1 <= AgentLimits.resultTextBytes - Self.resultRoom - 400 else { break }
            kept.append(line)
            characters += line.count + 1
            bytes += line.utf8.count + 1
        }
        store.records[tab.id] = record
        let block = AgentUntrusted.wrap(([header] + kept).joined(separator: "\n"), url: url)
        var text = ["\(handle) \u{00B7} \(tab.engine.rawValue) \u{00B7} snapshot \(number)\(full ? " \u{00B7} full" : "")\(target.map { " \u{00B7} \($0.ref)" } ?? "")\(access.description)", block]
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
    private func outline(_ nodes: [AgentOutlineNode], full: Bool, access: OutlineAccess, pageURL: URL) -> [String] {
        let base = nodes.first?.depth ?? 0
        var lines: [String] = []
        for (index, node) in nodes.enumerated() {
            let isContainer = node.ref == nil && node.role != "text" && node.role != "heading" && node.role != "img" && node.role != "frame"
            if isContainer, !full {
                let next = nodes.dropFirst(index + 1).first
                if next == nil || next!.depth <= node.depth { continue }
            }
            lines.append(String(repeating: "  ", count: max(0, node.depth - base)) + "- " + line(for: node, access: access, pageURL: pageURL))
        }
        return lines
    }

    private func line(for node: AgentOutlineNode, access: OutlineAccess, pageURL: URL) -> String {
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
        if let annotation = annotation(for: node, access: access) { line += " " + annotation }
        return line
    }

    /// What the policy says of an element before the agent tries: P1's fields, file inputs, CAPTCHAs, and the elements a rule asks about. The mode's own cards are named once in `session_info`.
    private func annotation(for node: AgentOutlineNode, access: OutlineAccess) -> String? {
        guard node.ref != nil else { return nil }
        let facts = AgentElementFacts(tag: "", role: node.role, name: node.name ?? "", inputType: node.inputType, valueClass: node.valueClass, isEditable: node.isEditable ?? false,
                                      isFileInput: node.isFileInput ?? false, submitsForm: node.submits ?? false, formFields: node.formFields ?? [])
        // The user picks the files, through hand_to_user; a chooser the page opens asks the user (P7).
        if facts.isFileInput { return "(hand to the user for files)" }
        if AgentPolicy.isChallenge(facts) { return "(CAPTCHA: hand to the user)" }
        if facts.isEditable, facts.valueClass == .hidden { return "(agents do not type here)" }
        if access == .run { return nil }
        if access == .shared { return "(asks the user)" }
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

    func screenshot(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState) async -> Outcome {
        let handle = arguments["tab"]?.stringValue ?? ""
        let tab: AgentTabInfo
        switch pageTab(handle, client, state: state) {
        case .value(let resolved): tab = resolved.0
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let area = arguments["area"]?.stringValue ?? "viewport"
        let shared = isShared(tab, client, state: state)
        var element: AgentBox?
        if area != "viewport", area != "full" {
            guard let record = currentSnapshot(of: tab, state: state), let entry = record.refs[area], let target = AgentRefTarget(area, fingerprint: entry.fingerprint) else {
                return AgentRefTarget(area) == nil ? Self.error("invalidArguments", "area must be viewport, full, or a ref such as e5.") : Self.stale(handle)
            }
            // An agent tab scrolls the element into view; a tab the user shared stays where the user left it.
            switch await pageScript(.element(target, scroll: !shared), in: tab, as: AgentElementReply.self, handle: handle) {
            case .outcome(var failure):
                failure.site = site
                return failure
            case .value(let reply):
                if reply.problem == "stale" || reply.problem == "notFound" { return Self.stale(handle) }
                element = reply.facts?.box
                if shared, let box = element, let viewport = reply.viewport, box.x + box.w <= 0 || box.y + box.h <= 0 || box.x >= viewport.w || box.y >= viewport.h {
                    return Self.error("notInteractable", "\(area) in \(handle) is outside the viewport, and Arch does not scroll a tab the user shared for a screenshot. Take one of the viewport, or scroll there first, which asks the user.")
                }
            }
        }
        let full = area == "full"
        var capture: AgentScreenshot.Capture?
        // The boxes are read before and after each capture; a page whose private fields moved meanwhile gets one more capture, then no screenshot.
        for _ in 0 ..< 2 {
            let before: AgentBoxesReply
            switch await pageScript(.boxes(shared: shared), in: tab, as: AgentBoxesReply.self, handle: handle) {
            case .value(let reply): before = reply
            case .outcome(var failure):
                failure.result.content.append(.text("A tab whose page does not answer gets no screenshot."))
                failure.site = site
                return failure
            }
            if let refusal = stillReadable(tab, handle: handle, reportedURL: before.url, client, state: state) { return refusal }
            // Chromium's full-page capture (`captureBeyondViewport`) lays the page out again at its full height, where a fixed dialog or a field below a viewport-high banner moves away from the boxes read in the page's own layout, and the page is back before the boxes are read again. So a Chromium page with anything to paint over gets no full-page screenshot.
            if full, tab.engine == .chromium, !before.boxes.isEmpty {
                return Outcome(result: AgentToolResult(status: .error, code: "notAvailable",
                                                       text: "\(handle) has private fields or frames that Arch paints over, and Chromium's full-page capture lays the page out again, which can move them, so Arch gives no full-page screenshot of it. Take screenshots of the viewport while scrolling.",
                                                       structured: ["tab": .string(handle)]), site: site)
            }
            guard let answer = await self.capture(tab, fullPage: full) else {
                return Outcome(result: AgentToolResult(status: .timeout, code: "notResponding", text: "\(handle) does not respond to Arch's capture, so it gives no screenshot. Read it with snapshot.",
                                                       structured: ["tab": .string(handle)]), site: site)
            }
            guard let image = answer, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), !AgentScreenshot.isBlank(cgImage) else {
                return Outcome(result: AgentToolResult(status: .error, code: "notVisible", text: "\(handle) cannot be captured while no window shows it. Read it with snapshot.",
                                                       structured: ["tab": .string(handle)]), site: site)
            }
            guard case .value(let after) = await pageScript(.boxes(shared: shared), in: tab, as: AgentBoxesReply.self, handle: handle) else { break }
            if let refusal = stillReadable(tab, handle: handle, reportedURL: after.url, client, state: state) { return refusal }
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
        var structured: [String: AgentJSON] = ["tab": .string(handle), "area": .string(area), "width": .number(Double(shot.width)), "height": .number(Double(shot.height)),
                                               "painted": .number(Double(shot.painted)), "cut": .bool(shot.cutAtCSSHeight), "mimeType": "image/jpeg"]
        // The page the capture shows, reduced as `read_text` gives it, from which an API-key session names the image's source.
        if let url = URL(string: capture.boxes.url) ?? tab.url { structured["url"] = .string(AgentAddress.reduced(url).absoluteString) }
        var result = AgentToolResult(status: .ok, text: text, structured: .object(structured))
        result.content.append(.image(shot.data, mimeType: "image/jpeg"))
        return Outcome(result: result, site: site, step: "Took a screenshot of \(handle) on \(site ?? "a page")")
    }

    // MARK: Actions

    func act(_ tool: String, _ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let handle = arguments["tab"]?.stringValue ?? ""
        var tab: AgentTabInfo
        switch pageTab(handle, client, state: state) {
        case .value(let resolved): tab = resolved.0
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        if tool == "scroll", (arguments["ref"] == nil) == (arguments["direction"] == nil) { return Self.error("invalidArguments", "scroll takes ref or direction.") }
        if tool == "scroll", arguments["amount"] != nil, arguments["direction"] == nil { return Self.error("invalidArguments", "scroll takes amount only with direction.") }
        await keepActionRate(state)
        if Task.isCancelled { return Self.ended }
        var target: AgentRefTarget?
        if let ref = arguments["ref"]?.stringValue {
            guard let record = currentSnapshot(of: tab, state: state), let entry = record.refs[ref], let resolved = AgentRefTarget(ref, fingerprint: entry.fingerprint) else { return Self.stale(handle) }
            target = resolved
        }
        let access = self.access(to: tab, client, state: state)
        let shared = access != .agentTab
        // The element's facts, which the policy reads; `press` without a ref reads the focused element. An agent tab scrolls the element into view to check that nothing covers it; a tab the user shared does not move before the user decides, and the action checks the cover once allowed.
        var facts: AgentElementFacts?
        if target != nil || tool == "press" {
            switch await pageScript(.element(target, scroll: !shared), in: tab, as: AgentElementReply.self, handle: handle) {
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
        if Task.isCancelled { return Self.ended }
        let text = tool == "type" ? arguments["text"]?.stringValue : tool == "press" ? arguments["keys"]?.stringValue : nil
        let keys = arguments["keys"]?.stringValue ?? ""
        // Enter or Space on a control is a click on it (`AgentPolicy.pressActivates`).
        let clicks = tool == "click" || (tool == "press" && facts.map { AgentPolicy.pressActivates(keys, on: $0) } == true)
        let submits = (clicks && facts?.submitsForm == true) || (tool == "type" && arguments["submit"] == .bool(true) && facts?.tag == "input" && facts?.formKey != nil)
            || (tool == "press" && keys == "Enter" && facts?.tag == "input" && facts?.formKey != nil)
        // The page the policy decides for: its count and address, which must still hold when the step runs after a card.
        let pages = state.activity(of: tab.id).pages
        let address = tab.url
        let typed = state.typedForms[tab.id].flatMap { $0.page == pages ? $0.keys : nil } ?? []
        // `type` with `submit` sends what it types itself.
        let typedIntoForm = (tool == "type" && submits) || (facts?.formKey.map(typed.contains) ?? false)
        // An in-app session's scope decides Act in Agent Tabs' free steps and P14; an outside client has none.
        let siteInScope = client.kind != .inApp || (tab.url.flatMap { client.inAppSession?.scope.contains($0) } ?? false)
        let step = AgentInteraction(tool: tool, tab: access, siteInScope: siteInScope, element: facts, text: text, submits: submits, typedIntoForm: typedIntoForm, pageHost: tab.url?.host)
        let allowances = AgentAllowances(page: state.pageAllowances[tab.id] == pages, site: site.map(state.siteAllowances.contains) ?? false)
        let sentence = Self.actionSentence(tool, arguments: arguments, facts: facts, site: site, submits: submits && tool != "click")
        var decision: AgentActivityEntry.Decision = .auto
        // The document the policy decides for, which a reload at the same address replaces.
        let document = tab.documentID
        switch AgentPolicy.decide(.interaction(step), client: client.kind, mode: client.level, allowances: allowances) {
        case .allow: break
        case .refuse(let rule, let sentence):
            guard let rule else {
                return Outcome(result: AgentToolResult(status: .refused, code: AgentPolicy.readOnlyCode, text: sentence, structured: ["tab": .string(handle), "rule": .string(AgentPolicy.readOnlyCode)]), site: site)
            }
            return Outcome(result: Self.refusal(rule, sentence, handle: handle), site: site)
        case .deny(let rule), .leaveToUser(let rule), .dismiss(let rule):
            return Outcome(result: Self.refusal(rule, AgentPolicy.entry(rule).sentence, handle: handle), site: site)
        case .ask(let ask):
            let card = await stepCard(sentence, ask: ask, tab: tab, handle: handle, client: client, state: state, element: facts?.box,
                                      exactText: tool == "type" ? text : nil, typing: tool == "type")
            box.approvalID = card.id
            let answer = await request(card, for: client)
            if let ended = answerOutcome(answer, card: card, handle: handle, client: client) {
                var outcome = ended
                outcome.site = site
                outcome.step = "\(answer.allows ? "Allowed" : "Not allowed"): \(sentence)"
                return outcome
            }
            decision = card.needsAuthentication ? .approvedWithTouchID : .approved
            if answer == .allowOnPage { state.pageAllowances[tab.id] = pages }
            if answer == .allowOnSite, let site { state.siteAllowances.insert(site) }
            if Task.isCancelled { return Self.ended }
            // The page may have moved on, or the user taken the tab over, while the card waited: the step runs only on the page the user allowed it on.
            guard case .value(let current) = pageTab(handle, client, state: state) else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle), site: site) }
            tab = current.0
            if state.activity(of: tab.id).pages != pages || tab.url != address || tab.documentID != document { return Self.stale(handle) }
        }
        // A session whose turn ended or that the user took over meanwhile acts on nothing.
        guard !Task.isCancelled, client.isCurrent else { return Self.ended }
        var reply: AgentActionReply
        var trusted = false
        // The form `type` typed into, for P5: also when the action fails once trusted text went, since the field may hold it.
        let tabID = tab.id
        func recordTyping() {
            if tool == "type", let key = facts?.formKey { state.typedForms[tabID] = (pages, typed.union([key])) }
        }
        switch await trustedAction(tool, arguments, tab: tab, handle: handle, access: access, target: target, facts: facts, state: state, didType: recordTyping) {
        case .ended(var failure):
            failure.site = site
            return failure
        case .done(let value, let isTrusted):
            reply = value
            trusted = isTrusted
        case .useDOM:
            let action = AgentPageAction(kind: tool == "select_option" ? "select" : tool, ref: target, text: arguments["text"]?.stringValue, replace: arguments["replace"] == .bool(true) ? true : nil,
                                         submit: arguments["submit"] == .bool(true) ? true : nil, keys: arguments["keys"]?.stringValue,
                                         values: Self.strings(arguments["values"]), count: arguments["count"].flatMap(Self.integer),
                                         modifiers: Self.strings(arguments["modifiers"]), direction: arguments["direction"]?.stringValue,
                                         amount: arguments["amount"].flatMap(Self.integer))
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
        }
        recordTyping()
        await settle(tab.id)
        // A wheel turn scrolls as the page lets it, so the position comes once the page settled.
        if trusted, tool == "scroll", case .value(let position) = await pageScript(.inputState(token: nil, need: nil, cancelRest: false, disarm: false), in: tab, as: AgentInputState.self, handle: handle) {
            reply.scrollX = position.scrollX
            reply.scrollY = position.scrollY
        }
        return actionOutcome(tool, reply: reply, handle: handle, ref: target?.ref, tab: tab, site: site, step: sentence, decision: decision, trusted: trusted)
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

    /// The step in a sentence for the card, the Touch ID prompt, and the panel, from the facts the host has: the element as the page names it, in quotes whose closing quote inside is doubled, the site, and whether the step submits the element's form by Enter.
    static func actionSentence(_ tool: String, arguments: [String: AgentJSON], facts: AgentElementFacts?, site: String?, submits: Bool = false) -> String {
        let element = facts.map { $0.name.isEmpty ? $0.role : "\u{201C}\(quoted($0.name))\u{201D}" } ?? "the page"
        let place = site.map { " on \($0)" } ?? ""
        let submission = submits ? " and submit the form" : ""
        switch tool {
        case "click": return "Click \(element)\(place)"
        case "type": return "Type into \(element)\(place)\(submission)"
        case "press": return "Press \u{201C}\(quoted(arguments["keys"]?.stringValue ?? ""))\u{201D} in \(element)\(place)\(submission)"
        case "select_option": return "Choose \((strings(arguments["values"]) ?? []).map { "\u{201C}\(quoted($0))\u{201D}" }.joined(separator: ", ")) in \(element)\(place)"
        case "scroll": return facts == nil ? "Scroll \(arguments["direction"]?.stringValue ?? "the page")\(place)" : "Scroll to \(element)\(place)"
        default: return "Hover over \(element)\(place)"
        }
    }

    private func actionOutcome(_ tool: String, reply: AgentActionReply, handle: String, ref: String?, tab: AgentTabInfo, site: String?, step: String, decision: AgentActivityEntry.Decision,
                               trusted: Bool) -> Outcome {
        let hit = reply.hit.map { AgentUntrusted.wrap($0, url: tab.url) } ?? "the page"
        var structured: [String: AgentJSON] = ["tab": .string(handle), "inputKind": trusted ? "trusted" : "dom"]
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
        let text = done + (trusted ? " Arch sent it as the user's own input (inputKind trusted)." : " Arch sent DOM events (inputKind dom), which some sites ignore.")
        return Outcome(result: AgentToolResult(status: .ok, text: text, structured: .object(structured)), site: site, reportedTabID: nil, step: step, decision: decision)
    }

    /// A list argument's strings.
    static func strings(_ value: AgentJSON?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap(\.stringValue)
    }

    // MARK: Cards

    /// A card for a step the policy asks about, with the host's facts: the step, the tab and site, the element marked on a fresh capture of the viewport when the tab can be captured, and the exact text that would be sent.
    func stepCard(_ sentence: String, ask: AgentAsk, tab: AgentTabInfo, handle: String, client: AgentToolClient, state: AgentGrantState, element: AgentBox?, exactText: String?, typing: Bool,
                  agentSays: String? = nil, kind: AgentApprovalKind = .step) async -> AgentApproval {
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        // The page the card is about, as before the capture, so that a page that moves on meanwhile withdraws it.
        let pages = state.activity(of: tab.id).pages
        let capture = await markedCapture(of: tab, element: element)
        var card = AgentApproval(ownerID: client.id, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: kind, rules: ask.rules, isSensitive: ask.isSensitive,
                                 offers: AgentApproval.offers(for: ask), action: sentence, tabID: tab.id, tabHandle: handle, site: site, exactText: exactText, agentSays: agentSays,
                                 capture: capture, connectionID: connectionID, document: pages, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        card.documentID = tab.documentID
        if typing, !ask.isSensitive { card.exactTextNote = "Allow on This Page or Allow on \(site ?? "this site") lets the site receive whatever the agent types there without asking again." }
        return card
    }

    /// The viewport with the element's box marked, for the user's card only, so nothing is painted over; nil when the tab cannot be captured or does not answer in time, and the card then opens without one.
    private func markedCapture(of tab: AgentTabInfo, element: AgentBox?) async -> NSImage? {
        guard let answer = await capture(tab, fullPage: false), let image = answer, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil), !AgentScreenshot.isBlank(cgImage) else { return nil }
        var viewport: AgentSize?
        if element != nil, case .value(let boxes) = await pageScript(.boxes(shared: false), in: tab, as: AgentBoxesReply.self) { viewport = boxes.viewport }
        return AgentScreenshot.marked(cgImage, element: element, viewport: viewport)
    }

    /// The result of a card that did not allow the step: denied, the user's reply, Take Over, timed out, withdrawn, or ended. Nil when the user allowed it.
    func answerOutcome(_ answer: AgentApprovalAnswer, card: AgentApproval, handle: String, client: AgentToolClient) -> Outcome? {
        let structured: AgentJSON = ["tab": .string(handle), "approval": .string(answer.title(site: card.site))]
        switch answer {
        case .allowOnce, .allowOnPage, .allowOnSite, .allowDownloadsFromSite, .allowOnTab: return nil
        case .deny: return Outcome(result: AgentToolResult(status: .denied, text: "The user denied this step in Arch.", structured: structured), decision: .denied)
        case .denyAndStop:
            stopClient?(client.id)
            return Outcome(result: AgentToolResult(status: .denied, text: "The user denied this step and stopped this client's work in Arch.", structured: structured), decision: .denied)
        case .reply(let text), .answer(let text):
            return Outcome(result: AgentToolResult(status: .denied, text: "The user did not allow this step and wrote instead: \(text)", structured: ["tab": .string(handle), "reply": .string(text)]), decision: .denied)
        case .takeOver:
            // On a session's card, Take Over pauses the session as the panel's Take Over does, so its agent waits until Hand Back.
            client.inAppSession?.takeOver()
            if let tabID = card.tabID { host.showTab(tabID) }
            return Outcome(result: AgentToolResult(status: .denied, text: "The user chose to do this step in \(handle) in Arch. Wait, then take a new snapshot.", structured: structured), decision: .denied)
        case .timedOut: return Outcome(result: AgentToolResult(status: .timeout, code: "notAnswered", text: "The user did not answer in Arch in time, so the step did not run.", structured: structured), decision: .timedOut)
        case .withdrawn: return Self.stale(handle)
        case .ended(let reason): return Outcome(result: AgentToolResult(status: .denied, code: "ended", text: "\(reason) The step did not run.", structured: structured), decision: .denied)
        case .done, .cancel, .tab: return Outcome(result: AgentToolResult(status: .denied, text: "The user did not allow this step.", structured: structured), decision: .denied)
        }
    }
}

/// Screenshots as agents get them (docs/agents.md, Fields the script never reveals; Tools ▸ Limits): the boxes of hidden and personal fields, other sites' frames, extension frames, and file inputs that hold files, and in a tab the user shared every field's, painted over before scaling and encoding, a full page cut at `AgentLimits.screenshotFullPageCSSHeight` CSS pixels, the longest side at most `AgentLimits.screenshotLongestSide` pixels, and JPEG at `AgentLimits.screenshotJPEGQuality` within `AgentLimits.screenshotBytes`, lower in quality and then in size when needed. The capture on a card, which only the user sees, is marked instead.
enum AgentScreenshot {
    /// An engine's capture of the tab, with the boxes to cover and whether it shows the full page.
    struct Capture {
        var image: CGImage
        var boxes: AgentBoxesReply
        var fullPage: Bool
    }

    /// The encoded screenshot that the client receives, with its size in pixels.
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
