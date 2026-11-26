// One catalog serves `tools/list`, `arch-mcp`, `arch-cli`, and the API-key loop (docs/agents.md, Tools).
// It names each tool, describes its access class and parameters with limits, and gives its MCP annotations.
// The catalog describes tools; the tool host decides each call. Nothing here grants access.
import Foundation

/// A tool's access class, which the modes and rules gate (docs/agents.md, Permissions, approvals, and injection defenses ▸ Modes).
public enum AgentToolClass: String, Sendable, CaseIterable {
    /// R: reads.
    case reads = "R"
    /// N: navigates in agent tabs.
    case navigates = "N"
    /// I: interacts with a page.
    case interacts = "I"
    /// S: sensitive; always asks.
    case sensitive = "S"

    public var title: String {
        switch self {
        case .reads: return "reads"
        case .navigates: return "navigates"
        case .interacts: return "interacts"
        case .sensitive: return "sensitive"
        }
    }
}

/// One named tool parameter and the constraints exposed in its JSON Schema.
public struct AgentToolParameter: Sendable {
    /// The JSON value shape a tool parameter accepts.
    public enum Kind: Sendable, Equatable {
        case string
        case integer
        case boolean
        /// A string from a fixed set.
        case choice([String])
        /// A list of at least one string, from a fixed set when one is given.
        case list([String]?)
    }

    public var name: String
    public var kind: Kind
    public var isRequired: Bool
    public var description: String
    public var minimum: Int?
    public var maximum: Int?
    public var pattern: String?

    public init(_ name: String, _ kind: Kind, required: Bool = false, _ description: String, minimum: Int? = nil, maximum: Int? = nil, pattern: String? = nil) {
        self.name = name
        self.kind = kind
        self.isRequired = required
        self.description = description
        self.minimum = minimum
        self.maximum = maximum
        self.pattern = pattern
    }

    /// The parameter's JSON Schema.
    public var schema: AgentJSON {
        var schema: [String: AgentJSON] = ["description": .string(description)]
        switch kind {
        case .string: schema["type"] = "string"
        case .integer: schema["type"] = "integer"
        case .boolean: schema["type"] = "boolean"
        case .choice(let choices):
            schema["type"] = "string"
            schema["enum"] = .array(choices.map(AgentJSON.string))
        case .list(let choices):
            schema["type"] = "array"
            var items: [String: AgentJSON] = ["type": "string"]
            if let choices { items["enum"] = .array(choices.map(AgentJSON.string)) }
            schema["items"] = .object(items)
            schema["minItems"] = 1
        }
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        if let pattern { schema["pattern"] = .string(pattern) }
        return .object(schema)
    }

    /// The type as `arch-cli tools` names it.
    public var typeName: String {
        switch kind {
        case .string: return "string"
        case .integer: return "integer"
        case .boolean: return "boolean"
        case .choice(let choices): return choices.joined(separator: "|")
        case .list(let choices): return "list of " + (choices?.joined(separator: "|") ?? "string")
        }
    }
}

