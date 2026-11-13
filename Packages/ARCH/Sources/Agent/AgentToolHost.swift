// The tool host: where every tool call runs and is checked, the same code for every client (agent decision 5). This build runs, for an outside client's grant, the tools that need no page script: `session_info`, `list_spaces`, `list_tabs`, `open_tab` and `navigate` with an address or a history step, `close_tab`, `read_text`, `wait_for`, `list_downloads`, `search_history`, and `guide`, with the events since the client's previous call, the limits, and the rules in `AgentPolicy`, and for an in-app session (`AgentToolClient`) the tools that need no agent tab. Plan task VII.13 adds snapshots, refs, actions, and approvals.
import AgentControl
import ARCHEngine
import Foundation

@MainActor struct AgentToolHost {
    /// The tools this build runs; `tools/list` lists only these, and the others answer that they are not available yet.
    static let servedTools = ["session_info", "list_spaces", "list_tabs", "open_tab", "navigate", "close_tab", "read_text", "wait_for", "list_downloads", "search_history", "guide"]

    let host: any AgentBrowserHost
    /// Whether AI may read a page at this address: the site exclusions of `ai.json` (docs/agents.md, Site exclusions).
    let allowsAI: (URL) -> Bool
    var now: () -> Date = Date.init
    /// How long `navigate` and `open_tab` wait for the document (docs/agents.md, Tools ▸ Limits).
    var loadWait = TimeInterval(AgentLimits.toolWaitSeconds)
    /// How long the page may take to answer a read before the call says it does not respond.
    var scriptWait: TimeInterval = 10

    /// What a call did, for the result and the activity log.
    struct Outcome {
        var result: AgentToolResult
        /// The page's site for the activity log, a host at most.
        var site: String?
        /// The tab whose load the call waited for and reported, whose load events it leaves out.
        var reportedTabID: UUID?
    }

    /// Every served tool in catalog order, for `tools/list` before a grant, since the grant sheet may allow any of them.
    static var toolsBeforeGrant: [AgentTool] {
        AgentToolCatalog.tools.filter { servedTools.contains($0.name) }
    }

    /// The served tools that a grant of `level` with `scopes` can ever call, in catalog order, for `tools/list`: Read Only leaves out interactions other than `scroll` and `hover` and sensitive steps, and `search_history` needs its scope.
    static func tools(for level: AgentAccessLevel, scopes: AgentGrantScopes) -> [AgentTool] {
        AgentToolCatalog.tools.filter { tool in
            guard servedTools.contains(tool.name) else { return false }
            if tool.traits.contains(.needsHistoryScope), !scopes.searchHistory { return false }
            switch tool.toolClass {
            case .reads, .navigates: return true
            case .interacts: return level != .readOnly || tool.traits.contains(.allowedInReadOnly)
            case .sensitive: return level != .readOnly
            }
        }
    }

    /// Runs a call for the grant and adds the events since the client's previous call.
    func run(_ call: AgentToolCall, for grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        let start = state.lastSequence
        var outcome = await outcome(of: call, for: grant, state: state)
        // A result that would still pass its limit, as a page's very long address can make one, says so in its place, so that no result takes a client's connection past the frame limit.
        if outcome.result.text.utf8.count > AgentLimits.resultTextBytes { outcome.result = Self.tooLong(outcome.result, tool: call.name) }
        attachEvents(to: &outcome, since: start, state: state)
        return outcome
    }

    /// The bytes a result leaves, within its limit, for the sentences around a page's text and for the events.
    static let resultRoom = 2_000

    private func outcome(of call: AgentToolCall, for grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        guard let tool = AgentToolCatalog.tool(named: call.name) else {
            return Self.error("unknownTool", "Arch has no tool named \(call.name).")
        }
        // The harness checks guide's arguments itself, so an unknown topic is answered with the topic names, as arch-cli guide answers it, and a null topic gives the guide.
        if tool.name != "guide", let problem = Self.problem(with: call.arguments, for: tool) {
            return Self.error("invalidArguments", problem)
        }
        guard state.countCall(at: now()) else {
            return Outcome(result: AgentToolResult(status: .error, code: "limitReached",
                                                   text: "This client made \(Self.number(AgentLimits.toolCallsPerGrantPerDay)) tool calls today, the most for a day. Its calls work again tomorrow.",
                                                   structured: ["limits": ["toolCallsPerDay": .number(Double(AgentLimits.toolCallsPerGrantPerDay))]]))
        }
        let arguments = call.arguments
        switch tool.name {
        case "session_info": return Outcome(result: sessionInfo(grant, state: state))
        case "list_spaces": return Outcome(result: listSpaces(grant, state: state))
        case "list_tabs": return Outcome(result: listTabs(shared: arguments["scope"]?.stringValue == "shared", grant, state: state))
        case "open_tab": return await openTab(arguments, grant, state: state)
        case "navigate": return await navigate(arguments, grant, state: state)
        case "close_tab": return closeTab(arguments, grant, state: state)
        case "read_text": return await readText(arguments, grant, state: state)
        case "wait_for": return await waitFor(arguments, grant, state: state)
        case "list_downloads": return Outcome(result: AgentToolResult(status: .ok, text: "No downloads. Arch refuses downloads from agent tabs until it can ask the user about each one.", structured: ["downloads": []]))
        case "search_history": return await searchHistory(arguments, grant)
        case "guide": return Outcome(result: AgentHarness.guideResult(arguments: arguments))
        default: return Self.notAvailable("This build of Arch does not run \(tool.name) yet.")
        }
    }

    /// Checks the arguments against the tool's parameters, as its schema states them: no unknown names, the required ones present, and values of the right kind.
    static func problem(with arguments: [String: AgentJSON], for tool: AgentTool) -> String? {
        for name in arguments.keys.sorted() where !tool.parameters.contains(where: { $0.name == name }) {
            return "\(tool.name) takes no argument named \(name)."
        }
        for parameter in tool.parameters {
            guard let value = arguments[parameter.name] else {
                if parameter.isRequired { return "\(tool.name) needs \(parameter.name)." }
                continue
            }
            switch parameter.kind {
            case .choice(let choices):
                guard let text = value.stringValue, choices.contains(text) else { return "\(parameter.name) must be one of \(choices.joined(separator: ", "))." }
            case .string:
                guard value.stringValue != nil else { return "\(parameter.name) must be text." }
            case .boolean:
                guard case .bool = value else { return "\(parameter.name) must be true or false." }
            case .integer:
                guard case .number(let number) = value, number.rounded() == number else { return "\(parameter.name) must be a whole number." }
                if let minimum = parameter.minimum, number < Double(minimum) { return "\(parameter.name) must be at least \(minimum)." }
                if let maximum = parameter.maximum, number > Double(maximum) { return "\(parameter.name) must be at most \(maximum)." }
            case .list:
                guard case .array(let items) = value, !items.isEmpty, items.allSatisfy({ $0.stringValue != nil }) else { return "\(parameter.name) must be a list of text." }
            }
            if let pattern = parameter.pattern, let text = value.stringValue, text.range(of: pattern, options: .regularExpression) == nil {
                return "\(parameter.name) must look like t1."
            }
        }
        return nil
    }

