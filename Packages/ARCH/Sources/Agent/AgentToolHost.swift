// The tool host: where every tool call runs and is checked, the same code for every client (agent decision 5). It runs, for an outside client's grant, every tool of the catalog: the session and list tools and `guide`, the agent tab and reading tools here, snapshots, screenshots, and actions in `AgentPageTools.swift`, and the tools that wait for the user in `AgentUserTools.swift`, with the events since the client's previous call, the limits, and the rules and modes in `AgentPolicy`; an in-app session's calls run on the same path with its site scope (P13), its own agent folder, and its cards in its panel. An outside client's call that waits for the user answers `approvalPending` after 45 seconds and goes on; `approval_wait` takes its result. A session's call waits on its card instead.
import AgentControl
import ARCHEngine
import Foundation

@MainActor struct AgentToolHost {
    /// The tools this build runs; `tools/list` lists only these, and the others answer that they are not available yet.
    static let servedTools = ["session_info", "list_spaces", "list_tabs", "request_tab", "open_tab", "navigate", "close_tab", "snapshot", "read_text", "screenshot", "click", "type", "press",
                              "select_option", "scroll", "hover", "wait_for", "list_downloads", "search_history", "ask_user", "request_approval", "hand_to_user", "approval_wait", "guide"]

    let host: any AgentBrowserHost
    /// Whether AI may read a page at this address: the site exclusions of `ai.json` (docs/agents.md, Site exclusions).
    let allowsAI: (URL) -> Bool
    var now: () -> Date = Date.init
    /// How long `navigate` and `open_tab` wait for the document (docs/agents.md, Tools ▸ Limits).
    var loadWait = TimeInterval(AgentLimits.toolWaitSeconds)
    /// How long the page may take to answer a read or a script before the call says it does not respond.
    var scriptWait: TimeInterval = 10
    /// The cards that wait for the user, which the service shows in the agent panel.
    var approvals = AgentApprovals()
    /// How long an outside client's call waits for the user before it answers `approvalPending`, and how long a card stays open (docs/agents.md, Tools ▸ Limits). An in-app session's call waits on its card until the card ends, which the service gives the in-app approval wait.
    var answerWait = TimeInterval(AgentLimits.callAnswerSeconds)
    var approvalWindow = TimeInterval(AgentLimits.outsideApprovalDefaultMinutes * 60)
    /// When an in-app session's call stops waiting for the user, from its arrival: its cards and its wait while the session is taken over share this time, which stays below the tool timeout of the user's CLI (docs/agents.md, Tools ▸ Limits).
    var callDeadline: Date?
    /// After an action, how long the host waits for a load it started, and the pause after it.
    var settleWait: TimeInterval = 3
    var settlePause: TimeInterval = 0.3
    /// The connection the call came on, which its cards name so that they end when the client leaves.
    var connectionID: UUID?
    /// The call's request ID on its connection, which a client's `tools/cancel` names.
    var callID: Int?
    /// Deny and Stop: the service disconnects the client, or stops the session's turn, by the owner's ID.
    var stopClient: ((UUID) -> Void)?

    /// What a call did, for the result, the activity log, and the agent panel.
    struct Outcome {
        var result: AgentToolResult
        /// The page's site for the activity log, a host at most.
        var site: String?
        /// The tab whose load the call waited for and reported, whose load events it leaves out.
        var reportedTabID: UUID?
        /// The step as the agent panel shows it to the user, such as "Clicked “Next” on example.org".
        var step: String?
        /// How the user decided, for the activity log, when a card asked.
        var decision: AgentActivityEntry.Decision?
        /// For `approvalPending`, the call that goes on, whose outcome the service records when it comes.
        var waitingCall: AgentCallBox?
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

    /// Runs a call for an outside client's grant.
    func run(_ call: AgentToolCall, for grant: AgentGrant, state: AgentGrantState) async -> Outcome {
        await run(call, for: AgentToolClient(grant: grant), state: state)
    }

    /// Runs a call for a grant or an in-app session, as a task the client's state keeps until it ends, so that Stop, Stop All Agents, revocation, expiry, the connection's close, and a session's turn ending cancel it (`AgentGrantState.cancelCalls(onConnection:)`). A call that still waits for the user after `answerWait` answers `approvalPending` with a handle, under which it goes on until `approval_wait` takes its result; an in-app session's call waits on its card instead, for at most the in-app approval wait.
    func run(_ call: AgentToolCall, for client: AgentToolClient, state: AgentGrantState) async -> Outcome {
        if call.name == "approval_wait" { return await approvalWait(call, for: client, state: state) }
        let box = AgentCallBox(connectionID: connectionID, callID: callID)
        state.runningCalls.append(box)
        box.task = Task {
            let outcome = await runNow(call, for: client, state: state, box: box)
            state.runningCalls.removeAll { $0 === box }
            box.finish(outcome)
        }
        while true {
            if await Self.wait(for: box, seconds: answerWait), let outcome = box.outcome { return outcome }
            // A caller that was cancelled stops the call too; a card it waited on records a denial.
            if Task.isCancelled {
                var ended = Self.ended
                if box.approvalID != nil { ended.decision = .denied }
                box.task?.cancel()
                return ended
            }
            // An in-app session's call never answers before its card does.
            guard client.session == nil, let approvalID = box.approvalID, approvals.isPending(approvalID) else { continue }
            let handle = state.handles.approvals.handle(for: approvalID)
            state.pendingCalls[handle] = box
            var pending = Self.pending(handle, tool: call.name)
            pending.waitingCall = box
            return pending
        }
    }

    /// `approval_wait`: the result of a call that answered `approvalPending`, once it has one, or `approvalPending` again after `answerWait`.
    private func approvalWait(_ call: AgentToolCall, for client: AgentToolClient, state: AgentGrantState) async -> Outcome {
        if let refusal = precheck(call, client, state: state) { return refusal }
        let handle = call.arguments["approval"]?.stringValue ?? ""
        guard let box = state.pendingCalls[handle] else { return Self.error("notFound", "No call of this client waits under \(handle).") }
        guard await Self.wait(for: box, seconds: answerWait), let outcome = box.outcome else { return Self.pending(handle, tool: "approval_wait") }
        state.pendingCalls[handle] = nil
        return outcome
    }

    /// The answer of a call that the client's work ending cancelled: Stop, Deny and Stop, Stop All Agents, a revocation, expiry, or its connection's close. Such a call runs no further step and opens no card.
    static var ended: Outcome {
        Outcome(result: AgentToolResult(status: .denied, code: "ended", text: "The client's work in Arch ended, so the step did not run."))
    }

    /// The answer of a call that waits for the user, which names its approval as the protocol carries it, for `arch-mcp`, which tells the agent to call `approval_wait`, and in `structured` for `arch-cli --json`.
    static func pending(_ handle: String, tool: String) -> Outcome {
        Outcome(result: AgentToolResult(status: .approvalPending, content: [.text("\(tool) waits for the user in Arch; call approval_wait with approval \(handle).")],
                                        structured: ["approval": .string(handle)], approval: handle), step: nil)
    }

    /// Runs a call now and adds the events since the client's previous call.
    private func runNow(_ call: AgentToolCall, for client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let start = state.lastSequence
        var outcome = await outcome(of: call, for: client, state: state, box: box)
        // A result that would still pass its limit, as a page's very long address can make one, says so in its place, so that no result takes a client's connection past the frame limit.
        if outcome.result.text.utf8.count > AgentLimits.resultTextBytes { outcome.result = Self.tooLong(outcome.result, tool: call.name) }
        attachEvents(to: &outcome, since: start, state: state)
        return outcome
    }

    /// The bytes a result leaves, within its limit, for the sentences around a page's text and for the events.
    static let resultRoom = 2_000