/// A tool's catalog description, access class, parameters, and MCP annotations.
public struct AgentTool: Sendable {
    /// Notes the catalog's class column adds to a tool's class.
    public struct Traits: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Always waits for the user, so the 30-second tool limit does not apply and the call answers `approvalPending` after 45 seconds.
        public static let waitsForUser = Traits(rawValue: 1 << 0)
        /// An interaction that changes no data and so runs in Read Only (`scroll`, `hover`).
        public static let allowedInReadOnly = Traits(rawValue: 1 << 1)
        /// Needs the history scope of a grant or the in-app setting (`search_history`).
        public static let needsHistoryScope = Traits(rawValue: 1 << 2)
        /// Removes something the agent had (`close_tab`), which the MCP annotations mark as destructive.
        public static let destructive = Traits(rawValue: 1 << 3)
    }

    /// 1 to 64 characters from `a-z`, `0-9`, and `_`, valid for MCP, `AITool`, and both CLIs.
    public var name: String
    public var description: String
    public var toolClass: AgentToolClass
    public var parameters: [AgentToolParameter]
    public var traits: Traits

    public init(_ name: String, _ toolClass: AgentToolClass, _ traits: Traits = [], _ description: String, _ parameters: [AgentToolParameter] = []) {
        self.name = name
        self.toolClass = toolClass
        self.traits = traits
        self.description = description
        self.parameters = parameters
    }

    /// The input's JSON Schema: an object of the parameters and no others. A choice between parameters, such as `url` or `ref`, is in their descriptions, since some providers refuse `oneOf` and `anyOf` at a schema's top level; the tool host checks it.
    public var inputSchema: AgentJSON {
        var schema: [String: AgentJSON] = [
            "type": "object",
            // A parameter listed twice is a mistake in the definition: debug builds stop on it, and a release build keeps the first.
            "properties": .object(Dictionary(parameters.map { ($0.name, $0.schema) }, uniquingKeysWith: { first, _ in
                assertionFailure("\(name) lists a parameter twice.")
                return first
            })),
            "additionalProperties": false,
        ]
        let required = parameters.filter(\.isRequired).map { AgentJSON.string($0.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    /// MCP's tool annotations: `readOnlyHint` for class R, `openWorldHint` for N and I, and `destructiveHint` for `close_tab`, each written out, since MCP's defaults for a missing hint are the opposite for the last two. Arch does not rely on a client honoring them.
    public var annotations: AgentJSON {
        [
            "readOnlyHint": .bool(toolClass == .reads),
            "destructiveHint": .bool(traits.contains(.destructive)),
            "openWorldHint": .bool(toolClass == .navigates || toolClass == .interacts),
        ]
    }

    /// The tool as an entry of MCP's `tools/list` result.
    public var mcpDefinition: AgentJSON {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema, "annotations": annotations]
    }
}

/// The shared tool definitions used by agent sessions and local control clients.
public enum AgentToolCatalog {
    /// Tab handles: `t1`, `t2`, and so on, per session or per grant.
    static let tabPattern = "^t[1-9][0-9]*$"

    /// Defines a tab handle parameter with the catalog's handle pattern.
    private static func tab(required: Bool = true, _ description: String = "The agent tab's handle, such as t1.") -> AgentToolParameter {
        AgentToolParameter("tab", .string, required: required, description, pattern: tabPattern)
    }

    /// A number formatted for descriptions and the harness, such as 16,000, regardless of the Mac's region.
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// Defines a snapshot element reference parameter.
    private static func ref(required: Bool = true, _ description: String = "An element's ref from the tab's latest snapshot, such as e5.") -> AgentToolParameter {
        AgentToolParameter("ref", .string, required: required, description)
    }

    /// Every tool, in the catalog's order.
    public static let tools: [AgentTool] = [
        AgentTool("session_info", .reads, [], "Describes this session: its mode, Persona, space, and site scope, its agent tabs, the limits left, and which steps ask the user. Call it first."),
        AgentTool("list_spaces", .reads, [], "Lists the spaces of the session's Persona: handle, name, and number of agent tabs."),
        AgentTool("list_tabs", .reads, [], "Lists the session's agent tabs (handle, title, address, whether it is loading, and engine), or with scope shared, the tabs the user shared with the session (handle, title, and host).", [
            AgentToolParameter("scope", .choice(["agent", "shared"]), "Which tabs to list: agent, the default, or shared."),
        ]),
        AgentTool("request_tab", .reads, [.waitsForUser], "Asks the user to pick one of their own tabs to share with the session, for reading or for acting, and returns that tab, or denied.", [
            AgentToolParameter("reason", .string, required: true, "Why the session needs the tab, shown to the user."),
            AgentToolParameter("access", .choice(["read", "act"]), required: true, "Whether the session only reads the tab or also acts in it."),
        ]),
        AgentTool("open_tab", .navigates, [], "Opens an agent tab in the background at an http or https address, or at the link a ref names in a snapshot, and returns the new tab.", [
            AgentToolParameter("url", .string, "An http or https address. Give url or ref."),
            ref(required: false, "A link's ref from a snapshot of the tab named by tab."),
            tab(required: false, "The tab whose snapshot holds ref."),
            AgentToolParameter("engine", .choice(["chromium", "webkit"]), "The new tab's engine; the default engine when absent."),
            AgentToolParameter("private", .boolean, "Open in a private window with independent in-memory storage. Only this client or session can access this tab; false by default."),
        ]),
        AgentTool("navigate", .navigates, [], "Loads an address or a link from the tab's snapshot in an agent tab, or goes back, forward, or reloads, and returns the address and title once the document loads, or after 30 seconds.", [
            tab(),
            AgentToolParameter("url", .string, "An http or https address. Give one of url, ref, or action."),
            ref(required: false, "A link's ref from the tab's latest snapshot, whose address Arch keeps."),
            AgentToolParameter("action", .choice(["back", "forward", "reload"]), "Go back, go forward, or reload instead of loading an address."),
        ]),
        AgentTool("close_tab", .navigates, [.destructive], "Closes an agent tab that this session or client opened.", [
            tab(),
        ]),
        AgentTool("snapshot", .reads, [], "Returns the page as an outline of roles and names, with a ref for each element an action can target. Interactive mode keeps those elements and the landmarks and headings around them; full mode adds the visible text.", [
            tab(),
            AgentToolParameter("mode", .choice(["interactive", "full"]), "What to outline: interactive, the default, or full."),
            ref(required: false, "Outline only this element and what it contains."),
            AgentToolParameter("max_chars", .integer, "The outline's length in characters, \(number(AgentLimits.snapshotDefaultCharacters)) by default and at most \(number(AgentLimits.snapshotMaximumCharacters)).", minimum: 1, maximum: AgentLimits.snapshotMaximumCharacters),
            AgentToolParameter("diff", .boolean, "Return only the lines added, removed, or changed since your last snapshot of the same document in the tab; a new document returns the whole outline."),
        ]),
        AgentTool("read_text", .reads, [], "Returns the page's readable text from offset, at most max_chars characters per call, with the text's length so that further calls can read the rest.", [
            tab(),
            AgentToolParameter("offset", .integer, "The character to start from; 0 by default.", minimum: 0, maximum: AgentLimits.readTextMaximumCharacters),
            AgentToolParameter("max_chars", .integer, "At most \(number(AgentLimits.readTextCharactersPerCall)), the default.", minimum: 1, maximum: AgentLimits.readTextCharactersPerCall),
        ]),
        AgentTool("screenshot", .reads, [], "Captures the tab's viewport, its full page, or one element as an image. Fields whose values snapshots hide, and frames of other sites, are painted over.", [
            tab(),
            AgentToolParameter("area", .string, required: true, "viewport, full, or an element's ref."),
        ]),
        AgentTool("click", .interacts, [], "Clicks an element and returns what it hit and the events that followed.", [
            tab(),
            ref(),
            AgentToolParameter("count", .integer, "1, the default, or 2 for a double click.", minimum: 1, maximum: 2),
            AgentToolParameter("modifiers", .list(["Shift", "Control", "Alt", "Meta"]), "Keys held during the click."),
        ]),
        AgentTool("type", .interacts, [], "Types text into a field, after the text already there unless replace is true, and returns the field and the events that followed.", [
            tab(),
            ref(),
            AgentToolParameter("text", .string, required: true, "The text to type."),
            AgentToolParameter("replace", .boolean, "Replace the field's text instead of adding to it."),
            AgentToolParameter("submit", .boolean, "Press Enter after typing, which submits the field's form."),
        ]),
        AgentTool("press", .interacts, [], "Presses keys in the focused element, or in the element a ref names, and returns the events that followed.", [
            tab(),
            AgentToolParameter("keys", .string, required: true, "A key or a combination, such as Enter, Escape, or Meta+A."),
            ref(required: false),
        ]),
        AgentTool("select_option", .interacts, [], "Selects options of a select element and returns the selected values.", [
            tab(),
            ref(),
            AgentToolParameter("values", .list(nil), required: true, "The options to select, by value or label."),
        ]),
        AgentTool("scroll", .interacts, [.allowedInReadOnly], "Scrolls an element into view, or scrolls the page in a direction, and returns the new position.", [
            tab(),
            ref(required: false, "An element to scroll into view. Give ref or direction."),
            AgentToolParameter("direction", .choice(["up", "down", "left", "right"]), "The direction to scroll the page."),
            AgentToolParameter("amount", .integer, "How far to scroll, in CSS pixels.", minimum: 1),
        ]),
        AgentTool("hover", .interacts, [.allowedInReadOnly], "Moves the pointer over an element and returns the events that followed.", [
            tab(),
            ref(),
        ]),
        AgentTool("wait_for", .reads, [], "Waits until the tab's document loads, a text appears in the page, its address contains a text, or an element appears, and says whether that happened before timeout_ms.", [
            tab(),
            AgentToolParameter("load", .boolean, "Wait for the document to load. Give one of load, text, url, or ref."),
            AgentToolParameter("text", .string, "Wait for this text to appear in the page."),
            AgentToolParameter("url", .string, "Wait for the tab's address to contain this text."),
            ref(required: false, "Wait for this element to appear."),
            AgentToolParameter("timeout_ms", .integer, "At most \(number(AgentLimits.toolWaitSeconds * 1000)) milliseconds, the default.", minimum: 1, maximum: AgentLimits.toolWaitSeconds * 1000),
        ]),
        AgentTool("list_downloads", .reads, [], "Lists the downloads this session's tabs started: name, size, and state."),
        AgentTool("search_history", .reads, [.needsHistoryScope], "Searches the browsing history and returns titles and addresses without their queries and fragments. It needs the history scope; excluded sites are left out.", [
            AgentToolParameter("query", .string, required: true, "Words to look for in titles and addresses."),
            AgentToolParameter("limit", .integer, "At most \(AgentLimits.historyResults), the default.", minimum: 1, maximum: AgentLimits.historyResults),
        ]),
        AgentTool("ask_user", .reads, [.waitsForUser], "Asks the user a question in Arch and returns the answer.", [
            AgentToolParameter("question", .string, required: true, "The question."),
            AgentToolParameter("choices", .list(nil), "Answers to offer as buttons; the user can also write an answer."),
        ]),
        AgentTool("request_approval", .sensitive, [.waitsForUser], "Asks the user to approve a step before it is taken, such as a submission, a purchase, a message, a deletion, or a download, and returns approved, denied, or the user's instruction.", [
            AgentToolParameter("summary", .string, required: true, "The step, in one sentence."),
            AgentToolParameter("kind", .choice(["submit", "purchase", "send", "delete", "download", "other"]), required: true, "What kind of step it is."),
            tab(required: false, "The tab the step is in."),
        ]),
        AgentTool("hand_to_user", .reads, [.waitsForUser], "Hands a tab to the user for a step agents never take, such as signing in, a verification code, or payment details, and returns the user's Done or Cancel with what the user wrote.", [
            tab(),
            AgentToolParameter("reason", .choice(["sign_in", "verification", "payment", "other"]), required: true, "What the user needs to do."),
            AgentToolParameter("message", .string, required: true, "What to tell the user."),
        ]),
        AgentTool("approval_wait", .reads, [.waitsForUser], "Waits for the result of a call that answered approvalPending.", [
            AgentToolParameter("approval", .string, required: true, "The approval ID that the approvalPending answer named."),
        ]),
        AgentTool("guide", .reads, [], "Returns Arch's guide for agents, or one of its topics.", [
            AgentToolParameter("topic", .choice(AgentGuideTopic.allCases.map(\.rawValue)), "A topic; the guide itself when absent."),
        ]),
    ]

    /// Offered only when a hook grants it. Outside and interactive clients keep their own tool lists.
    public static let renameTab = AgentTool("rename_tab", .navigates, [], "Suggest a sidebar name for a run tab.", [
        AgentToolParameter("tab", .string, required: true, "The tab handle, such as t1."),
        AgentToolParameter("name", .string, required: true, "The suggested name, or an empty string to clear it.")
    ])

    /// Offered to an outside client whose grant has Watch Browser Events (`docs/hooks.md`, arch-mcp): events come as a tool, since MCP clients do not pass a server's notifications to their model (hook decision 11).
    public static let watchEvents = AgentTool("watch_events", .reads, [], "Returns the browser events of the grant's Persona after a sequence, up to \(AgentLimits.watchEventsPerCall) at a time, or waits up to timeout_ms for the first: tabs that open, load, change address or title, are selected, or close, downloads this client's tabs finished, and space switches. The user's own tabs show a watch ID such as w4 and their site only, never titles or pages; no tool accepts a watch ID.", [
        AgentToolParameter("kinds", .list(AgentEventFilter.kinds), "The event kinds to return; every kind when absent."),
        AgentToolParameter("after", .integer, "The last sequence of the previous result; replays the events Arch keeps after it. Without it, only new events.", minimum: 0),
        AgentToolParameter("timeout_ms", .integer, "How long to wait for a first event, at most \(number(AgentLimits.toolWaitSeconds * 1000)) milliseconds, the default.", minimum: 0, maximum: AgentLimits.toolWaitSeconds * 1000),
    ])

    /// The read-only tab request offered to an outside client's task session.
    public static let sessionTabRequest = AgentTool("request_tab", .reads, [.waitsForUser], "Asks the user to choose one tab to share for reading.", [
        AgentToolParameter("reason", .string, required: true, "Why this task needs another tab, shown to the user."),
        AgentToolParameter("access", .choice(["read"]), required: true, "Read-only access."),
    ])

    /// Finds a session tool, substituting its read-only tab request definition.
    public static func sessionTool(named name: String) -> AgentTool? {
        switch name {
        case sessionTabRequest.name: return sessionTabRequest
        default: return tool(named: name)
        }
    }

    /// Finds a shared tool or a tool offered only by a hook or outside client.
    public static func tool(named name: String) -> AgentTool? {
        if name == renameTab.name { return renameTab }
        if name == watchEvents.name { return watchEvents }
        return tools.first { $0.name == name }
    }

    /// The catalog as MCP's `tools/list` result, `{"tools": […]}`.
    public static var mcpToolList: AgentJSON {
        ["tools": .array(tools.map(\.mcpDefinition))]
    }
}