    // MARK: Session and lists

    private func sessionInfo(_ grant: AgentGrant, state: AgentGrantState) -> AgentToolResult {
        let persona = personaName(of: grant)
        let space = space(of: grant)
        let spaceHandle = space.map { state.handles.spaces.handle(for: $0.id) }
        let openTabs = host.agentTabs(of: grant.id).count
        let asks = Self.whatAsks(grant.level)
        // A Persona's place reads as "Persona / Space" (Personas, history, and permissions).
        let place = space.map { "\(persona) / \($0.name) (\(spaceHandle ?? ""))" } ?? "the \(persona) Persona"
        var lines = ["This client has \(grant.level.title) access in \(place)."]
        lines.append("Site scope: none. An outside client navigates freely in its own agent tabs, which open in its agent folder \u{201C}\(Self.folderName(for: grant.client))\u{201D}.")
        lines.append("Agent tabs: \(openTabs == 0 ? "none" : String(openTabs)) open, at most \(AgentLimits.agentTabs) at once.")
        lines.append("Limits: \(Self.number(AgentLimits.toolCallsPerGrantPerDay)) tool calls a day for this grant, \(AgentLimits.actionsPerSecond) actions a second, \(AgentLimits.toolWaitSeconds) seconds per wait.")
        lines.append(contentsOf: asks)
        let structured: AgentJSON = [
            "mode": .string(grant.level.rawValue),
            "persona": .string(persona),
            "space": space.map { ["handle": .string(spaceHandle ?? ""), "name": .string($0.name)] } ?? .null,
            "siteScope": .null,
            "agentTabs": .number(Double(openTabs)),
            "limits": ["agentTabs": .number(Double(AgentLimits.agentTabs)), "toolCallsPerDay": .number(Double(AgentLimits.toolCallsPerGrantPerDay)), "actionsPerSecond": .number(Double(AgentLimits.actionsPerSecond))],
            "asks": .array(asks.map(AgentJSON.string)),
            "scopes": ["searchHistory": .bool(grant.scopes.searchHistory), "startTasks": .bool(grant.scopes.startTasks)],
        ]
        return AgentToolResult(status: .ok, text: lines.joined(separator: "\n"), structured: structured)
    }

    /// What asks the user or is refused at each level, for an outside client (docs/agents.md, Modes).
    static func whatAsks(_ level: AgentAccessLevel) -> [String] {
        let interactions: String
        switch level {
        case .readOnly: interactions = "Interactions other than scroll and hover are refused, and so are sensitive steps such as request_approval."
        case .askBeforeActing: interactions = "Each interaction asks the user first, and sensitive steps such as request_approval always ask."
        case .actInAgentTabs: interactions = "Interactions in your own agent tabs run without asking; elsewhere they ask once per site, and sensitive steps such as request_approval always ask."
        }
        return [
            "Reading and navigating in your own agent tabs run without asking. \(interactions)",
            "Arch refuses typing passwords, codes, or card details, sites excluded from AI, internal pages, downloads, other apps, and tabs you were not given. Hand such steps to the user with hand_to_user.",
        ]
    }

    private func listSpaces(_ grant: AgentGrant, state: AgentGrantState) -> AgentToolResult {
        let spaces = host.spaces(in: grant.personaID)
        let agentTabs = host.agentTabs(of: grant.id)
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for space in spaces {
            let handle = state.handles.spaces.handle(for: space.id)
            let count = agentTabs.filter { $0.spaceID == space.id }.count
            rows.append(["handle": .string(handle), "name": .string(space.name), "agentTabs": .number(Double(count))])
            lines.append("\(handle)  \(space.name)  \(count == 1 ? "1 agent tab" : "\(count) agent tabs")")
        }
        let persona = personaName(of: grant)
        let summary = spaces.isEmpty ? "The \(persona) Persona has no spaces." : "The \(persona) Persona has \(spaces.count == 1 ? "1 space" : "\(spaces.count) spaces")."
        return AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"), structured: ["spaces": .array(rows)])
    }

    /// The client's agent tabs, or the tabs the user shared, in sidebar order. A tab on a site excluded from AI, or on a page agents do not read, is listed without its title or address (rule P16).
    private func listTabs(shared: Bool, _ grant: AgentGrant, state: AgentGrantState) -> AgentToolResult {
        let tabs = shared ? host.tabs(withIDs: Set(state.handles.sharedTabIDs)) : host.agentTabs(of: grant.id)
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for tab in tabs {
            let handle = state.handles.tabs.handle(for: tab.id)
            let excluded = !AgentPolicy.showsTitle(of: tab.url, allowsAI: allowsAI)
            var row: [String: AgentJSON] = ["handle": .string(handle), "excluded": .bool(excluded)]
            var line = handle
            if excluded {
                line += "  (a page agents do not read)"
            } else {
                let reduced = tab.url.map(AgentAddress.reduced)
                let title = Self.pageName(tab.title, url: tab.url)
                row["title"] = .string(title)
                if shared {
                    row["host"] = tab.url?.host.map(AgentJSON.string) ?? .null
                    line += "  \(title)  \(tab.url?.host ?? "")"
                } else {
                    row["url"] = reduced.map { .string($0.absoluteString) } ?? .null
                    row["loading"] = .bool(tab.isLoading)
                    row["engine"] = .string(tab.engine.rawValue)
                    line += "  \(title)  \(reduced?.absoluteString ?? "")\(tab.isLoading ? "  loading" : "")"
                }
            }
            rows.append(.object(row))
            lines.append(line)
        }
        let kind = shared ? "shared" : "agent"
        let summary: String
        switch tabs.count {
        case 0: summary = shared ? "The user has shared no tabs with this client." : "This client has no agent tabs open."
        case 1: summary = "1 \(kind) tab."
        default: summary = "\(tabs.count) \(kind) tabs."
        }
        let list = Self.fitted(summary, lines, rows, noun: "tab")
        var structured: [String: AgentJSON] = ["scope": .string(kind), "tabs": .array(list.rows)]
        if let limits = list.limits { structured["limits"] = limits }
        return AgentToolResult(status: .ok, text: list.text, structured: .object(structured))
    }