    /// The checks before any tool runs: a tool of the catalog, arguments its parameters allow, and for a grant a call within the day's limit; an in-app session counts its calls per message and per session before they reach the host.
    private func precheck(_ call: AgentToolCall, _ client: AgentToolClient, state: AgentGrantState) -> Outcome? {
        guard let tool = AgentToolCatalog.tool(named: call.name) else {
            return Self.error("unknownTool", "Arch has no tool named \(call.name).")
        }
        // The harness checks guide's arguments itself, so an unknown topic is answered with the topic names, as arch-cli guide answers it, and a null topic gives the guide.
        if tool.name != "guide", let problem = Self.problem(with: call.arguments, for: tool) {
            return Self.error("invalidArguments", problem)
        }
        guard client.session != nil || state.countCall(at: now()) else {
            return Outcome(result: AgentToolResult(status: .error, code: "limitReached",
                                                   text: "This client made \(Self.number(AgentLimits.toolCallsPerGrantPerDay)) tool calls today, the most for a day. Its calls work again tomorrow.",
                                                   structured: ["limits": ["toolCallsPerDay": .number(Double(AgentLimits.toolCallsPerGrantPerDay))]]))
        }
        return nil
    }

    private func outcome(of call: AgentToolCall, for client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        if let refusal = precheck(call, client, state: state) { return refusal }
        guard let tool = AgentToolCatalog.tool(named: call.name) else { return Self.error("unknownTool", "Arch has no tool named \(call.name).") }
        let arguments = call.arguments
        let shared = arguments["scope"]?.stringValue == "shared"
        switch tool.name {
        case "session_info": return Outcome(result: client.session != nil ? sessionInfo(ofSession: client, handles: &state.handles) : sessionInfo(client, state: state))
        case "list_spaces": return Outcome(result: client.session != nil ? listSpaces(ofSession: client, handles: &state.handles) : listSpaces(client, state: state))
        case "list_tabs": return Outcome(result: client.session != nil ? listTabs(shared: shared, ofSession: client, handles: &state.handles) : listTabs(shared: shared, client, state: state))
        case "open_tab": return await openTab(arguments, client, state: state, box: box)
        case "navigate": return await navigate(arguments, client, state: state, box: box)
        case "close_tab": return closeTab(arguments, client, state: state)
        case "read_text": return await readText(arguments, client, state: state)
        case "wait_for": return await waitFor(arguments, client, state: state)
        case "list_downloads": return listDownloads(client)
        case "search_history": return await searchHistory(arguments, client)
        case "snapshot": return await snapshot(arguments, client, state: state)
        case "screenshot": return await screenshot(arguments, client, state: state)
        case "click", "type", "press", "select_option", "scroll", "hover": return await act(tool.name, arguments, client, state: state, box: box)
        case "request_tab": return await requestTab(arguments, client, state: state, box: box)
        case "ask_user": return await askUser(arguments, client, box: box)
        case "request_approval": return await requestApproval(arguments, client, state: state, box: box)
        case "hand_to_user": return await handToUser(arguments, client, state: state, box: box)
        case "guide": return Outcome(result: AgentHarness.guideResult(arguments: arguments, inSession: client.session != nil))
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

    private func sessionInfo(_ client: AgentToolClient, state: AgentGrantState) -> AgentToolResult {
        let persona = personaName(of: client)
        let space = space(of: client)
        let spaceHandle = space.map { state.handles.spaces.handle(for: $0.id) }
        let openTabs = host.agentTabs(of: client.id).count
        let asks = Self.whatAsks(client.level)
        // A Persona's place reads as "Persona / Space" (Personas, history, and permissions).
        let place = space.map { "\(persona) / \($0.name) (\(spaceHandle ?? ""))" } ?? "the \(persona) Persona"
        var lines = ["This client has \(client.level.title) access in \(place)."]
        lines.append("Site scope: none. An outside client navigates freely in its own agent tabs, which open in its agent folder \u{201C}\(client.folderName)\u{201D}.")
        lines.append("Agent tabs: \(openTabs == 0 ? "none" : String(openTabs)) open, at most \(AgentLimits.agentTabs) at once.")
        lines.append("Limits: \(Self.number(AgentLimits.toolCallsPerGrantPerDay)) tool calls a day for this grant, \(AgentLimits.actionsPerSecond) actions a second, \(AgentLimits.toolWaitSeconds) seconds per wait.")
        lines.append(contentsOf: asks)
        let structured: AgentJSON = [
            "mode": .string(client.level.rawValue),
            "persona": .string(persona),
            "space": space.map { ["handle": .string(spaceHandle ?? ""), "name": .string($0.name)] } ?? .null,
            "siteScope": .null,
            "agentTabs": .number(Double(openTabs)),
            "limits": ["agentTabs": .number(Double(AgentLimits.agentTabs)), "toolCallsPerDay": .number(Double(AgentLimits.toolCallsPerGrantPerDay)), "actionsPerSecond": .number(Double(AgentLimits.actionsPerSecond))],
            "asks": .array(asks.map(AgentJSON.string)),
            "scopes": ["searchHistory": .bool(client.scopes.searchHistory), "startTasks": .bool(client.scopes.startTasks)],
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
            "Arch refuses typing passwords, codes, or card details, file choosers, CAPTCHAs, sites excluded from AI, internal pages, and tabs you were not given. Hand such steps to the user with hand_to_user. Downloads, links to other apps, and every action in a tab the user shared ask the user.",
        ]
    }

    private func listSpaces(_ client: AgentToolClient, state: AgentGrantState) -> AgentToolResult {
        let spaces = host.spaces(in: client.personaID)
        let agentTabs = host.agentTabs(of: client.id)
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for space in spaces {
            let handle = state.handles.spaces.handle(for: space.id)
            let count = agentTabs.filter { $0.spaceID == space.id }.count
            rows.append(["handle": .string(handle), "name": .string(space.name), "agentTabs": .number(Double(count))])
            lines.append("\(handle)  \(space.name)  \(count == 1 ? "1 agent tab" : "\(count) agent tabs")")
        }
        let persona = personaName(of: client)
        let summary = spaces.isEmpty ? "The \(persona) Persona has no spaces." : "The \(persona) Persona has \(spaces.count == 1 ? "1 space" : "\(spaces.count) spaces")."
        return AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"), structured: ["spaces": .array(rows)])
    }

    /// The client's agent tabs, or the tabs the user shared, in sidebar order. A tab on a site excluded from AI, or on a page agents do not read, is listed without its title or address (rule P16).
    private func listTabs(shared: Bool, _ client: AgentToolClient, state: AgentGrantState) -> AgentToolResult {
        let tabs = shared ? host.tabs(withIDs: Set(state.handles.sharedTabIDs)).filter { access(to: $0, client, state: state) != .notTheClients } : host.agentTabs(of: client.id)
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

    private func openTab(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let url: URL
        var isWritten = false
        if let ref = arguments["ref"]?.stringValue {
            if arguments["url"] != nil { return Self.error("invalidArguments", "open_tab takes url or ref, not both.") }
            guard let handle = arguments["tab"]?.stringValue else { return Self.error("invalidArguments", "open_tab needs tab, the tab whose snapshot holds ref.") }
            switch link(ref, in: handle, client, state: state) {
            case .value(let followed): url = followed
            case .outcome(let failure): return failure
            }
        } else {
            if arguments["tab"] != nil { return Self.error("invalidArguments", "open_tab takes tab only with ref.") }
            guard let text = arguments["url"]?.stringValue else { return Self.error("invalidArguments", "open_tab needs url or ref.") }
            switch writtenAddress(text) {
            case .value(let written): url = written
            case .outcome(let refusal): return refusal
            }
            isWritten = true
        }
        if let full = tabLimit(client, opening: url) { return full }
        guard let space = space(of: client) else { return Self.error("noSpace", "The \(personaName(of: client)) Persona has no space for agent tabs.") }
        var decision: AgentActivityEntry.Decision?
        if isWritten {
            switch await askAboutWrittenAddress(url, in: nil, handle: nil, client, state: state, box: box) {
            case .value(let answered): decision = answered
            case .outcome(var refusal):
                refusal.site = AgentActivityEntry.site(of: url)
                return refusal
            }
        }
        // A session whose turn ended or that the user took over while the card waited opens nothing, and other calls may have opened tabs meanwhile.
        guard !Task.isCancelled, client.isCurrent else { return Self.ended }
        if decision != nil, var full = tabLimit(client, opening: url) {
            full.decision = decision
            return full
        }
        let engine = arguments["engine"]?.stringValue.map { $0 == "webkit" ? EngineKind.webKit : EngineKind.chromium }
        let owner = AgentTabOwner(id: client.id, spaceID: space.id, folderName: client.folderName)
        guard let tab = host.openAgentTab(at: url, engine: engine, for: owner) else { return Self.error("noSpace", "Arch could not open an agent tab in this client's space.") }
        let handle = state.handles.tabs.handle(for: tab.id)
        let load = isWritten && client.kind == .inApp ? state.beginWrittenLoad(url, in: tab.id) : nil
        var outcome = await finishLoad(of: tab.id, handle: handle, load: load, client, state: state, box: box, since: AgentTabActivity(), opened: true, decision: decision)
        outcome.site = AgentActivityEntry.site(of: url)
        return outcome
    }

    /// The refusal of a tab past the limit of agent tabs, or nil while the client has room for one.
    private func tabLimit(_ client: AgentToolClient, opening url: URL) -> Outcome? {
        guard host.agentTabs(of: client.id).count >= AgentLimits.agentTabs else { return nil }
        return Outcome(result: AgentToolResult(status: .error, code: "limitReached",
                                               text: "This client has \(AgentLimits.agentTabs) agent tabs open, the most at once. Close one with close_tab first.",
                                               structured: ["limits": ["agentTabs": .number(Double(AgentLimits.agentTabs))]]), site: AgentActivityEntry.site(of: url))
    }

    private func navigate(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Outcome {
        let given = ["url", "ref", "action"].filter { arguments[$0] != nil }
        guard given.count == 1 else { return Self.error("invalidArguments", "navigate takes one of url, ref, or action.") }
        var tab: AgentTabInfo, handle: String
        switch agentTab(arguments["tab"]?.stringValue ?? "", client, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        let navigation: AgentNavigation
        if let text = arguments["url"]?.stringValue {
            switch writtenAddress(text) {
            case .value(let url): navigation = .load(url)
            case .outcome(let refusal): return refusal
            }
        } else if let ref = arguments["ref"]?.stringValue {
            switch link(ref, in: handle, client, state: state) {
            case .value(let url): navigation = .load(url)
            case .outcome(let failure): return failure
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
        let written = arguments["url"] != nil
        var decision: AgentActivityEntry.Decision?
        if written, case .load(let url) = navigation {
            switch await askAboutWrittenAddress(url, in: tab, handle: handle, client, state: state, box: box) {
            case .value(let answered): decision = answered
            case .outcome(var refusal):
                refusal.site = AgentActivityEntry.site(of: url)
                return refusal
            }
            // The tab may have closed or left the client while the card waited.
            switch agentTab(handle, client, state: state) {
            case .value(let resolved): tab = resolved.0
            case .outcome(let failure): return failure
            }
        }
        guard !Task.isCancelled, client.isCurrent else { return Self.ended }
        let before = state.activity(of: tab.id)
        // The navigation replaces the tab's earlier one, whose checks end; a written address's starts its own.
        var load: UUID?
        if client.kind == .inApp {
            if written, case .load(let url) = navigation { load = state.beginWrittenLoad(url, in: tab.id) } else { state.endWrittenLoad(in: tab.id) }
        }
        host.navigate(tab.id, navigation)
        var outcome = await finishLoad(of: tab.id, handle: handle, load: load, client, state: state, box: box, since: before, opened: false,
                                       history: navigation == .back || navigation == .forward, decision: decision)
        if case .load(let url) = navigation { outcome.site = AgentActivityEntry.site(of: url) }
        return outcome
    }

    /// How many redirect hops off the scope one call asks the user about before it gives up.
    static let askedHopsPerCall = 3

    /// Waits for the load a call started and answers with it, with the user's decision when a card asked. A redirect hop of an in-app session's written address (`load`) that the scope stopped (`heldHops`) asks the user with the hop's full address; Allow adds it to the scope and loads it as a written address's navigation of its own, and any other answer ends the call without it. Once the call ends, a hop of its navigation that the scope stops is refused.
    private func finishLoad(of tabID: UUID, handle: String, load: UUID?, _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox, since start: AgentTabActivity, opened: Bool,
                            history: Bool = false, decision: AgentActivityEntry.Decision? = nil) async -> Outcome {
        var before = start
        var asked = 0
        var load = load
        var decision = decision
        defer { if let load { state.stopAwaiting(load, in: tabID) } }
        while true {
            let loaded = await waitForLoad(of: tabID, load: load, client, state: state, since: before)
            if Task.isCancelled { return Self.ended }
            guard let current = load, let question = state.takeHeldHop(of: current, in: tabID) else {
                var outcome = loadOutcome(of: tabID, handle: handle, client, state: state, since: before, didLoad: loaded, opened: opened, history: history)
                outcome.decision = decision
                return outcome
            }
            load = nil
            guard asked < Self.askedHopsPerCall else {
                var outcome = Self.error("navigationFailed", "\(handle) kept redirecting to sites outside the session's scope, so Arch stopped its navigation.")
                outcome.decision = decision
                return outcome
            }
            asked += 1
            guard let tab = host.tabs(withIDs: [tabID]).first, tab.agentOwnerID == client.id else {
                var outcome = loadOutcome(of: tabID, handle: handle, client, state: state, since: before, didLoad: loaded, opened: opened, history: history)
                outcome.decision = decision
                return outcome
            }
            switch await askAboutAddress(question, in: tab, handle: handle, isHop: true, client, state: state, box: box) {
            case .value(let answered): decision = answered ?? decision
            case .outcome(let refusal): return refusal
            }
            guard !Task.isCancelled, client.isCurrent, host.tabs(withIDs: [tabID]).first?.agentOwnerID == client.id else { return Self.ended }
            before = state.activity(of: tabID)
            load = state.beginWrittenLoad(question.url, in: tabID)
            host.navigate(tabID, .load(question.url))
        }
    }

    /// Rule P13 for an address an in-app session's agent wrote (docs/agents.md, Site scope and navigation): it opens without asking only when the session has seen it, when it is the search engine's results address, or when it is the bare origin of a site in scope; otherwise the user decides on a sensitive card, in every mode. An outside client navigates freely in its own agent tabs. The address may open with the user's decision, nil when no card asked.
    private func askAboutWrittenAddress(_ url: URL, in tab: AgentTabInfo?, handle: String?, _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Resolved<AgentActivityEntry.Decision?> {
        guard client.kind == .inApp, let owner = client.inAppSession, case .asks(let question) = owner.scope.written(url) else { return .value(nil) }
        return await askAboutAddress(question, in: tab, handle: handle, isHop: false, client, state: state, box: box)
    }

    /// A P13 card: the step, the scope's sentence, and the full address with the parts the session has not seen marked. The card is about the address, not the tab's page, so a new page in the tab leaves it waiting. Allow adds the address to the scope, which makes its site part of it, and gives the decision for the activity log; any other answer gives the call's outcome.
    private func askAboutAddress(_ question: AgentAddressQuestion, in tab: AgentTabInfo?, handle: String?, isHop: Bool, _ client: AgentToolClient, state: AgentGrantState, box: AgentCallBox) async -> Resolved<AgentActivityEntry.Decision?> {
        let facts = AgentNavigationFacts(isWritten: true, siteInScope: !question.isOutsideScope, isRedirectHop: isHop)
        guard let owner = client.inAppSession, case .ask(let ask) = AgentPolicy.decide(.navigation(facts), client: client.kind, mode: client.level) else { return .value(nil) }
        let place = handle.map { "in \($0)" } ?? "in a new agent tab"
        // A hop asks only when it leaves the scope; its address may be one a page showed.
        let action = isHop ? "Follow a redirect \(place) to a site outside the session's scope" : "Open an address \(place)"
        var offers = AgentApproval.offers(for: ask)
        // Take Over needs a tab to show.
        if tab == nil { offers.removeAll { $0 == .takeOver } }
        var card = AgentApproval(ownerID: client.id, clientName: client.name, isOutsideClient: client.isOutsideClient, kind: .step, rules: ask.rules, isSensitive: ask.isSensitive,
                                 offers: offers, action: action, tabID: tab?.id, tabHandle: handle, site: question.url.host?.lowercased(), exactText: question.url.absoluteString,
                                 connectionID: connectionID, createdAt: now(), deadline: now().addingTimeInterval(approvalWindow))
        card.exactTextNote = question.sentence
        card.addressQuestion = question
        box.approvalID = card.id
        let answer = await request(card, for: client)
        if let ended = answerOutcome(answer, card: card, handle: handle ?? "", client: client) { return .outcome(ended) }
        guard !Task.isCancelled, client.isCurrent else { return .outcome(Self.ended) }
        owner.scope.add(question.url)
        return .value(card.needsAuthentication ? .approvedWithTouchID : .approved)
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

    /// The full address of a link that a ref names in the tab's latest snapshot, which a followed link opens without the agent seeing its query (docs/agents.md, Untrusted marking), refused like a written address on a site agents do not open (P16), and stale once the tab shows another document.
    private func link(_ ref: String, in handle: String, _ client: AgentToolClient, state: AgentGrantState) -> Resolved<URL> {
        let tab: AgentTabInfo
        switch readableTab(handle, client, state: state) {
        case .value(let resolved): tab = resolved.0
        case .outcome(let failure): return .outcome(failure)
        }
        guard let record = currentSnapshot(of: tab, state: state), let entry = record.refs[ref] else { return .outcome(Self.stale(handle)) }
        guard let url = entry.href else { return .outcome(Self.error("notALink", "\(ref) in \(handle) is not a link. Use click for other elements.")) }
        if case .refused(let rule, let sentence) = AgentPolicy.mayOpen(url, allowsAI: allowsAI) {
            return .outcome(Outcome(result: Self.refusal(rule, "Arch did not open the link. \(sentence)"), site: AgentActivityEntry.site(of: url)))
        }
        return .value(url)
    }

    /// The tab's latest snapshot while the tab still shows its page.
    func currentSnapshot(of tab: AgentTabInfo, state: AgentGrantState) -> AgentSnapshotRecord? {
        state.snapshots.current(tab, pages: state.activity(of: tab.id).pages)
    }

    static func stale(_ handle: String) -> Outcome {
        Outcome(result: AgentToolResult(status: .stale, code: "stale", text: "The page in \(handle) changed since your last snapshot. Take a new snapshot.", structured: ["tab": .string(handle)]))
    }

    /// Waits until the tab's main frame finishes a document, the tab stops loading, a rule stops its navigation or the scope a hop of `load`, or it closes or leaves the client, at most `loadWait`, and says whether one of them happened.
    private func waitForLoad(of tabID: UUID, load: UUID?, _ client: AgentToolClient, state: AgentGrantState, since before: AgentTabActivity) async -> Bool {
        await Self.poll(for: loadWait) {
            let activity = state.activity(of: tabID)
            let isHeld = load != nil && state.heldHops[tabID]?.loadID == load
            if activity.documents > before.documents || activity.stops > before.stops || activity.refusals > before.refusals || activity.isGone || isHeld { return true }
            return host.tabs(withIDs: [tabID]).first?.agentOwnerID != client.id
        }
    }

    /// The result of a load the call waited for: refused when a rule stopped it or the page is one agents do not read, an error when no new document came, and otherwise the address and the title.
    private func loadOutcome(of tabID: UUID, handle: String, _ client: AgentToolClient, state: AgentGrantState, since before: AgentTabActivity, didLoad: Bool, opened: Bool, history: Bool = false) -> Outcome {
        let activity = state.activity(of: tabID)
        guard let tab = host.tabs(withIDs: [tabID]).first else {
            return Outcome(result: AgentToolResult(status: .error, code: "tabNotFound", text: "\(handle) closed before its page loaded."), reportedTabID: tabID)
        }
        guard tab.agentOwnerID == client.id else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle)), reportedTabID: tabID) }
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

    private func closeTab(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState) -> Outcome {
        let tab: AgentTabInfo, handle: String
        switch agentTab(arguments["tab"]?.stringValue ?? "", client, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        guard client.isCurrent else { return Self.ended }
        host.closeAgentTab(tab.id)
        state.endWrittenLoad(in: tab.id)
        return Outcome(result: AgentToolResult(status: .ok, text: "Closed \(handle).", structured: ["tab": .string(handle), "closed": true]), site: tab.url.flatMap(AgentActivityEntry.site(of:)))
    }

    // MARK: Reading

    private func readText(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState) async -> Outcome {
        let tab: AgentTabInfo, handle: String
        switch readableTab(arguments["tab"]?.stringValue ?? "", client, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        return await readText(arguments, tab: tab, handle: handle) { mayStillRead($0, as: tab, handle: handle, client, state: state) }
    }

    func readText(_ arguments: [String: AgentJSON], tab: AgentTabInfo, handle: String, mayReadTab: (AgentTabInfo) -> Bool) async -> Outcome {
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let content: EngineReadableContent
        switch await read(tab, handle: handle, mayReadTab: mayReadTab) {
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
    private func read(_ tab: AgentTabInfo, handle: String, mayReadTab: (AgentTabInfo) -> Bool) async -> Resolved<EngineReadableContent> {
        guard mayReadTab(tab) else { return .outcome(Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle))) }
        if case .refused(let rule, let sentence) = AgentPolicy.mayRead(tab.url, allowsAI: allowsAI) {
            return .outcome(Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle)))
        }
        let host = host
        let wait = scriptWait
        let reply = AgentOnce<Result<EngineReadableContent, any Error>>()
        let timeout = Task {
            try await Task.sleep(for: .seconds(wait))
            reply.resume(with: nil)
        }
        defer { timeout.cancel() }
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard reply.begin(continuation) else { return }
                host.readableContent(of: tab.id, limit: AgentLimits.readTextMaximumCharacters) { reply.resume(with: $0) }
            }
        } onCancel: {
            reply.resume(with: nil)
        }
        guard !Task.isCancelled else { return .outcome(Self.ended) }
        switch answer {
        case nil:
            return .outcome(Outcome(result: AgentToolResult(status: .timeout, code: "notResponding", text: "\(handle) shows a dialog or does not respond. It waits for the user.")))
        case .failure?:
            return .outcome(Outcome(result: AgentToolResult(status: .error, code: "unreadable", text: "\(handle) has no document Arch can read, as while it shows an engine's error page.")))
        case .success(let content)?:
            guard let current = host.tabs(withIDs: [tab.id]).first else { return .outcome(Self.error("tabNotFound", "\(handle) is closed.")) }
            guard mayReadTab(current) else {
                return .outcome(Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle)))
            }
            for address in [current.url, content.url] {
                if case .refused(let rule, let sentence) = AgentPolicy.mayRead(address, allowsAI: allowsAI) {
                    return .outcome(Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle)))
                }
            }
            guard current.documentID == tab.documentID, tab.url == content.url, current.url == content.url else {
                return .outcome(Self.error("pageChanged", "\(handle) changed pages during the read. Read the current page again."))
            }
            return .value(content)
        }
    }

