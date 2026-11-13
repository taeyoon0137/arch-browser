// The tool host: where every tool call runs and is checked, the same code for every client (agent decision 5). This first host runs the reading tools that need no page: `session_info`, `list_spaces`, `list_tabs`, and `guide`, for an outside client's grant or an in-app session (`AgentToolClient`). Plan task VII.12 adds agent tabs and the reading and navigating tools, with their events, limits, and rules.
import AgentControl
import Foundation

/// The handles a grant's client uses for the launch: `t1`, `t2`, and so on for tabs and `s1`, `s2` for spaces, never reused, and the tabs it may see.
struct AgentGrantHandles {
    var tabs = AgentHandleTable(prefix: "t")
    var spaces = AgentHandleTable(prefix: "s")
    /// The client's agent tabs, in the order they opened; plan task VII.12 opens them.
    var agentTabIDs: [UUID] = []
    /// The tabs the user shared with the client; plan task VII.13 shares them through `request_tab`.
    var sharedTabIDs: [UUID] = []
}

struct AgentHandleTable {
    let prefix: String
    private var next = 1
    private var handles: [UUID: String] = [:]
    private var ids: [String: UUID] = [:]

    init(prefix: String) {
        self.prefix = prefix
    }

    /// The handle of `id`, given on first use.
    mutating func handle(for id: UUID) -> String {
        if let handle = handles[id] { return handle }
        let handle = "\(prefix)\(next)"
        next += 1
        handles[id] = handle
        ids[handle] = id
        return handle
    }

    /// The ID behind a handle this table gave; a handle from elsewhere reads as not found.
    func id(for handle: String) -> UUID? {
        ids[handle]
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

    /// The grant's or session's ID.
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

@MainActor struct AgentToolHost {
    /// The tools this build runs; `tools/list` lists only these, and the others answer that they are not available yet.
    static let servedTools = ["session_info", "list_spaces", "list_tabs", "guide"]

    let host: any AgentBrowserHost
    /// Whether AI may read a page at this address: the site exclusions of `ai.json` (docs/agents.md, Site exclusions).
    let allowsAI: (URL) -> Bool

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

    func run(_ call: AgentToolCall, for grant: AgentGrant, handles: inout AgentGrantHandles) -> AgentToolResult {
        run(call, for: AgentToolClient(grant: grant), handles: &handles)
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
        case "session_info": return client.session == nil ? sessionInfo(client, handles: &handles) : sessionInfo(ofSession: client, handles: &handles)
        case "list_spaces": return listSpaces(client, handles: &handles)
        case "list_tabs": return listTabs(shared: call.arguments["scope"]?.stringValue == "shared", client, handles: &handles)
        default: return AgentToolResult(status: .error, code: "notAvailable", text: "This build of Arch does not run \(tool.name) yet.")
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
        }
        return nil
    }

    // MARK: Tools

    private func sessionInfo(_ client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        let persona = host.personas.first { $0.id == client.personaID }?.name ?? "deleted"
        let space = space(of: client)
        let spaceHandle = space.map { handles.spaces.handle(for: $0.id) }
        let openTabs = host.tabs(withIDs: Set(handles.agentTabIDs)).count
        let asks = Self.whatAsks(client.level)
        var lines = ["This client has \(client.level.title) access in the \(persona) Persona" + (space.map { ", in the space \($0.name) (\(spaceHandle ?? ""))." } ?? ".")]
        lines.append("Site scope: none. An outside client navigates freely in its own agent tabs.")
        lines.append("Agent tabs: \(openTabs == 0 ? "none" : String(openTabs)) open, at most \(AgentLimits.agentTabs) at once.")
        lines.append("Limits: \(AgentLimits.toolCallsPerGrantPerDay.formatted(.number.locale(Locale(identifier: "en_US")))) tool calls a day for this grant, \(AgentLimits.actionsPerSecond) actions a second.")
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
            "Arch refuses typing passwords, codes, or card details, sites excluded from AI, and tabs you were not given. Hand such steps to the user with hand_to_user.",
        ]
    }

    private func listSpaces(_ client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        let spaces = host.spaces(in: client.personaID)
        let agentTabs = host.tabs(withIDs: Set(handles.agentTabIDs))
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

    /// The client's agent tabs, or the tabs the user shared, in sidebar order. A tab on a site excluded from AI is listed without its title or address (rule P16).
    private func listTabs(shared: Bool, _ client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        let ids = shared ? handles.sharedTabIDs : handles.agentTabIDs
        let tabs = host.tabs(withIDs: Set(ids))
        var rows: [AgentJSON] = []
        var lines: [String] = []
        for tab in tabs {
            let handle = handles.tabs.handle(for: tab.id)
            let excluded = tab.url.map { !allowsAI($0) } ?? false
            var row: [String: AgentJSON] = ["handle": .string(handle), "excluded": .bool(excluded)]
            var line = handle
            if excluded {
                line += "  (a site excluded from AI)"
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
        case 0: summary = shared ? "The user has shared no tabs with this \(client.session == nil ? "client" : "session")." : "This \(client.session == nil ? "client" : "session") has no agent tabs open."
        case 1: summary = "1 \(kind) tab."
        default: summary = "\(tabs.count) \(kind) tabs."
        }
        return AgentToolResult(status: .ok, text: ([summary] + lines).joined(separator: "\n"), structured: ["scope": .string(kind), "tabs": .array(rows)])
    }

    /// An in-app session's details (docs/agents.md, Tools ▸ Catalog): its mode, its Persona and space, its site scope, its tabs, what is left of its limits, and what asks. The Persona and space read as "Persona / Space".
    private func sessionInfo(ofSession client: AgentToolClient, handles: inout AgentGrantHandles) -> AgentToolResult {
        guard let session = client.session else { return sessionInfo(client, handles: &handles) }
        let persona = host.personas.first { $0.id == client.personaID }?.name ?? "deleted"
        let space = space(of: client)
        let spaceHandle = space.map { handles.spaces.handle(for: $0.id) }
        let place = space.map { "\(persona) / \($0.name) (\(spaceHandle ?? ""))" } ?? "the \(persona) Persona"
        let openTabs = host.tabs(withIDs: Set(handles.agentTabIDs)).count
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

    /// The grant's or session's space, or the Persona's first space once that one is gone.
    func space(of client: AgentToolClient) -> AgentSpaceInfo? {
        let spaces = host.spaces(in: client.personaID)
        return spaces.first { $0.id == client.spaceID } ?? spaces.first
    }
}