    /// A list result's text and rows within the result's limit, with room for the events: the last rows go while the text is too long, as with long addresses, and a last line and `limits` say how many.
    static func fitted(_ summary: String, _ lines: [String], _ rows: [AgentJSON], noun: String) -> (text: String, rows: [AgentJSON], limits: AgentJSON?) {
        // The last line takes at most 100 bytes.
        let room = AgentLimits.resultTextBytes - resultRoom - 100
        var used = summary.utf8.count
        var kept = 0
        for line in lines {
            used += line.utf8.count + 1
            guard used <= room else { break }
            kept += 1
        }
        let left = lines.count - kept
        guard left > 0 else { return (([summary] + lines).joined(separator: "\n"), rows, nil) }
        let note = "\(left) more \(left == 1 ? noun : "\(noun)s") left out to keep the result within its limit."
        return (([summary] + lines.prefix(kept) + [note]).joined(separator: "\n"), Array(rows.prefix(kept)),
                ["resultTextBytes": .number(Double(AgentLimits.resultTextBytes)), "leftOut": .number(Double(left))])
    }

    // MARK: Navigation

    private func openTab(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        if arguments["ref"] != nil || arguments["tab"] != nil {
            if arguments["url"] != nil { return Self.error("invalidArguments", "open_tab takes url or ref, not both.") }
            return Self.notAvailable("Links from snapshots come with the snapshot tool, which this build of Arch does not run yet. Give url.")
        }
        guard let text = arguments["url"]?.stringValue else { return Self.error("invalidArguments", "open_tab needs url or ref.") }
        let url: URL
        switch writtenAddress(text) {
        case .value(let written): url = written
        case .outcome(let refusal): return refusal
        }
        let openTabs = host.agentTabs(of: grant.id)
        guard openTabs.count < AgentLimits.agentTabs else {
            return Outcome(result: AgentToolResult(status: .error, code: "limitReached",
                                                   text: "This client has \(AgentLimits.agentTabs) agent tabs open, the most at once. Close one with close_tab first.",
                                                   structured: ["limits": ["agentTabs": .number(Double(AgentLimits.agentTabs))]]), site: AgentActivityEntry.site(of: url))
        }
        guard let space = space(of: grant) else { return Self.error("noSpace", "The \(personaName(of: grant)) Persona has no space for agent tabs.") }
        let engine = arguments["engine"]?.stringValue.map { $0 == "webkit" ? EngineKind.webKit : EngineKind.chromium }
        let owner = AgentTabOwner(id: grant.id, spaceID: space.id, folderName: Self.folderName(for: grant.client))
        guard let tab = host.openAgentTab(at: url, engine: engine, for: owner) else { return Self.error("noSpace", "Arch could not open an agent tab in this client's space.") }
        let handle = state.handles.tabs.handle(for: tab.id)
        let before = AgentTabActivity()
        let loaded = await waitForLoad(of: tab.id, grant, state: state, since: before)
        var outcome = loadOutcome(of: tab.id, handle: handle, grant, state: state, since: before, didLoad: loaded, opened: true)
        outcome.site = AgentActivityEntry.site(of: url)
        return outcome
    }

    private func navigate(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        let given = ["url", "ref", "action"].filter { arguments[$0] != nil }
        guard given.count == 1 else { return Self.error("invalidArguments", "navigate takes one of url, ref, or action.") }
        if given == ["ref"] { return Self.notAvailable("Links from snapshots come with the snapshot tool, which this build of Arch does not run yet. Give url or action.") }
        let tab: AgentTabInfo, handle: String
        switch agentTab(arguments["tab"]?.stringValue ?? "", grant, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        let navigation: AgentNavigation
        if let text = arguments["url"]?.stringValue {
            switch writtenAddress(text) {
            case .value(let url): navigation = .load(url)
            case .outcome(let refusal): return refusal
            }
        } else {
            switch arguments["action"]?.stringValue {
            case "back":
                guard tab.canGoBack else { return Self.error("navigationFailed", "\(handle) has no page to go back to.") }
                navigation = .back
            case "forward":
                guard tab.canGoForward else { return Self.error("navigationFailed", "\(handle) has no page to go forward to.") }
                navigation = .forward
            default:
                navigation = .reload
            }
        }
        let before = state.activity(of: tab.id)
        host.navigate(tab.id, navigation)
        let loaded = await waitForLoad(of: tab.id, grant, state: state, since: before)
        var outcome = loadOutcome(of: tab.id, handle: handle, grant, state: state, since: before, didLoad: loaded, opened: false, history: navigation == .back || navigation == .forward)
        if case .load(let url) = navigation { outcome.site = AgentActivityEntry.site(of: url) }
        return outcome
    }

    /// An address the agent wrote, as rule P16 lets it open: http or https, with a host, on a site not excluded from AI.
    private func writtenAddress(_ text: String) -> Resolved<URL> {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            return .outcome(Self.error("invalidArguments", "url must be a full address with http:// or https://, such as https://example.org/."))
        }
        if case .refused(let rule, let sentence) = AgentPolicy.mayOpen(url, allowsAI: allowsAI) {
            return .outcome(Outcome(result: Self.refusal(rule, "Arch did not open the address. \(sentence)"), site: AgentActivityEntry.site(of: url)))
        }
        return .value(url)
    }

    /// Waits until the tab's main frame finishes a document, the tab stops loading, a rule stops its navigation, or it closes or leaves the client, at most `loadWait`, and says whether one of them happened.
    private func waitForLoad(of tabID: UUID, _ grant: AgentGrant, state: AgentGrantState, since before: AgentTabActivity) async -> Bool {
        await Self.poll(for: loadWait) {
            let activity = state.activity(of: tabID)
            if activity.documents > before.documents || activity.stops > before.stops || activity.refusals > before.refusals || activity.isGone { return true }
            return host.tabs(withIDs: [tabID]).first?.agentOwnerID != grant.id
        }
    }