    /// Whether the client may still read `tab`: one of its agent tabs, or one the user shared with it that is still the user's, in an in-app session also one of the user's open tabs of its Persona; and for a session, while the call's turn goes on and the user has not taken the session over.
    func mayStillRead(_ tab: AgentTabInfo, _ client: AgentToolClient, state: AgentGrantState) -> Bool {
        guard client.isCurrent else { return false }
        switch access(to: tab, client, state: state) {
        case .notTheClients: return false
        case .agentTab: return true
        case .shared: return client.session == nil || host.userTabs(in: client.personaID).contains { $0.id == tab.id }
        }
    }

    /// Whether the client may still read the tab that a read began on as `original`, as it is now: also under the same handle, which Stop Sharing removes, and with the same owner.
    func mayStillRead(_ current: AgentTabInfo, as original: AgentTabInfo, handle: String, _ client: AgentToolClient, state: AgentGrantState) -> Bool {
        current.agentOwnerID == original.agentOwnerID && state.handles.tabs.id(for: handle) == original.id && mayStillRead(current, client, state: state)
    }

    private func waitFor(_ arguments: [String: AgentJSON], _ client: AgentToolClient, state: AgentGrantState) async -> Outcome {
        let given = ["load", "text", "url", "ref"].filter { arguments[$0] != nil }
        guard given.count == 1 else { return Self.error("invalidArguments", "wait_for takes one of load, text, url, or ref.") }
        if given == ["load"], arguments["load"] != .bool(true) { return Self.error("invalidArguments", "load must be true.") }
        let tab: AgentTabInfo, handle: String
        switch readableTab(arguments["tab"]?.stringValue ?? "", client, state: state) {
        case .value(let resolved): (tab, handle) = resolved
        case .outcome(let failure): return failure
        }
        let site = tab.url.flatMap(AgentActivityEntry.site(of:))
        let seconds = (arguments["timeout_ms"].flatMap(Self.integer).map { Double($0) / 1000 }) ?? Double(AgentLimits.toolWaitSeconds)
        let deadline = Date().addingTimeInterval(seconds)
        let waited: String
        var isMet = false
        // A tab the user takes over during the wait is no longer the client's to watch: the read, or the check after the poll, refuses it (P17).
        if let ref = arguments["ref"]?.stringValue {
            waited = "\(ref) to appear"
            guard let record = currentSnapshot(of: tab, state: state), let entry = record.refs[ref], let target = AgentRefTarget(ref, fingerprint: entry.fingerprint) else { return Self.stale(handle) }
            // Watching scrolls nothing, so that a wait leaves the user's shared tab where it is.
            while !isMet {
                guard let current = host.tabs(withIDs: [tab.id]).first else { return Self.error("tabNotFound", "\(handle) closed while it waited.") }
                guard mayStillRead(current, client, state: state) else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle), site: site) }
                if case .refused(let rule, let sentence) = AgentPolicy.mayRead(current.url, allowsAI: allowsAI) {
                    return Outcome(result: Self.refusal(rule, "Arch does not let agents read \(handle). \(sentence)", handle: handle), site: site)
                }
                if case .value(let reply) = await pageScript(.element(target, scroll: false), in: current, as: AgentElementReply.self) {
                    isMet = reply.facts != nil && !["notFound", "stale", "hidden", "detached"].contains(reply.problem ?? "")
                }
                if isMet || Date() >= deadline || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        } else if let text = arguments["text"]?.stringValue {
            waited = "the text \u{201C}\(text)\u{201D} to appear"
            while !isMet {
                guard let current = host.tabs(withIDs: [tab.id]).first else { return Self.error("tabNotFound", "\(handle) closed while it waited.") }
                let reading = await read(current, handle: handle) { mayStillRead($0, client, state: state) }
                switch reading {
                case .value(let content): isMet = content.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                case .outcome(let failure) where failure.result.status == .refused: return Outcome(result: failure.result, site: site)
                case .outcome: break
                }
                if isMet || Date() >= deadline || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        } else {
            let address = arguments["url"]?.stringValue
            waited = address.map { "its address to contain \u{201C}\($0)\u{201D}" } ?? "its document to load"
            isMet = await Self.poll(for: deadline.timeIntervalSinceNow) {
                guard let current = host.tabs(withIDs: [tab.id]).first, mayStillRead(current, client, state: state) else { return true }
                guard let address else { return !current.isLoading && current.url != nil }
                // The address as results show it, without its query and fragment, which agents never see, and never that of a page agents do not read.
                guard AgentPolicy.showsTitle(of: current.url, allowsAI: allowsAI), let url = current.url else { return false }
                return AgentAddress.reduced(url).absoluteString.contains(address)
            }
            guard let current = host.tabs(withIDs: [tab.id]).first else { return Self.error("tabNotFound", "\(handle) closed while it waited.") }
            guard mayStillRead(current, client, state: state) else { return Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle), site: site) }
        }
        if Task.isCancelled { return Self.ended }
        let structured: AgentJSON = ["tab": .string(handle), "met": .bool(isMet)]
        if isMet { return Outcome(result: AgentToolResult(status: .ok, text: "\(handle): the wait for \(waited) is over; it happened.", structured: structured), site: site) }
        return Outcome(result: AgentToolResult(status: .timeout, text: "\(handle): the wait for \(waited) timed out after \(Self.seconds(seconds)).", structured: structured), site: site)
    }

    /// The downloads the client's agent tabs started once the user allowed them: name, size, and state, never a path.
    private func listDownloads(_ client: AgentToolClient) -> Outcome {
        let downloads = host.agentDownloads(of: client.id)
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for download in downloads {
            let name = Self.pageName(download.name, url: nil)
            let size = download.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file) : "size unknown"
            rows.append(["name": .string(name), "completedBytes": .number(Double(download.completedBytes)), "totalBytes": .number(Double(download.totalBytes)), "state": .string(download.state.rawValue)])
            lines.append("\(name)  \(size)  \(download.state.rawValue)")
        }
        let summary = downloads.isEmpty ? "No downloads. A download from an agent tab starts only after the user allows it in Arch." : "\(downloads.count == 1 ? "1 download" : "\(downloads.count) downloads")."
        let list = Self.fitted(summary, lines, rows, noun: "download")
        var structured: [String: AgentJSON] = ["downloads": .array(list.rows)]
        if let limits = list.limits { structured["limits"] = limits }
        return Outcome(result: AgentToolResult(status: .ok, text: list.text, structured: .object(structured)))
    }

    /// History pages whose title or address without query and fragment contains the query, without excluded sites and pages agents do not read, at most `limit`, each address once. The store also matches queries and fragments, which agents never see, so it is asked for more.
    private func searchHistory(_ arguments: [String: AgentJSON], _ client: AgentToolClient) async -> Outcome {
        guard client.scopes.searchHistory else {
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
    func agentTab(_ handle: String, _ client: AgentToolClient, state: AgentGrantState) -> Resolved<(AgentTabInfo, String)> {
        guard let id = state.handles.tabs.id(for: handle) else { return .outcome(Self.error("tabNotFound", "This client has no tab \(handle).")) }
        guard let tab = host.tabs(withIDs: [id]).first else { return .outcome(Self.error("tabNotFound", "\(handle) is closed.")) }
        guard tab.agentOwnerID == client.id else { return .outcome(Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle))) }
        return .value((tab, handle))
    }

    /// A tab the client may read: one of its agent tabs, or one the user shared with it that is still the user's, by the tab's current owner.
    func readableTab(_ handle: String, _ client: AgentToolClient, state: AgentGrantState) -> Resolved<(AgentTabInfo, String)> {
        guard let id = state.handles.tabs.id(for: handle) else { return .outcome(Self.error("tabNotFound", "This client has no tab \(handle).")) }
        guard let tab = host.tabs(withIDs: [id]).first else { return .outcome(Self.error("tabNotFound", "\(handle) is closed.")) }
        guard mayStillRead(tab, client, state: state) else { return .outcome(Outcome(result: Self.refusal(.p17, AgentPolicy.notTheClientsSentence(handle), handle: handle))) }
        return .value((tab, handle))
    }

    /// How the client may use the tab as it is now, on every call: its own agent tab while the tab is in its agent folder, and a tab the user shared while the tab is the user's. A shared tab that has moved into an agent folder is no longer shared, and leaves the shared list. A tab never changes Persona, and the user shared one of the grant's Persona.
    func access(to tab: AgentTabInfo, _ client: AgentToolClient, state: AgentGrantState) -> AgentTabAccess {
        let isShared = state.handles.sharedTabIDs.contains(tab.id)
        if isShared, tab.agentOwnerID != nil {
            state.handles.sharedTabIDs.removeAll { $0 == tab.id }
            state.handles.actingSharedTabIDs.remove(tab.id)
        }
        if tab.agentOwnerID == client.id { return .agentTab }
        guard isShared, tab.agentOwnerID == nil else { return .notTheClients }
        return .shared(acting: state.handles.actingSharedTabIDs.contains(tab.id))
    }

    private static func tabJSON(_ tab: AgentTabInfo, handle: String) -> [String: AgentJSON] {
        ["tab": .string(handle), "url": tab.url.map { .string(AgentAddress.reduced($0).absoluteString) } ?? .null, "title": .string(pageName(tab.title, url: tab.url)),
         "loading": .bool(tab.isLoading), "engine": .string(tab.engine.rawValue)]
    }

    /// The grant's or session's space, or the Persona's first space once that one is gone.
    func space(of client: AgentToolClient) -> AgentSpaceInfo? {
        let spaces = host.spaces(in: client.personaID)
        return spaces.first { $0.id == client.spaceID } ?? spaces.first
    }

    func space(of grant: AgentGrant) -> AgentSpaceInfo? {
        space(of: AgentToolClient(grant: grant))
    }

    func personaName(of client: AgentToolClient) -> String {
        host.personas.first { $0.id == client.personaID }?.name ?? "deleted"
    }

    func personaName(of grant: AgentGrant) -> String {
        personaName(of: AgentToolClient(grant: grant))
    }

    /// The agent folder's name for a client: its name and the app it runs in, as in "claude · Terminal".
    nonisolated static func folderName(for client: AgentClientIdentity) -> String {
        [client.name, client.host].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    // MARK: Events

    /// Keeps what happened in an agent tab for its client's next result, in `state`, which a grant has from its first call. A tab that a page opened beyond the limit of agent tabs closes again, on the next turn of the run loop, since the engine is still in the callback that made it. A new page, which an address change counts before its document finishes loading, withdraws the cards about the tab's earlier one, and a tab that closed or left the client withdraws all of its cards. A download or a link to another app that a page started asks the user on a card of its own (P6, P11), one at a time per tab.
    func tab(_ tabID: UUID, of ownerID: UUID, didReport report: AgentTabReport, state: AgentGrantState?, client: AgentToolClient? = nil) {
        if case .opened(let openedID) = report, host.agentTabs(of: ownerID).count > AgentLimits.agentTabs {
            let host = host
            DispatchQueue.main.async { MainActor.assumeIsolated { host.closeAgentTab(openedID) } }
            state?.record(.closedOverLimit, tab: tabID)
            return
        }
        // One download card per tab waits at a time, so that a page cannot pile them up; a page's further downloads meanwhile do not start, and the agent hears so.
        if case .downloadAsked = report, let state, approvals.pending.contains(where: { $0.tabID == tabID && $0.kind == .download }) {
            state.record(.decided("A page in \(state.handles.tabs.handle(for: tabID)) started another download while one waits for the user, so Arch did not start it."), tab: tabID)
            return
        }
        if case .externalAppAsked(let url) = report, let state, !asksAboutExternalApp(url, in: tabID, state: state) { return }
        state?.record(.report(report), tab: tabID)
        switch report {
        case .addressChanged, .loaded: approvals.withdraw(tab: tabID, owner: ownerID, document: state?.activity(of: tabID).pages ?? Int.max)
        case .closed, .takenOver:
            state?.endWrittenLoad(in: tabID)
            approvals.withdraw(tab: tabID, owner: ownerID, document: nil)
        case .downloadAsked(let url): if let state { askAboutDownload(url, in: tabID, of: ownerID, state: state, client: client) }
        case .externalAppAsked(let url): if let state { askAboutExternalApp(url, in: tabID, of: ownerID, state: state, client: client) }
        default: break
        }
    }

    /// Rule P6 when a page in an agent tab starts a download: a download the user allowed once, or one from a site the user allowed downloads from for the session, goes ahead.
    func tab(_ tabID: UUID, mayDownload url: URL, state: AgentGrantState?) -> Bool {
        guard let state else { return false }
        if state.allowedDownloads.remove(url) != nil { return true }
        return url.host.map { state.downloadSites.contains($0.lowercased()) } ?? false
    }

    /// Rule P16 at each main frame navigation, redirect hop, and popup of an agent tab, whoever started it: the exclusions then in force decide, and a refusal is an event for the client. For an in-app session, rule P13 at each server redirect of a navigation by an address its agent wrote (`writtenLoads`), never at a popup or a link that opens elsewhere: a hop to a site outside `scope` stops, and the call that waits for the navigation asks the user with the hop's full address (`heldHops`), or, once no call waits, the hop is refused and the agent hears so. The navigation's checks end once the tab commits another document than the one it showed at the navigation's first check.
    func tab(_ tabID: UUID, mayLoad url: URL, kind: AgentLoadKind, state: AgentGrantState?, scope: AgentSiteScope? = nil) -> Bool {
        if case .refused = AgentPolicy.mayLoad(url, allowsAI: allowsAI) {
            state?.record(.refused(url), tab: tabID)
            return false
        }
        guard kind != .popup, let state, var load = state.writtenLoads[tabID] else { return true }
        let document = host.tabs(withIDs: [tabID]).first?.documentID
        if load.documentID == nil {
            load.documentID = document
            state.writtenLoads[tabID] = load
        } else if load.documentID != document {
            state.writtenLoads[tabID] = nil
            return true
        }
        guard kind == .redirect, let scope, AgentSeenAddress(url) != AgentSeenAddress(load.url),
              case .asks(let question) = scope.hop(to: url, ofWrittenAddress: true) else { return true }
        if load.isAwaited {
            state.heldHops[tabID] = AgentHeldHop(loadID: load.id, question: question)
        } else {
            state.writtenLoads[tabID] = nil
            state.record(.hopStopped, tab: tabID)
        }
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
        // A dialog's text comes only from a frame on the page's own site that AI may read, as a snapshot reads no other site's frame; the engine names the frame's origin, and a dialog whose origin it does not name gives no text.
        func dialogText(_ text: String, frame: URL?) -> String? {
            guard let frame, let pageURL, let site = AgentSite.of(frame), site == AgentSite.of(pageURL), allowsAI(frame) else { return nil }
            return pageText(text)
        }
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
        case .report(.stoppedLoading), .report(.addressChanged):
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
        case .report(.dialogWaiting(let kind, let message, let frame)):
            json["kind"] = "dialogWaiting"
            json["rule"] = "P9"
            json["dialog"] = .string(kind.rawValue)
            // A sign-in names its host only when it is the page's own, so that neither a proxy's host nor another site's, as a frame's on a site excluded from AI, reaches the agent.
            let text = kind != .signIn ? dialogText(message, frame: frame) : message.lowercased() == pageURL?.host?.lowercased() ? pageName(message) : nil
            if let text { json["message"] = .string(text) }
            switch kind {
            case .confirm, .prompt: line = "\(handle) shows a \(kind.rawValue) dialog, which waits for the user in Arch (P9)" + (text.map { ": \($0)" } ?? ".")
            case .leavePage: line = "\(handle) asks whether to leave its page, which waits for the user in Arch (P9)."
            case .signIn: line = "\(handle) asks for a user name and password\(text.map { " for \($0)" } ?? ""), which the user answers in Arch (P9)."
            }
        case .report(.alertDismissed(let message, let frame)):
            json["kind"] = "alertDismissed"
            json["rule"] = "P10"
            let text = dialogText(message, frame: frame)
            if let text { json["message"] = .string(text) }
            line = "\(handle) showed an alert, which Arch dismissed (P10)" + (text.map { ": \($0)" } ?? ".")
        case .report(.downloadAsked(let url)):
            json["kind"] = "downloadAsked"
            json["rule"] = "P6"
            let text = pageName(url.lastPathComponent)
            if let text { json["name"] = .string(text) }
            line = "\(handle) started a download\(text.map { " of \($0)" } ?? ""), which waits for the user in Arch (P6)."
        case .report(.downloadStarted(let url)):
            json["kind"] = "downloadStarted"
            let text = pageName(url.lastPathComponent)
            if let text { json["name"] = .string(text) }
            line = "\(handle) started a download\(text.map { " of \($0)" } ?? "") that the user allowed. list_downloads shows how it goes."
        case .report(.externalAppAsked(let url)):
            json["kind"] = "externalAppAsked"
            json["rule"] = "P11"
            let text = pageName(url.scheme ?? "")
            if let text { json["scheme"] = .string(text) }
            line = "\(handle) tried to open a link in another app\(text.map { " with the scheme \($0)" } ?? ""), which waits for the user in Arch (P11)."
        case .decided(let sentence):
            json["kind"] = "decided"
            line = sentence
        case .refused(let url):
            json["kind"] = "navigationRefused"
            json["rule"] = "P16"
            let isWeb = url.scheme.map { AgentPolicy.webSchemes.contains($0.lowercased()) } ?? false
            // The scheme is the page's choice, as the address of its own navigation.
            let scheme = isWeb ? nil : pageName(url.scheme ?? "")
            if let scheme { json["scheme"] = .string(scheme) }
            line = isWeb ? "Arch stopped \(handle) from loading a site excluded from AI (P16)."
                : "Arch stopped \(handle) from loading an address with \(scheme.map { "the scheme \($0), which" } ?? "a scheme that") agents never open (P16)."
        case .hopStopped:
            json["kind"] = "redirectStopped"
            json["rule"] = "P13"
            line = "Arch stopped \(handle)'s navigation at a redirect to a site outside the session's scope, since no call waited to ask the user (P13). Navigate to the address again to let the user decide."
        case .closedOverLimit:
            json["kind"] = "closedOverLimit"
            line = "A page in \(handle) opened another tab, which Arch closed: a client has at most \(AgentLimits.agentTabs) agent tabs open."
        }
        return (line, .object(json))
    }

    // MARK: Helpers

    /// A name a page gives, such as its title, a link's scheme, or a download's file name, as an untrusted block of at most `AgentLimits.pageNameCharacters` characters; a longer one is cut and ends with an ellipsis. Pages choose them freely, and WebKit does not cut titles.
    static func pageName(_ name: String, url: URL?) -> String {
        let displayName = reducedName(name, url: url)
        let cut = displayName.prefix(AgentLimits.pageNameCharacters)
        return AgentUntrusted.wrap(cut.endIndex < displayName.endIndex ? String(cut) + "\u{2026}" : displayName, url: url)
    }

    /// Some documents use their own address as the title. Reduce it wherever the browser reports that page name.
    private static func reducedName(_ name: String, url: URL?) -> String {
        guard let url, AgentAddress.isOwnAddress(name, of: url) else { return name }
        return AgentAddress.reduced(url).absoluteString
    }

    /// What a call answers in place of a result whose text would pass its limit; a tab's handle stays.
    static func tooLong(_ result: AgentToolResult, tool: String) -> AgentToolResult {
        var structured: [String: AgentJSON] = ["limits": ["resultTextBytes": .number(Double(AgentLimits.resultTextBytes))]]
        if let handle = result.structured?["tab"]?.stringValue, handle.count <= 16 { structured["tab"] = .string(handle) }
        return AgentToolResult(status: .error, code: "limitReached",
                               text: "\(tool)'s result would pass \(AgentLimits.resultTextBytes / 1024) KB of text, the most a result carries, as a page's very long address can make it.",
                               structured: .object(structured))
    }

    /// Waits until the call has its outcome, `seconds` pass, or the waiting task is cancelled, and says whether it has its outcome; the outcome answers at once, without polling.
    static func wait(for box: AgentCallBox, seconds: TimeInterval) async -> Bool {
        if box.outcome != nil { return true }
        let once = AgentOnce<Bool>()
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(with: false)
        }
        defer { timer.cancel() }
        _ = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard once.begin(continuation) else { return }
                box.whenFinished { _ in once.resume(with: true) }
            }
        } onCancel: {
            once.resume(with: false)
        }
        return box.outcome != nil && !Task.isCancelled
    }

    /// Polls `condition` on the main actor every 50 milliseconds until it holds, `seconds` pass, or the task is cancelled, and says whether it held.
    static func poll(for seconds: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    static func integer(_ value: AgentJSON) -> Int? {
        guard case .number(let number) = value else { return nil }
        return Int(number)
    }

    /// A number as results write it, such as 16,000, whatever the Mac's region.
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? (value == 1 ? "1 second" : "\(Int(value)) seconds") : String(format: "%.1f seconds", value)
    }

    static func error(_ code: String, _ text: String) -> Outcome {
        Outcome(result: AgentToolResult(status: .error, code: code, text: text))
    }

    static func notAvailable(_ text: String) -> Outcome {
        error("notAvailable", text)
    }

    /// Shows a card for the client's call and waits for the user's answer, at most until the call's deadline. A session an outside client started with `--deny-approvals` gets a denial at once, and no card opens; nor does one for a call whose session's turn ended or that the user took over.
    func request(_ card: AgentApproval, for client: AgentToolClient) async -> AgentApprovalAnswer {
        guard !client.deniesApprovals else { return .ended(Self.deniedApprovalsReason) }
        guard client.isCurrent else { return .ended(Self.notCurrentReason) }
        var card = card
        if let callDeadline, callDeadline < card.deadline { card.deadline = callDeadline }
        return await approvals.request(card)
    }

    static let deniedApprovalsReason = "This task was started with approvals denied, so Arch denied the step without asking the user."
    static let notCurrentReason = "The session's turn ended or the user took the session over."


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

/// Who a call is for: an outside client's grant, or an in-app session. The host runs both on the same path and reads the same facts from both; a session adds its site scope (P13), what is left of its call limits, and the turn and take-over the call belongs to.
struct AgentToolClient {
    struct Session {
        var siteScope: [String]
        var hasSearchResults: Bool
        var callsLeftThisTurn: Int
        var callsLeftThisSession: Int
        var readerExcerpt: AgentReaderExcerpt?
        /// The turn and the take-over the call arrived in; a call whose turn ended or whose session the user took over meanwhile reads and acts on nothing more.
        var callEpoch = 0
        var takeoverGeneration = 0
    }

    /// The grant's or session's ID, which owns its agent tabs.
    var id: UUID
    var personaID: UUID
    /// The space where its agent folder goes; one that is gone falls back to the Persona's first.
    var spaceID: UUID
    var level: AgentAccessLevel
    var scopes: AgentGrantScopes
    /// The name cards and Touch ID's reason give the client: an outside client's as Arch verified it, also for a session it started, or the title of a session the user started.
    var name: String
    /// The agent folder's name: the client and its app, as "claude · Terminal", or the session's title (docs/agents.md, Agent folders).
    var folderName: String
    /// The policy's kind of client: an in-app session has a site scope, which applies to its navigation and typing (P13, P14), also in a session an outside client started.
    var kind: AgentClientKind
    /// Whether the access comes from an outside client, whose sensitive Allow and Share count only after Touch ID or the login password: a grant, or a session an outside client started with `arch-cli task`.
    var isOutsideClient: Bool
    /// A session an outside client started with `--deny-approvals`: each card is denied at once, and none opens.
    var deniesApprovals = false
    /// Set for an in-app session.
    var session: Session?
    /// The in-app session itself, whose scope the host checks written addresses and redirect hops against and adds the addresses the user allows to.
    var inAppSession: AgentSession?