    /// The result of a load the call waited for: refused when a rule stopped it or the page is one agents do not read, an error when no new document came, and otherwise the address and the title.
    private func loadOutcome(of tabID: UUID, handle: String, _ grant: AgentGrant, state: AgentGrantState, since before: AgentTabActivity, didLoad: Bool, opened: Bool, history: Bool = false) -> Outcome {
        let activity = state.activity(of: tabID)
        guard let tab = host.tabs(withIDs: [tabID]).first else {
            return Outcome(result: AgentToolResult(status: .error, code: "tabNotFound", text: "\(handle) closed before its page loaded."), reportedTabID: tabID)
        }
        guard tab.agentOwnerID == grant.id else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle)), reportedTabID: tabID) }
        if activity.refusals > before.refusals {
            return Outcome(result: Self.refusal(.p16, "Arch stopped \(handle)'s navigation at an address that agents do not open: a site excluded from AI, an internal page, a file, or another app's link.",
                                                handle: handle), reportedTabID: tabID)
        }
        guard AgentPolicy.showsTitle(of: tab.url, allowsAI: allowsAI) else {
            return Outcome(result: Self.refusal(.p16, "\(handle) shows a page that agents do not read.", handle: handle), reportedTabID: tabID)
        }
        let address = tab.url.map { AgentAddress.reduced($0).absoluteString } ?? ""
        let title = Self.pageName(tab.title, url: tab.url)
        let structured = Self.tabJSON(tab, handle: handle)
        let status: AgentResultStatus
        let text: String
        if !didLoad {
            status = .ok
            text = "\(handle) is still loading \(address) after \(Self.seconds(loadWait)). Call wait_for with load to wait longer."
        } else if activity.documents == before.documents, !tab.isLoading, !history {
            status = .error
            text = "\(handle) did not load a new document; it shows \(address)."
        } else {
            status = .ok
            text = opened ? "Opened \(handle) in the background: \(title) at \(address)." : "\(handle) loaded \(title) at \(address)."
        }
        return Outcome(result: AgentToolResult(status: status, code: status == .error ? "navigationFailed" : nil, text: text, structured: .object(structured)), reportedTabID: tabID)
    }

    private func closeTab(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState) -> Outcome {
        let tab: AgentTabInfo, handle: String
        switch agentTab(arguments["tab"]?.stringValue ?? "", grant, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        host.closeAgentTab(tab.id)
        return Outcome(result: AgentToolResult(status: .ok, text: "Closed \(handle).", structured: ["tab": .string(handle), "closed": true]), site: tab.url.flatMap(AgentActivityEntry.site(of:)))
    }

    // MARK: Reading

    private func readText(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        let tab: AgentTabInfo, handle: String
        switch readableTab(arguments["tab"]?.stringValue ?? "", grant, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let content: EngineReadableContent
        switch await read(tab, handle: handle, grant, state: state) {
        case .value(let read): content = read
        case .outcome(let failure):
            var outcome = failure
            outcome.site = site
            return outcome
        }
        let characters = Array(content.text)
        let offset = min(arguments["offset"].flatMap(Self.integer) ?? 0, characters.count)
        var count = min(arguments["max_chars"].flatMap(Self.integer) ?? AgentLimits.readTextCharactersPerCall, characters.count - offset)
        // The whole result's text stays within its limit, which a long page of wide characters can pass before the character limit; the room left covers the sentences around the text and the events.
        var block = AgentUntrusted.wrap(String(characters[offset ..< offset + count]), url: content.url)
        while count > 0, block.utf8.count + Self.resultRoom > AgentLimits.resultTextBytes {
            count = count * 3 / 4
            block = AgentUntrusted.wrap(String(characters[offset ..< offset + count]), url: content.url)
        }
        let end = offset + count
        var lines = ["\(handle): characters \(Self.number(offset)) to \(Self.number(end)) of \(Self.number(characters.count)) of the page's text.", block]
        var limits: [String: AgentJSON] = [:]
        if end < characters.count {
            lines.append("More follows: call read_text with offset \(end).")
            limits["readText"] = ["nextOffset": .number(Double(end))]
        }
        if content.isTruncated {
            lines.append("The page's text goes on past \(Self.number(AgentLimits.readTextMaximumCharacters)) characters, which is as far as read_text reads.")
            limits["readTextMaximum"] = .number(Double(AgentLimits.readTextMaximumCharacters))
        }
        var structured: [String: AgentJSON] = ["tab": .string(handle), "url": .string(AgentAddress.reduced(content.url).absoluteString),
                                               "title": .string(Self.pageName(content.title, url: content.url)), "offset": .number(Double(offset)),
                                               "end": .number(Double(end)), "length": .number(Double(characters.count)), "text": .string(block)]
        if !limits.isEmpty { structured["limits"] = .object(limits) }
        return Outcome(result: AgentToolResult(status: .ok, text: lines.joined(separator: "\n"), structured: .object(structured)), site: site)
    }

    /// The page's text, at most `AgentLimits.readTextMaximumCharacters`, refused when the tab's page, before or after the read, is one agents do not read (P16) or the tab, before or after it, is no longer the client's to read (P17), as when the user takes it over meanwhile, and timed out when the page does not answer within `scriptWait`.
    private func read(_ tab: AgentTabInfo, handle: String, _ grant: AgentGrant, state: AgentGrantState) async -> Resolved<EngineReadableContent> {
        guard mayStillRead(tab, grant, state: state) else { return .outcome(Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle))) }
        if case .refused(let rule, let sentence) = AgentPolicy.mayRead(tab.url, allowsAI: allowsAI) {
            return .outcome(Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle)))
        }
        let host = host
        let wait = scriptWait
        let answer: Result<EngineReadableContent, any Error>? = await withCheckedContinuation { continuation in
            let once = AgentOnce(continuation)
            host.readableContent(of: tab.id, limit: AgentLimits.readTextMaximumCharacters) { once.resume(with: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { once.resume(with: nil) }
        }
        switch answer {
        case nil:
            return .outcome(Outcome(result: AgentToolResult(status: .timeout, code: "notResponding", text: "\(handle) shows a dialog or does not respond. It waits for the user.")))
        case .failure?:
            return .outcome(Outcome(result: AgentToolResult(status: .error, code: "unreadable", text: "\(handle) has no document Arch can read, as while it shows an engine's error page.")))
        case .success(let content)?:
            // The page may have moved on during the read, and the user may have taken the tab over; a tab that closed meanwhile was still the client's.
            if let current = host.tabs(withIDs: [tab.id]).first, !mayStillRead(current, grant, state: state) {
                return .outcome(Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle)))
            }
            if case .refused(let rule, let sentence) = AgentPolicy.mayRead(content.url, allowsAI: allowsAI) {
                return .outcome(Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle)))
            }
            return .value(content)
        }
    }

    /// Whether the client may still read `tab`: one of its agent tabs, or one the user shared with it.
    private func mayStillRead(_ tab: AgentTabInfo, _ grant: AgentGrant, state: AgentGrantState) -> Bool {
        tab.agentOwnerID == grant.id || state.handles.sharedTabIDs.contains(tab.id)
    }

    private func waitFor(_ arguments: [String: AgentJSON], _ grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        let given = ["load", "text", "url", "ref"].filter { arguments[$0] != nil }
        guard given.count == 1 else { return Self.error("invalidArguments", "wait_for takes one of load, text, url, or ref.") }
        if given == ["ref"] { return Self.notAvailable("Refs come with the snapshot tool, which this build of Arch does not run yet. Wait for load, text, or url.") }
        if given == ["load"], arguments["load"] != .bool(true) { return Self.error("invalidArguments", "load must be true.") }
        let tab: AgentTabInfo, handle: String
        switch readableTab(arguments["tab"]?.stringValue ?? "", grant, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let seconds = (arguments["timeout_ms"].flatMap(Self.integer).map { Double($0) / 1000 }) ?? Double(AgentLimits.toolWaitSeconds)
        let deadline = Date().addingTimeInterval(seconds)
        let waited: String
        var isMet = false
        // A tab the user takes over during the wait is no longer the client's to watch: the read, or the check after the poll, refuses it (P17).
        if let text = arguments["text"]?.stringValue {
            waited = "the text \u{201C}\(text)\u{201D} to appear"
            while !isMet {
                guard let current = host.tabs(withIDs: [tab.id]).first else { return Self.error("tabNotFound", "\(handle) closed while it waited.") }
                switch await read(current, handle: handle, grant, state: state) {
                case .value(let content): isMet = content.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                case .outcome(let failure) where failure.result.status == .refused: return Outcome(result: failure.result, site: site)
                case .outcome: break
                }
                if isMet || Date() >= deadline { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        } else {
            let address = arguments["url"]?.stringValue
            waited = address.map { "its address to contain \u{201C}\($0)\u{201D}" } ?? "its document to load"
            isMet = await Self.poll(for: deadline.timeIntervalSinceNow) {
                guard let current = host.tabs(withIDs: [tab.id]).first, mayStillRead(current, grant, state: state) else { return true }
                guard let address else { return !current.isLoading && current.url != nil }
                // The address as results show it, without its query and fragment, which agents never see, and never that of a page agents do not read.
                guard AgentPolicy.showsTitle(of: current.url, allowsAI: allowsAI), let url = current.url else { return false }
                return AgentAddress.reduced(url).absoluteString.contains(address)
            }
            guard let current = host.tabs(withIDs: [tab.id]).first else { return Self.error("tabNotFound", "\(handle) closed while it waited.") }
            guard mayStillRead(current, grant, state: state) else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle), site: site) }
        }
        let structured: AgentJSON = ["tab": .string(handle), "met": .bool(isMet)]
        if isMet { return Outcome(result: AgentToolResult(status: .ok, text: "\(handle): the wait for \(waited) is over; it happened.", structured: structured), site: site) }
        return Outcome(result: AgentToolResult(status: .timeout, text: "\(handle): the wait for \(waited) timed out after \(Self.seconds(seconds)).", structured: structured), site: site)
    }

    /// History pages whose title or address without query and fragment contains the query, without excluded sites and pages agents do not read, at most `limit`, each address once. The store also matches queries and fragments, which agents never see, so it is asked for more.
    private func searchHistory(_ arguments: [String: AgentJSON], _ grant: AgentGrant) async -> Outcome {
        guard grant.scopes.searchHistory else {
            return Outcome(result: AgentToolResult(status: .refused, code: "historyScope", text: "search_history needs the history scope, which the user gives on Arch's grant sheet."))
        }
        let query = (arguments["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = arguments["limit"].flatMap(Self.integer) ?? AgentLimits.historyResults
        var seen: Set<String> = []
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for page in await host.searchHistory(query, limit: AgentLimits.historyResults * 5) where rows.count < limit {
            guard AgentPolicy.showsTitle(of: page.url, allowsAI: allowsAI) else { continue }
            let address = AgentAddress.reduced(page.url).absoluteString
            guard address.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil || page.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  seen.insert(address).inserted else { continue }
            let title = Self.pageName(page.title, url: page.url)
            rows.append(["title": .string(title), "url": .string(address)])
            lines.append("\(title)  \(address)")
        }
        let summary = rows.isEmpty ? "No history page matches \u{201C}\(query)\u{201D}." : "\(rows.count == 1 ? "1 history page matches" : "\(rows.count) history pages match") \u{201C}\(query)\u{201D}."
        let list = Self.fitted(summary, lines, rows, noun: "history page")
        var structured: [String: AgentJSON] = ["pages": .array(list.rows)]
        if let limits = list.limits { structured["limits"] = limits }
        return Outcome(result: AgentToolResult(status: .ok, text: list.text, structured: .object(structured)))
    }

    // MARK: Tabs

    /// One of the grant's agent tabs by handle: not found for a handle this client was not given or a tab that closed, and refused (P17) for a tab the user took over.
    private func agentTab(_ handle: String, _ grant: AgentGrant, state: AgentGrantState) -> Resolved<(AgentTabInfo, String)> {
        guard let id = state.handles.tabs.id(for: handle) else { return .outcome(Self.error("tabNotFound", "This client has no tab \(handle).")) }
        guard let tab = host.tabs(withIDs: [id]).first else { return .outcome(Self.error("tabNotFound", "\(handle) is closed.")) }
        guard tab.agentOwnerID == grant.id else { return .outcome(Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle))) }
        return .value((tab, handle))
    }

    /// A tab the client may read: one of its agent tabs, or one the user shared with it.
    private func readableTab(_ handle: String, _ grant: AgentGrant, state: AgentGrantState) -> Resolved<(AgentTabInfo, String)> {
        if let id = state.handles.tabs.id(for: handle), state.handles.sharedTabIDs.contains(id), let tab = host.tabs(withIDs: [id]).first { return .value((tab, handle)) }
        return agentTab(handle, grant, state: state)
    }

    private static func tabJSON(_ tab: AgentTabInfo, handle: String) -> [String: AgentJSON] {
        ["tab": .string(handle), "url": tab.url.map { .string(AgentAddress.reduced($0).absoluteString) } ?? .null, "title": .string(pageName(tab.title, url: tab.url)),
         "loading": .bool(tab.isLoading), "engine": .string(tab.engine.rawValue)]
    }

    /// The grant's space, or the Persona's first space once that one is gone.
    func space(of grant: AgentGrant) -> AgentSpaceInfo? {
        let spaces = host.spaces(in: grant.personaID)
        return spaces.first { $0.id == grant.spaceID } ?? spaces.first
    }

    private func personaName(of grant: AgentGrant) -> String {
        host.personas.first { $0.id == grant.personaID }?.name ?? "deleted"
    }

    /// The agent folder's name for a client: its name and the app it runs in, as in "claude · Terminal".
    static func folderName(for client: AgentClientIdentity) -> String {
        [client.name, client.host].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    // MARK: Events

    /// Keeps what happened in an agent tab for its client's next result, in `state`, which a grant has from its first call. A tab that a page opened beyond the limit of agent tabs closes again, on the next turn of the run loop, since the engine is still in the callback that made it.
    func tab(_ tabID: UUID, of ownerID: UUID, didReport report: AgentTabReport, state: AgentGrantState?) {
        if case .opened(let openedID) = report, host.agentTabs(of: ownerID).count > AgentLimits.agentTabs {
            let host = host
            DispatchQueue.main.async { MainActor.assumeIsolated { host.closeAgentTab(openedID) } }
            state?.record(.closedOverLimit, tab: tabID)
            return
        }
        state?.record(.report(report), tab: tabID)
    }

    /// Rule P16 at each main frame navigation, redirect hop, and popup of an agent tab, whoever started it: the exclusions then in force decide, and a refusal is an event for the client.
    func tab(_ tabID: UUID, mayLoad url: URL, state: AgentGrantState?) -> Bool {
        guard case .refused = AgentPolicy.mayLoad(url, allowsAI: allowsAI) else { return true }
        state?.record(.refused(url), tab: tabID)
        return false
    }

    /// Adds the events since the client's previous call to the result, as sentences after its own and as `events` in its structured value, without the loads of the tab whose load the result reports. Events whose sentences would take the result past its limit are left out, oldest first, and the result says how many.
    private func attachEvents(to outcome: inout Outcome, since start: Int, state: AgentGrantState) {
        let events = state.takeEvents().filter { event in
            guard event.sequence > start, event.tabID == outcome.reportedTabID else { return true }
            if case .report(.loaded) = event.kind { return false }
            return true
        }
        var described = events.compactMap { describe($0, state: state) }
        guard !described.isEmpty else { return }
        var left = 0
        let base = outcome.result.text.utf8.count
        while !described.isEmpty, base + described.map({ $0.line.utf8.count + 3 }).reduce(0, +) > AgentLimits.resultTextBytes - 200 {
            described.removeFirst()
            left += 1
        }
        var lines = described.map { "- \($0.line)" }
        if left > 0 { lines.insert("- \(left) earlier \(left == 1 ? "event" : "events") left out to keep the result within its limit.", at: 0) }
        outcome.result.content.append(.text("Since your last call:\n" + lines.joined(separator: "\n")))
        var structured = outcome.result.structured?.objectValue ?? [:]
        structured["events"] = .array(described.map(\.json))
        outcome.result.structured = .object(structured)
    }

    /// An event's sentence and JSON. Whatever the page chose in it, its text and the names it gives, such as a title, a link's scheme, a download's file name, or the host that asks for a sign-in, is an untrusted block, and a page agents do not read gives none.
    private func describe(_ event: AgentEvent, state: AgentGrantState) -> (line: String, json: AgentJSON)? {
        let handle = state.handles.tabs.handle(for: event.tabID)
        let pageURL = host.tabs(withIDs: [event.tabID]).first?.url
        let readable = AgentPolicy.showsTitle(of: pageURL, allowsAI: allowsAI)
        func pageText(_ text: String) -> String? { readable && !text.isEmpty ? AgentUntrusted.wrap(text, url: pageURL) : nil }
        func pageName(_ name: String) -> String? { readable && !name.isEmpty ? Self.pageName(name, url: pageURL) : nil }
        var json: [String: AgentJSON] = ["tab": .string(handle)]
        let line: String
        switch event.kind {
        case .report(.loaded(let url, let title)):
            json["kind"] = "loaded"
            if AgentPolicy.showsTitle(of: url, allowsAI: allowsAI), let url {
                let address = AgentAddress.reduced(url).absoluteString
                json["url"] = .string(address)
                let title = Self.pageName(title, url: url)
                json["title"] = .string(title)
                line = "\(handle) loaded \(title) at \(address)."
            } else {
                line = "\(handle) loaded a page that agents do not read."
            }
        case .report(.stoppedLoading):
            return nil
        case .report(.opened(let openedID)):
            let opened = state.handles.tabs.handle(for: openedID)
            json["kind"] = "opened"
            json["opened"] = .string(opened)
            line = "A page in \(handle) opened \(opened), which joined your agent folder."
        case .report(.closed):
            json["kind"] = "closed"
            line = "\(handle) closed: the user or its page closed it."
        case .report(.takenOver):
            json["kind"] = "takenOver"
            line = "The user took over \(handle), which is no longer your agent tab."
        case .report(.permissionDenied(let types)):
            json["kind"] = "permissionDenied"
            json["rule"] = "P8"
            json["permissions"] = .array(types.map { .string($0.agentName) })
            line = "\(handle) asked for \(types.map(\.agentName).joined(separator: " and ")), which Arch denied (P8). \(AgentPolicy.permissionSentence)"
        case .report(.dialogWaiting(let kind, let message)):
            json["kind"] = "dialogWaiting"
            json["rule"] = "P9"
            json["dialog"] = .string(kind.rawValue)
            // A sign-in names its host only when it is the page's own, so that neither a proxy's host nor another site's, as a frame's on a site excluded from AI, reaches the agent.
            let text = kind != .signIn ? pageText(message) : message.lowercased() == pageURL?.host?.lowercased() ? pageName(message) : nil
            if let text { json["message"] = .string(text) }
            switch kind {
            case .confirm, .prompt: line = "\(handle) shows a \(kind.rawValue) dialog, which waits for the user in Arch (P9)" + (text.map { ": \($0)" } ?? ".")
            case .leavePage: line = "\(handle) asks whether to leave its page, which waits for the user in Arch (P9)."
            case .signIn: line = "\(handle) asks for a user name and password\(text.map { " for \($0)" } ?? ""), which the user answers in Arch (P9)."
            }
        case .report(.alertDismissed(let message)):
            json["kind"] = "alertDismissed"
            json["rule"] = "P10"
            let text = pageText(message)
            if let text { json["message"] = .string(text) }
            line = "\(handle) showed an alert, which Arch dismissed (P10)" + (text.map { ": \($0)" } ?? ".")
        case .report(.downloadRefused(let name)):
            json["kind"] = "downloadRefused"
            json["rule"] = "P6"
            let text = pageName(name)
            if let text { json["name"] = .string(text) }
            line = "\(handle) started a download\(text.map { " of \($0)" } ?? ""), which Arch refused (P6). \(AgentPolicy.downloadSentence)"
        case .report(.externalAppRefused(let scheme)):
            json["kind"] = "externalAppRefused"
            json["rule"] = "P11"
            let text = pageName(scheme)
            if let text { json["scheme"] = .string(text) }
            line = "\(handle) tried to open a link in another app\(text.map { " with the scheme \($0)" } ?? ""), which Arch refused (P11). \(AgentPolicy.externalAppSentence)"
        case .refused(let url):
            json["kind"] = "navigationRefused"
            json["rule"] = "P16"
            let isWeb = url.scheme.map { AgentPolicy.webSchemes.contains($0.lowercased()) } ?? false
            // The scheme is the page's choice, as the address of its own navigation.
            let scheme = isWeb ? nil : pageName(url.scheme ?? "")
            if let scheme { json["scheme"] = .string(scheme) }
            line = isWeb ? "Arch stopped \(handle) from loading a site excluded from AI (P16)."
                : "Arch stopped \(handle) from loading an address with \(scheme.map { "the scheme \($0), which" } ?? "a scheme that") agents never open (P16)."
        case .closedOverLimit:
            json["kind"] = "closedOverLimit"
            line = "A page in \(handle) opened another tab, which Arch closed: a client has at most \(AgentLimits.agentTabs) agent tabs open."
        }
        return (line, .object(json))
    }

    // MARK: Helpers

    /// A name a page gives, such as its title, a link's scheme, or a download's file name, as an untrusted block of at most `AgentLimits.pageNameCharacters` characters; a longer one is cut and ends with an ellipsis. Pages choose them freely, and WebKit does not cut titles.
    static func pageName(_ name: String, url: URL?) -> String {
        let cut = name.prefix(AgentLimits.pageNameCharacters)
        return AgentUntrusted.wrap(cut.endIndex < name.endIndex ? String(cut) + "\u{2026}" : name, url: url)
    }

    /// What a call answers in place of a result whose text would pass its limit; a tab's handle stays.
    static func tooLong(_ result: AgentToolResult, tool: String) -> AgentToolResult {
        var structured: [String: AgentJSON] = ["limits": ["resultTextBytes": .number(Double(AgentLimits.resultTextBytes))]]
        if let handle = result.structured?["tab"]?.stringValue, handle.count <= 16 { structured["tab"] = .string(handle) }
        return AgentToolResult(status: .error, code: "limitReached",
                               text: "\(tool)'s result would pass \(AgentLimits.resultTextBytes / 1024) KB of text, the most a result carries, as a page's very long address can make it.",
                               structured: .object(structured))
    }

    /// Polls `condition` on the main actor every 50 milliseconds until it holds or `seconds` pass, and says whether it held.
    static func poll(for seconds: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private static func integer(_ value: AgentJSON) -> Int? {
        guard case .number(let number) = value else { return nil }
        return Int(number)
    }

    /// A number as results write it, such as 16,000, whatever the Mac's region.
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? (value == 1 ? "1 second" : "\(Int(value)) seconds") : String(format: "%.1f seconds", value)
    }

    static func error(_ code: String, _ text: String) -> Outcome {
        Outcome(result: AgentToolResult(status: .error, code: code, text: text))
    }

    static func notAvailable(_ text: String) -> Outcome {
        error("notAvailable", text)
    }

    /// A rule's refusal, named in its code and its text.
    static func refusal(_ rule: AgentRule, _ text: String, handle: String? = nil) -> AgentToolResult {
        var structured: [String: AgentJSON] = ["rule": .string(rule.rawValue)]
        if let handle { structured["tab"] = .string(handle) }
        return AgentToolResult(status: .refused, code: rule.rawValue, text: "\(text) (\(rule.rawValue))", structured: .object(structured))
    }

    /// A value a step needs, or the outcome that ends the call without it.
    enum Resolved<Value> {
        case value(Value)
        case outcome(Outcome)
    }
}