    init(grant: AgentGrant) {
        id = grant.id
        personaID = grant.personaID
        spaceID = grant.spaceID
        level = grant.level
        scopes = grant.scopes
        name = grant.client.displayName
        folderName = AgentToolHost.folderName(for: grant.client)
        kind = .outside
        isOutsideClient = true
    }

    /// An in-app session, whose `search_history` follows Let In-App Agents Search History and which starts no tasks of its own.
    @MainActor init(session: AgentSession, searchesHistory: Bool) {
        id = session.id
        personaID = session.personaID
        spaceID = session.spaceID
        level = session.mode
        scopes = AgentGrantScopes(searchHistory: searchesHistory, startTasks: false)
        // A session an outside client started names the client as Arch verified it, never words of the client's task.
        name = session.cardName
        folderName = session.title
        kind = .inApp
        isOutsideClient = session.isFromOutsideClient
        if case .outsideClient(_, _, true) = session.origin { deniesApprovals = true }
        self.session = Session(siteScope: session.scope.sites, hasSearchResults: session.scope.searchResults != nil,
                               callsLeftThisTurn: session.callsLeftThisTurn, callsLeftThisSession: session.callsLeftThisSession, readerExcerpt: session.readerExcerpt,
                               callEpoch: session.callEpoch, takeoverGeneration: session.takeoverGeneration)
        inAppSession = session
    }