/// Who a call is for: an outside client's grant, or an in-app session. The host reads the same facts from both; a session adds its site scope and what is left of its call limits.
struct AgentToolClient {
    struct Session {
        var siteScope: [String]
        var hasSearchResults: Bool
        var sharedTabCount: Int
        var callsLeftThisTurn: Int
        var callsLeftThisSession: Int
    }

    /// The grant's or session's ID, which owns its agent tabs.
    var id: UUID
    var personaID: UUID
    /// The space where its agent folder goes; one that is gone falls back to the Persona's first.
    var spaceID: UUID
    var level: AgentAccessLevel
    var scopes: AgentGrantScopes
    /// Set for an in-app session.
    var session: Session?

    init(grant: AgentGrant) {
        id = grant.id
        personaID = grant.personaID
        spaceID = grant.spaceID
        level = grant.level
        scopes = grant.scopes
    }

    /// An in-app session, whose `search_history` follows Let In-App Agents Search History and which starts no tasks of its own.
    @MainActor init(session: AgentSession, searchesHistory: Bool) {
        id = session.id
        personaID = session.personaID
        spaceID = session.spaceID
        level = session.mode
        scopes = AgentGrantScopes(searchHistory: searchesHistory, startTasks: false)
        self.session = Session(siteScope: session.scope.sites, hasSearchResults: session.scope.searchResults != nil, sharedTabCount: session.handles.sharedTabIDs.count,
                               callsLeftThisTurn: session.callsLeftThisTurn, callsLeftThisSession: session.callsLeftThisSession)
    }
}