    /// Whether the call's session still runs it: not ended, not taken over, and in the turn and take-over it arrived in. An outside client's grant always does.
    @MainActor var isCurrent: Bool {
        guard let owner = inAppSession, let session else { return true }
        return !owner.hasEnded && !owner.isTakenOver && owner.callEpoch == session.callEpoch && owner.takeoverGeneration == session.takeoverGeneration
    }
}

// MARK: In-app sessions

/// An in-app session's calls (docs/agents.md, In-app sessions; Site scope and navigation): every tool runs on the grant's path (`run(_:for:state:)`) with the session's own tool state (`AgentSession.toolState`), the session as the agent folder's owner, its site scope for written addresses and redirect hops (P13), and its cards in its panel. The session's details, lists, and guide are its own, a question waits only during a turn, and Take Over shows the tab a read is using.
extension AgentToolHost {
    /// The tools an in-app session runs: every served tool but `approval_wait`, since a session's call waits on its card instead of answering `approvalPending`.
    static let sessionServedTools = servedTools.filter { $0 != "approval_wait" }

    /// The tools an in-app session in `mode` with `scopes` can call, in catalog order, for its `tools/list`.
    static func sessionTools(for mode: AgentAccessLevel, scopes: AgentGrantScopes) -> [AgentTool] {
        tools(for: mode, scopes: scopes).filter { sessionServedTools.contains($0.name) }
    }

    func run(_ call: AgentToolCall, in session: AgentSession, searchesHistory: Bool) async -> AgentToolResult {
        await runSession(call, in: session, searchesHistory: searchesHistory).result
    }

    /// Runs an in-app session's call, with its result, the step the transcript shows, the site the activity log records, and the user's decision when a card asked.
    func runSession(_ call: AgentToolCall, in session: AgentSession, searchesHistory: Bool) async -> Outcome {
        guard let tool = AgentToolCatalog.tool(named: call.name) else { return Self.error("unknownTool", "Arch has no tool named \(call.name).") }
        guard Self.sessionServedTools.contains(tool.name) else { return Self.notAvailable("In-app sessions do not run \(tool.name).") }
        // The harness checks guide's arguments itself, so an unknown topic is answered with the topic names, as arch-cli guide answers it, and a null topic gives the guide.
        if tool.name == "guide" { return Outcome(result: AgentHarness.guideResult(arguments: call.arguments, inSession: true)) }
        if let problem = Self.problem(with: call.arguments, for: tool) { return Self.error("invalidArguments", problem) }
        if tool.name == "ask_user" {
            guard session.isTurnRunning, !session.hasEnded, !session.isTakenOver, session.acceptsQuestions else {
                return Outcome(result: AgentToolResult(status: .refused, code: "stopped", text: "This session is not accepting questions for this turn."))
            }
            if case .outsideClient(_, _, true) = session.origin {
                return Outcome(result: AgentToolResult(status: .denied, code: "notAvailable", text: "This task was started with user prompts disabled."))
            }
        }
        let client = AgentToolClient(session: session, searchesHistory: searchesHistory)
        // Take Over shows the tab a read is using.
        var reading: UUID?
        if tool.name == "read_text" || tool.name == "snapshot", let id = call.arguments["tab"]?.stringValue.flatMap(session.handles.tabs.id(for:)) {
            reading = session.beganReading(id)
        }
        defer { if let reading { session.finishedReading(reading) } }
        let outcome = await run(call, for: client, state: session.toolState)
        // The full addresses behind a snapshot's link refs are seen, so that writing one of them opens it without asking.
        if tool.name == "snapshot", outcome.result.status == .ok, client.isCurrent,
           let id = call.arguments["tab"]?.stringValue.flatMap(session.handles.tabs.id(for:)), let record = session.toolState.snapshots.records[id] {
            var scope = session.scope
            record.refs.values.compactMap(\.href).forEach { scope.see($0) }
            if scope != session.scope { session.scope = scope }
        }
        return outcome
    }