// MARK: In-app sessions

/// An in-app session's calls (docs/agents.md, In-app sessions), which run the tools that need no agent tab until plan task VII.17.1 runs them on the grant's path with the session as the agent folder's owner, its site scope (P13), and the cards in its panel.
extension AgentToolHost {
    /// The tools an in-app session runs in this build; its `tools/list` lists only these, and the others answer that they are not available yet.
    static let sessionServedTools = ["session_info", "list_spaces", "list_tabs", "guide"]

    /// The tools an in-app session in `mode` with `scopes` can call, in catalog order, for its `tools/list`.
    static func sessionTools(for mode: AgentAccessLevel, scopes: AgentGrantScopes) -> [AgentTool] {
        tools(for: mode, scopes: scopes).filter { sessionServedTools.contains($0.name) }
    }

    func run(_ call: AgentToolCall, for client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        guard let tool = AgentToolCatalog.tool(named: call.name) else {
            return AgentToolResult(status: .error, code: "unknownTool", text: "Arch has no tool named \(call.name).")
        }
        // The harness checks guide's arguments itself, so an unknown topic is answered with the topic names, as arch-cli guide answers it, and a null topic gives the guide.
        if tool.name == "guide" { return AgentHarness.guideResult(arguments: call.arguments) }
        if let problem = Self.problem(with: call.arguments, for: tool) {
            return AgentToolResult(status: .error, code: "invalidArguments", text: problem)
        }
        switch tool.name {
        case "session_info": return sessionInfo(ofSession: client, handles: &handles)
        case "list_spaces": return listSpaces(ofSession: client, handles: &handles)
        case "list_tabs": return listTabs(shared: call.arguments["scope"]?.stringValue == "shared", ofSession: client, handles: &handles)
        default: return AgentToolResult(status: .error, code: "notAvailable", text: "In-app sessions do not run \(tool.name) in this build of Arch yet.")
        }
    }

    /// An in-app session's details (docs/agents.md, Tools ▸ Catalog): its mode, its Persona and space, its site scope, its tabs, what is left of its limits, and what asks. The Persona and space read as "Persona / Space".
    private func sessionInfo(ofSession client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        let session = client.session ?? AgentToolClient.Session(siteScope: [], hasSearchResults: false, sharedTabCount: 0, callsLeftThisTurn: 0, callsLeftThisSession: 0)
        let persona = host.personas.first { $0.id == client.personaID }?.name ?? "deleted"
        let space = space(of: client)
        let spaceHandle = space.map { handles.spaces.handle(for: $0.id) }
        let place = space.map { "\(persona) / \($0.name) (\(spaceHandle ?? ""))" } ?? "the \(persona) Persona"
        let openTabs = host.agentTabs(of: client.id).count
        let shared = handles.sharedTabIDs.map { handles.tabs.handle(for: $0) }
        let asks = Self.whatAsksInSession(client.level)
        let sites = session.siteScope.isEmpty ? "no sites yet" : session.siteScope.joined(separator: ", ")
        var lines = ["This session works in \(place), in \(client.level.title)."]
        lines.append("Site scope: \(sites)\(session.hasSearchResults ? ", and the search engine's results address" : ""). \(Self.scopeRule)")
        lines.append("Agent tabs: \(openTabs == 0 ? "none" : String(openTabs)) open, at most \(AgentLimits.agentTabs) at once. Tabs the user shared: \(shared.isEmpty ? "none" : shared.joined(separator: ", ")).")
        lines.append("Limits: \(session.callsLeftThisTurn) of \(AgentLimits.toolCallsPerTurn) tool calls left for this message and \(session.callsLeftThisSession) of \(AgentLimits.toolCallsPerSession) for the session, \(AgentLimits.actionsPerSecond) actions a second.")
        lines.append(contentsOf: asks)
        let structured: AgentJSON = [
            "mode": .string(client.level.rawValue),
            "persona": .string(persona),
            "space": space.map { ["handle": .string(spaceHandle ?? ""), "name": .string($0.name)] } ?? .null,
            "siteScope": ["sites": .array(session.siteScope.map(AgentJSON.string)), "searchResults": .bool(session.hasSearchResults)],
            "agentTabs": .number(Double(openTabs)),
            "sharedTabs": .array(shared.map(AgentJSON.string)),
            "limits": ["agentTabs": .number(Double(AgentLimits.agentTabs)), "toolCallsLeftThisTurn": .number(Double(session.callsLeftThisTurn)),
                       "toolCallsLeftThisSession": .number(Double(session.callsLeftThisSession)), "actionsPerSecond": .number(Double(AgentLimits.actionsPerSecond))],
            "asks": .array(asks.map(AgentJSON.string)),
            "scopes": ["searchHistory": .bool(client.scopes.searchHistory)],
        ]
        return AgentToolResult(status: .ok, text: lines.joined(separator: "\n"), structured: structured)
    }

    /// How the site scope gates the addresses an in-app session's agent writes (rule P13).
    static let scopeRule = "Links you follow by ref open without asking. An address you write opens without asking only when a page or the user showed it, when it is the search engine's results address, or when it is the bare origin of a site in scope; any other address asks the user first, in every mode, and so does a redirect of it to a site outside the scope."

    /// What asks the user or is refused in each mode of an in-app session (docs/agents.md, Modes).
    static func whatAsksInSession(_ mode: AgentAccessLevel) -> [String] {
        let interactions: String
        switch mode {
        case .readOnly: interactions = "Interactions other than scroll and hover are refused, and so are sensitive steps such as request_approval."
        case .askBeforeActing: interactions = "Each interaction asks the user first, and sensitive steps such as request_approval always ask."
        case .actInAgentTabs: interactions = "Interactions in your agent tabs on sites in scope run without asking; elsewhere they ask once per site, and sensitive steps such as request_approval always ask."
        }
        return [
            "Reading runs without asking. \(interactions) Any interaction in a tab the user shared asks every time.",
            "Arch refuses typing passwords, codes, or card details, sites excluded from AI, and tabs you were not given. Hand such steps to the user with hand_to_user.",
        ]
    }

    private func listSpaces(ofSession client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        let spaces = host.spaces(in: client.personaID)
        let agentTabs = host.agentTabs(of: client.id)
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for space in spaces {
            let handle = handles.spaces.handle(for: space.id)
            let count = agentTabs.filter { $0.spaceID == space.id }.count
            rows.append(["handle": .string(handle), "name": .string(space.name), "agentTabs": .number(Double(count))])
            lines.append("\(handle)  \(space.name)  \(count == 1 ? "1 agent tab" : "\(count) agent tabs")")
        }
        let persona = host.personas.first { $0.id == client.personaID }?.name ?? "deleted"
        let summary = spaces.isEmpty ? "The \(persona) Persona has no spaces." : "The \(persona) Persona has \(spaces.count == 1 ? "1 space" : "\(spaces.count) spaces")."
        return AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"), structured: ["spaces": .array(rows)])
    }

    /// The session's agent tabs, or the tabs the user shared, in sidebar order. A tab on a site excluded from AI, or on a page agents do not read, is listed without its title or address (rule P16).
    private func listTabs(shared: Bool, ofSession client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        let tabs = shared ? host.tabs(withIDs: Set(handles.sharedTabIDs)) : host.agentTabs(of: client.id)
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for tab in tabs {
            let handle = handles.tabs.handle(for: tab.id)
            let excluded = !AgentPolicy.showsTitle(of: tab.url, allowsAI: allowsAI)
            var row: [String: AgentJSON] = ["handle": .string(handle), "excluded": .bool(excluded)]
            var line = handle
            if excluded {
                line += "  (a page agents do not read)"
            } else {
                let reduced = tab.url.map(AgentAddress.reduced)
                row["title"] = .string(AgentUntrusted.wrap(tab.title, url: tab.url))
                if shared {
                    row["host"] = tab.url?.host.map(AgentJSON.string) ?? .null
                    line += "  \(AgentUntrusted.wrap(tab.title, url: tab.url))  \(tab.url?.host ?? "")"
                } else {
                    row["url"] = reduced.map { .string($0.absoluteString) } ?? .null
                    row["loading"] = .bool(tab.isLoading)
                    row["engine"] = .string(tab.engine.rawValue)
                    line += "  \(AgentUntrusted.wrap(tab.title, url: tab.url))  \(reduced?.absoluteString ?? "")\(tab.isLoading ? "  loading" : "")"
                }
            }
            rows.append(.object(row))
            lines.append(line)
        }
        let kind = shared ? "shared" : "agent"
        let summary: String
        switch tabs.count {
        case 0: summary = shared ? "The user has shared no tabs with this session." : "This session has no agent tabs open."
        case 1: summary = "1 \(kind) tab."
        default: summary = "\(tabs.count) \(kind) tabs."
        }
        return AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"), structured: ["scope": .string(kind), "tabs": .array(rows)])
    }

    /// The session's space, or the Persona's first space once that one is gone.
    func space(of client: AgentToolClient) -> AgentSpaceInfo? {
        let spaces = host.spaces(in: client.personaID)
        return spaces.first { $0.id == client.spaceID } ?? spaces.first
    }
}

/// Resumes a continuation once, with the first of the answers that may come, as a page's answer and a timer, on whatever thread each comes.
final class AgentOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Value?) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