    /// An in-app session's details (docs/agents.md, Tools ▸ Catalog): its mode, its Persona and space, its site scope, its tabs, what is left of its limits, and what asks. The Persona and space read as "Persona / Space".
    private func sessionInfo(ofSession client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        let session = client.session ?? AgentToolClient.Session(siteScope: [], hasSearchResults: false, callsLeftThisTurn: 0, callsLeftThisSession: 0)
        let persona = host.personas.first { $0.id == client.personaID }?.name ?? "deleted"
        let space = space(of: client)
        let spaceHandle = space.map { handles.spaces.handle(for: $0.id) }
        let place = space.map { "\(persona) / \($0.name) (\(spaceHandle ?? ""))" } ?? "the \(persona) Persona"
        let openTabs = host.agentTabs(of: client.id).count
        let shared = handles.sharedTabIDs.map { handles.tabs.handle(for: $0) }
        let asks = Self.whatAsksInSession(client.level)
        let sites = session.siteScope.isEmpty ? "no sites yet" : session.siteScope.joined(separator: ", ")
        var lines = ["This session works in \(place), in \(client.level.title)."]
        lines.append("Site scope: \(sites)\(session.hasSearchResults ? ", and the search engine's results address" : "").")
        lines.append("Agent tabs: \(openTabs == 0 ? "none" : String(openTabs)) open, at most \(AgentLimits.agentTabs) at once, in the agent folder \u{201C}\(client.folderName)\u{201D}. Tabs the user shared: \(shared.isEmpty ? "none" : shared.joined(separator: ", ")).")
        lines.append("Limits: \(session.callsLeftThisTurn) of \(AgentLimits.toolCallsPerTurn) tool calls left for this message and \(session.callsLeftThisSession) of \(AgentLimits.toolCallsPerSession) for the session, \(AgentLimits.actionsPerSecond) actions a second.")
        lines.append(contentsOf: asks)
        if let excerpt = session.readerExcerpt, handles.sharedTabIDs.contains(excerpt.tabID),
           host.userTabs(in: client.personaID).contains(where: excerpt.matches), AgentPolicy.showsTitle(of: excerpt.url, allowsAI: allowsAI) {
            if let text = excerpt.selection { lines.append("Selected text shared from the reader:\n" + AgentUntrusted.wrap(text, url: excerpt.url)) }
            if let reply = excerpt.reply { lines.append("Previous model answer shared from the reader:\n" + AgentUntrusted.wrap(reply, url: excerpt.url)) }
        }
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

    /// What asks the user or is refused at each mode in an in-app session (docs/agents.md, Modes; Site scope and navigation).
    static func whatAsksInSession(_ level: AgentAccessLevel) -> [String] {
        let interactions: String
        switch level {
        case .readOnly: interactions = "Interactions other than scroll and hover are refused, and so are sensitive steps such as request_approval."
        case .askBeforeActing: interactions = "Each interaction asks the user first, and sensitive steps such as request_approval always ask."
        case .actInAgentTabs: interactions = "Interactions in your agent tabs on sites in scope run without asking; on other sites they ask once per site, and sensitive steps such as request_approval always ask."
        }
        return [
            "Reading runs without asking, and so does following a link by its ref. An address you write opens without asking only when a page or the user showed it, when it is the search engine's results address, or when it is the bare origin of a site in scope; any other address asks the user in every mode, and so does a redirect of it to a site outside the scope. \(interactions)",
            "Arch refuses typing passwords, codes, or card details, file choosers, CAPTCHAs, sites excluded from AI, internal pages, and tabs you were not given. Hand such steps to the user with hand_to_user. Downloads and links to other apps ask the user, and the tabs the user shared are for reading only.",
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
        let sharedIDs = Set(handles.sharedTabIDs)
        let tabs = shared ? host.userTabs(in: client.personaID).filter { sharedIDs.contains($0.id) } : host.agentTabs(of: client.id)
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
                let title = AgentUntrusted.wrap(Self.reducedName(tab.title, url: tab.url), url: tab.url)
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
        case 0: summary = shared ? "The user has shared no tabs with this session." : "This session has no agent tabs open."
        case 1: summary = "1 \(kind) tab."
        default: summary = "\(tabs.count) \(kind) tabs."
        }
        return AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"), structured: ["scope": .string(kind), "tabs": .array(rows)])
    }

}

/// Resumes a continuation once, with the first of the answers that may come, as a page's answer and a timer, on whatever thread each comes.
final class AgentOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    private var ended = false

    init(_ continuation: CheckedContinuation<Value?, Never>? = nil) {
        self.continuation = continuation
    }

    /// A cancellation or timeout can end a read before its continuation is installed.
    func begin(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let shouldStart = lock.withLock {
            guard !ended else { return false }
            self.continuation = continuation
            return true
        }
        if !shouldStart { continuation.resume(returning: nil) }
        return shouldStart
    }

    func resume(with value: Value?) {
        let waiting = lock.withLock {
            ended = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
