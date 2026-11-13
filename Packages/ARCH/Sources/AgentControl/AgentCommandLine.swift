// `arch-cli`'s command table and argument parsing, and the `argv[0]` dispatch that makes the same executable `arch-mcp` (docs/agents.md, agent decision 2; arch-cli). The table also generates the `cli` guide topic and `--help`, so the three cannot drift apart. The executable in `ArchCLI` only runs what this parses.
import Foundation

/// What the executable runs as.
public enum AgentInvocation: Equatable, Sendable {
    /// `arch-cli` with its arguments.
    case cli([String])
    /// `arch-mcp`, started under that name (as through its link) or as `arch-cli mcp`, with its arguments.
    case mcp([String])
}

public enum AgentCLICommand: Equatable, Sendable {
    case help
    case status
    /// The guide, or one of its topics.
    case guide(AgentGuideTopic?)
    case tools
    /// The spaces of the grant's Persona (`list_spaces`).
    case spaces
    /// The grant's agent tabs, or with `--shared` the tabs the user shared (`list_tabs`).
    case tabs(shared: Bool)
    /// Gives up this client's grant (`grant/release`).
    case release
    /// The configuration that adds arch-mcp to one client, or to each when nil.
    case mcpConfig(AgentMCPConfigurationFormat?)
    case setup(AgentMCPSetupClient)
    /// PATH links, in the folder `--dir` names or else one PATH chooses.
    case links(AgentLinksAction, folder: String?)
    /// The entry skill at the places named by `--target` and `--path`, in order; `list` without either lists every target.
    case skills(AgentSkillsAction, places: [AgentSkillInstaller.Place])
    /// Starts an in-app session on the user's `agent` route and prints its progress until its turn ends (`task/start`).
    case task(AgentTaskStart)
    /// The sessions this client started (`sessions/list`), or stopping one (`task/stop`).
    case sessions(AgentSessionsAction)
    /// One tool call: `open`, `navigate`, `back`, `forward`, `reload`, `close`, `snapshot`, `text`, `click`, `type`, `press`, `select`, `scroll`, `hover`, `wait`, `downloads`, `history`, and `call` with any tool's name and arguments.
    case tool(AgentToolCall)
    /// `type` with `--text -`: the call without its `text`, which comes from standard input so that it stays out of argument lists and shell history.
    case typeFromStandardInput(AgentToolCall)
    /// `screenshot`, whose image goes only to the file `-o` names, or to `arch-screenshot-<time>.jpg` in the current folder.
    case screenshot(AgentToolCall, output: String?)
}

public enum AgentSessionsAction: Equatable, Sendable {
    case list
    case show(UUID)
    case stop(UUID)
}

public enum AgentLinksAction: String, CaseIterable, Sendable {
    case install
    case remove
}

public enum AgentSkillsAction: String, CaseIterable, Sendable {
    case list
    case install
    case remove
}

public struct AgentCLIRequest: Equatable, Sendable {
    public var command: AgentCLICommand
    /// `--json`: print the result's structured value instead of text. `guide`, `--help`, the setup commands, and `skills` always print text.
    public var json: Bool

    public init(command: AgentCLICommand, json: Bool) {
        self.command = command
        self.json = json
    }
}

public struct AgentUsageError: Error, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// A row of the command table.
public struct AgentCLICommandSpec: Sendable {
    public var name: String
    /// The arguments as the usage line writes them, such as `[topic]`.
    public var arguments: String
    public var summary: String
    /// Whether the command reaches the running Arch.
    public var needsArch: Bool
}

public enum AgentCommandLine {
    public static let commands: [AgentCLICommandSpec] = [
        AgentCLICommandSpec(name: "status", arguments: "", summary: "Shows whether Arch is running, whether agent access is on, this client's grant, and both versions.", needsArch: true),
        AgentCLICommandSpec(name: "guide", arguments: "[topic]", summary: "Prints the guide for agents, or one of its topics: \(AgentGuideTopic.allCases.map(\.rawValue).joined(separator: ", ")).", needsArch: false),
        AgentCLICommandSpec(name: "tools", arguments: "", summary: "Lists Arch's agent tools with their classes and parameters.", needsArch: false),
        AgentCLICommandSpec(name: "spaces", arguments: "", summary: "Lists the spaces of this client's Persona. The first command that reaches Arch asks you there to allow this client.", needsArch: true),
        AgentCLICommandSpec(name: "tabs", arguments: "[--shared]", summary: "Lists this client's agent tabs, or with --shared the tabs you shared with it.", needsArch: true),
        AgentCLICommandSpec(name: "release", arguments: "", summary: "Gives up this client's grant, so that its next command asks again.", needsArch: true),
        AgentCLICommandSpec(name: "task", arguments: "\"<task>\" [--space name] [--mode read|ask|act] [--model name] [--deny-approvals]", summary: "Starts an agent session in Arch on your AI subscription and prints its progress until its turn ends. It needs a grant with Start Agent Tasks and runs in the grant's Persona, in the space --space names or the grant's, at most at the grant's access and the mode Settings sets for new sessions, which --mode can only lower. Arch asks you in its own window before sensitive steps; --deny-approvals denies each at once.", needsArch: true),
        AgentCLICommandSpec(name: "sessions", arguments: "[list|show id|stop id]", summary: "Lists the agent sessions this client started, shows one, or stops one.", needsArch: true),
        AgentCLICommandSpec(name: "mcp", arguments: "[--session]", summary: "Runs as arch-mcp, the MCP server on standard input and output. Arch starts it with --session for its own agent sessions.", needsArch: true),
        AgentCLICommandSpec(name: "mcp-config", arguments: "[claude|codex|json]", summary: "Prints the configuration that adds arch-mcp, by its absolute path, to Claude Code, Codex, or another MCP client.", needsArch: false),
        AgentCLICommandSpec(name: "setup", arguments: "claude|codex", summary: "Shows the command that adds arch-mcp to Claude Code or Codex for your user, asks, and runs it.", needsArch: false),
        AgentCLICommandSpec(name: "links", arguments: "install|remove [--dir folder]", summary: "Links arch-cli and arch-mcp into a writable folder on your PATH inside your home folder, ~/.local/bin first, or removes those links.", needsArch: false),
        AgentCLICommandSpec(name: "skills", arguments: "list|install|remove [--target t] [--path folder]", summary: "Lists, installs, or removes the \(AgentHarness.entrySkillName) skill, which tells an agent how to use Arch, in Claude Code's skill folder (--target claude), Codex's (--target codex or codex-home), or a folder of skill folders (--path). Install and remove change only the places named.", needsArch: false),
        AgentCLICommandSpec(name: "open", arguments: "<url>", summary: "Opens an agent tab in the background at an http or https address, waits for its page, and prints the tab's handle, title, and address.", needsArch: true),
        AgentCLICommandSpec(name: "navigate", arguments: "<tab> <url>", summary: "Loads an address in one of this client's agent tabs and prints its title and address.", needsArch: true),
        AgentCLICommandSpec(name: "back", arguments: "<tab>", summary: "Goes back in an agent tab.", needsArch: true),
        AgentCLICommandSpec(name: "forward", arguments: "<tab>", summary: "Goes forward in an agent tab.", needsArch: true),
        AgentCLICommandSpec(name: "reload", arguments: "<tab>", summary: "Reloads an agent tab.", needsArch: true),
        AgentCLICommandSpec(name: "close", arguments: "<tab>", summary: "Closes one of this client's agent tabs.", needsArch: true),
        AgentCLICommandSpec(name: "snapshot", arguments: "<tab> [--full] [--ref r] [--diff]", summary: "Prints the page as an outline with a ref for each element an action can target, the whole page with --full, one element with --ref, or what changed since the last snapshot with --diff.", needsArch: true),
        AgentCLICommandSpec(name: "screenshot", arguments: "<tab> [--full|--ref r] [-o file]", summary: "Captures the viewport, the full page, or one element as a JPEG image with private fields painted over, and writes it to the file, or to arch-screenshot-<time>.jpg in the current folder.", needsArch: true),
        AgentCLICommandSpec(name: "text", arguments: "<tab> [--offset n]", summary: "Prints a page's readable text, \(AgentLimits.readTextCharactersPerCall.formatted(.number.locale(Locale(identifier: "en_US")))) characters at a time from character n.", needsArch: true),
        AgentCLICommandSpec(name: "click", arguments: "<tab> <ref>", summary: "Clicks an element. A step that needs your approval prints that it waits and goes on once you answer in Arch.", needsArch: true),
        AgentCLICommandSpec(name: "type", arguments: "<tab> <ref> (<text>|--text -) [--replace] [--submit]", summary: "Types text into a field, from standard input with --text -, replacing its text with --replace and pressing Enter after it with --submit.", needsArch: true),
        AgentCLICommandSpec(name: "press", arguments: "<tab> <keys> [--ref r]", summary: "Presses keys, such as Enter or Meta+A, in the focused element or the element r.", needsArch: true),
        AgentCLICommandSpec(name: "select", arguments: "<tab> <ref> <value>...", summary: "Selects options of a select element by value or label.", needsArch: true),
        AgentCLICommandSpec(name: "scroll", arguments: "<tab> (<ref>|up|down|left|right) [--amount n]", summary: "Scrolls an element into view, or the page by n CSS pixels in a direction.", needsArch: true),
        AgentCLICommandSpec(name: "hover", arguments: "<tab> <ref>", summary: "Moves the pointer over an element.", needsArch: true),
        AgentCLICommandSpec(name: "wait", arguments: "<tab> --load|--text t|--url u [--timeout ms]", summary: "Waits until the page loads, shows the text t, or has an address containing u, for at most ms milliseconds, \((AgentLimits.toolWaitSeconds * 1000).formatted(.number.locale(Locale(identifier: "en_US")))) by default.", needsArch: true),
        AgentCLICommandSpec(name: "downloads", arguments: "", summary: "Lists the downloads this client's agent tabs started.", needsArch: true),
        AgentCLICommandSpec(name: "history", arguments: "<query>", summary: "Searches the browsing history for the query's words, when this client's grant includes the history scope.", needsArch: true),
        AgentCLICommandSpec(name: "call", arguments: "<tool> [json]", summary: "Runs any tool, with its arguments as one JSON object.", needsArch: true),
    ]

    /// The options that take a value, and the commands that take each option.
    private static let valueOptions: Set<String> = ["--offset", "--text", "--url", "--timeout", "--ref", "-o", "--amount"]
    private static let optionCommands: [String: Set<String>] = [
        "--shared": ["tabs"], "--offset": ["text"], "--load": ["wait"], "--text": ["type", "wait"], "--url": ["wait"], "--timeout": ["wait"],
        "--full": ["screenshot", "snapshot"], "--ref": ["press", "screenshot", "snapshot"], "--diff": ["snapshot"], "-o": ["screenshot"],
        "--replace": ["type"], "--submit": ["type"], "--amount": ["scroll"],
    ]

    /// Tells `arch-mcp` from `arch-cli` by the name the process was started under, which for the link in `Contents/Helpers` or on PATH is `arch-mcp`, and by an `mcp` first argument.
    public static func invocation(arguments: [String]) -> AgentInvocation {
        let name = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        let rest = Array(arguments.dropFirst())
        if name == AgentBundleLayout.mcpName { return .mcp(rest) }
        if rest.first == "mcp" { return .mcp(Array(rest.dropFirst())) }
        return .cli(rest)
    }

    /// Parses `arch-cli`'s arguments without the program name. `--json`, `--help`, and `-h` may appear anywhere; `help` means `--help`. An option of `optionCommands` belongs to the commands it lists and takes the next argument when it takes a value; `--dir` takes the next argument and belongs to `links`; `--target` and `--path` each take the next argument, may repeat, and belong to `skills`; `--space`, `--mode`, and `--model` each take the next argument and, with `--deny-approvals`, belong to `task`.
    public static func parse(_ arguments: [String]) throws -> AgentCLIRequest {
        var json = false
        var help = false
        var options: [String: String] = [:]
        var folder: String?
        var taskOptions = TaskOptions()
        var places: [AgentSkillInstaller.Place] = []
        var words: [String] = []
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--json": json = true
            case "--help", "-h": help = true
            case "--dir":
                guard let value = remaining.popFirst() else { throw AgentUsageError(message: "--dir needs a folder.") }
                folder = value
            case "--target":
                guard let value = remaining.popFirst() else { throw AgentUsageError(message: "--target needs claude, codex, or codex-home.") }
                guard let target = AgentSkillInstaller.Target(rawValue: value) else { throw AgentUsageError(message: "--target takes claude, codex, or codex-home.") }
                if !places.contains(.target(target)) { places.append(.target(target)) }
            case "--path":
                guard let value = remaining.popFirst() else { throw AgentUsageError(message: "--path needs a folder.") }
                if !places.contains(.path(value)) { places.append(.path(value)) }
            case "--space":
                guard let value = remaining.popFirst() else { throw AgentUsageError(message: "--space needs a space's name.") }
                taskOptions.space = value
            case "--mode":
                guard let value = remaining.popFirst() else { throw AgentUsageError(message: "--mode needs read, ask, or act.") }
                guard let mode = AgentAccessLevel(cliWord: value) else { throw AgentUsageError(message: "--mode takes read, ask, or act.") }
                taskOptions.mode = mode
            case "--model":
                guard let value = remaining.popFirst() else { throw AgentUsageError(message: "--model needs a model's name.") }
                taskOptions.model = value
            case "--deny-approvals": taskOptions.deniesApprovals = true
            case _ where optionCommands[argument] != nil:
                if valueOptions.contains(argument) {
                    guard let value = remaining.popFirst() else { throw AgentUsageError(message: "\(argument) needs a value.") }
                    options[argument] = value
                } else {
                    options[argument] = ""
                }
            case _ where argument.hasPrefix("-") && argument != "-": throw AgentUsageError(message: "Unknown option \(argument).")
            default: words.append(argument)
            }
        }
        if help { return AgentCLIRequest(command: .help, json: json) }
        guard let name = words.first else { throw AgentUsageError(message: "Name a command.") }
        let operands = Array(words.dropFirst())
        for option in options.keys.sorted() {
            guard let commands = optionCommands[option], commands.contains(name) else {
                let takers = optionCommands[option]?.sorted().joined(separator: " and ") ?? ""
                throw AgentUsageError(message: "Only \(takers) takes \(option).")
            }
        }
        let command: AgentCLICommand
        switch name {
        case "help":
            command = .help
        case "status":
            try expectNoOperands(operands, for: name)
            command = .status
        case "tools":
            try expectNoOperands(operands, for: name)
            command = .tools
        case "spaces":
            try expectNoOperands(operands, for: name)
            command = .spaces
        case "tabs":
            try expectNoOperands(operands, for: name)
            command = .tabs(shared: options["--shared"] != nil)
        case "release":
            try expectNoOperands(operands, for: name)
            command = .release
        case "guide":
            guard operands.count <= 1 else { throw AgentUsageError(message: "guide takes at most one topic.") }
            if let topicName = operands.first {
                guard let topic = AgentGuideTopic(rawValue: topicName) else {
                    throw AgentUsageError(message: "There is no guide topic named \(topicName). Topics: \(AgentGuideTopic.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                command = .guide(topic)
            } else {
                command = .guide(nil)
            }
        case "mcp":
            // `invocation(arguments:)` runs `arch-cli mcp` as arch-mcp; here it followed an option.
            throw AgentUsageError(message: "mcp must be the first argument, as in arch-cli mcp.")
        case "mcp-config":
            guard operands.count <= 1 else { throw AgentUsageError(message: "mcp-config takes at most one of claude, codex, or json.") }
            if let formatName = operands.first {
                guard let format = AgentMCPConfigurationFormat(rawValue: formatName) else { throw AgentUsageError(message: "mcp-config takes claude, codex, or json.") }
                command = .mcpConfig(format)
            } else {
                command = .mcpConfig(nil)
            }
        case "setup":
            guard operands.count == 1, let client = AgentMCPSetupClient(rawValue: operands[0]) else { throw AgentUsageError(message: "setup takes claude or codex.") }
            command = .setup(client)
        case "links":
            guard operands.count == 1, let action = AgentLinksAction(rawValue: operands[0]) else { throw AgentUsageError(message: "links takes install or remove.") }
            command = .links(action, folder: folder)
        case "skills":
            guard operands.count == 1, let action = AgentSkillsAction(rawValue: operands[0]) else { throw AgentUsageError(message: "skills takes list, install, or remove.") }
            if action != .list, places.isEmpty {
                throw AgentUsageError(message: "skills \(action.rawValue) needs --target claude, codex, or codex-home, or --path with a folder.")
            }
            command = .skills(action, places: places)
        case "task":
            guard operands.count == 1, let text = operands.first, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentUsageError(message: "task takes the task as one argument, in quotes.")
            }
            command = .task(AgentTaskStart(task: text, space: taskOptions.space, mode: taskOptions.mode, model: taskOptions.model, deniesApprovals: taskOptions.deniesApprovals))
        case "sessions":
            command = .sessions(try sessionsAction(operands))
        case "screenshot":
            var arguments: [String: AgentJSON] = ["tab": .string(try expectOperands(operands, ["tab"], for: name)[0])]
            if options["--full"] != nil, options["--ref"] != nil { throw AgentUsageError(message: "screenshot takes --full or --ref, not both.") }
            arguments["area"] = .string(options["--ref"] ?? (options["--full"] != nil ? "full" : "viewport"))
            command = .screenshot(AgentToolCall(name: "screenshot", arguments: arguments), output: options["-o"])
        case "type" where options["--text"] == "-":
            command = .typeFromStandardInput(try typeCall(operands, options))
        default:
            command = .tool(try toolCall(name, operands, options))
        }
        if case .links = command {} else if folder != nil { throw AgentUsageError(message: "--dir belongs to links.") }
        if case .skills = command {} else if !places.isEmpty { throw AgentUsageError(message: "--target and --path belong to skills.") }
        if case .task = command {} else if taskOptions != TaskOptions() { throw AgentUsageError(message: "--space, --mode, --model, and --deny-approvals belong to task.") }
        return AgentCLIRequest(command: command, json: json)
    }

    /// `task`'s options, gathered wherever they appear.
    private struct TaskOptions: Equatable {
        var space: String?
        var mode: AgentAccessLevel?
        var model: String?
        var deniesApprovals = false
    }

    private static func sessionsAction(_ operands: [String]) throws -> AgentSessionsAction {
        switch operands.first {
        case nil, "list"?:
            guard operands.count <= 1 else { throw AgentUsageError(message: "sessions list takes no arguments.") }
            return .list
        case let verb? where verb == "show" || verb == "stop":
            guard operands.count == 2, let id = UUID(uuidString: operands[1]) else { throw AgentUsageError(message: "sessions \(verb) takes a session's ID, as sessions lists it.") }
            return verb == "show" ? .show(id) : .stop(id)
        default:
            throw AgentUsageError(message: "sessions takes list, show, or stop.")
        }
    }

    /// arch-mcp's mode from its arguments and `ARCH_AGENT_TICKET`: an outside client without arguments, or an in-app session's server with `--session`, which needs the ticket. An outside client ignores a ticket in its environment.
    public static func mcpMode(_ arguments: [String], ticket: String?) throws -> AgentMCPServer.Mode {
        switch arguments {
        case []:
            return .outside
        case ["--session"]:
            guard let ticket, !ticket.isEmpty else {
                throw AgentUsageError(message: "arch-mcp --session needs \(AgentMCPServer.ticketVariable), which Arch sets for the agent sessions it starts.")
            }
            return .session(ticket: ticket)
        default:
            throw AgentUsageError(message: "arch-mcp takes no arguments other than --session.")
        }
    }

    /// `type`'s call: the tab, the ref, and the text from the operands or `--text`, or without the text for `--text -`, which standard input gives.
    private static func typeCall(_ operands: [String], _ options: [String: String]) throws -> AgentToolCall {
        let option = options["--text"]
        guard operands.count == (option == nil ? 3 : 2) else { throw AgentUsageError(message: "type takes <tab> <ref> and the text, or --text - to read it from standard input.") }
        var arguments: [String: AgentJSON] = ["tab": .string(operands[0]), "ref": .string(operands[1])]
        if let text = option == nil ? operands[2] : option, text != "-" || option == nil { arguments["text"] = .string(text) }
        if options["--replace"] != nil { arguments["replace"] = true }
        if options["--submit"] != nil { arguments["submit"] = true }
        return AgentToolCall(name: "type", arguments: arguments)
    }

    /// The tool call of a command that runs one, from its operands and options.
    private static func toolCall(_ name: String, _ operands: [String], _ options: [String: String]) throws -> AgentToolCall {
        switch name {
        case "open":
            let url = try expectOperands(operands, ["url"], for: name)[0]
            return AgentToolCall(name: "open_tab", arguments: ["url": .string(url)])
        case "navigate":
            let given = try expectOperands(operands, ["tab", "url"], for: name)
            return AgentToolCall(name: "navigate", arguments: ["tab": .string(given[0]), "url": .string(given[1])])
        case "back", "forward", "reload":
            let tab = try expectOperands(operands, ["tab"], for: name)[0]
            return AgentToolCall(name: "navigate", arguments: ["tab": .string(tab), "action": .string(name)])
        case "close":
            let tab = try expectOperands(operands, ["tab"], for: name)[0]
            return AgentToolCall(name: "close_tab", arguments: ["tab": .string(tab)])
        case "snapshot":
            var arguments: [String: AgentJSON] = ["tab": .string(try expectOperands(operands, ["tab"], for: name)[0])]
            if options["--full"] != nil { arguments["mode"] = "full" }
            if let ref = options["--ref"] { arguments["ref"] = .string(ref) }
            if options["--diff"] != nil { arguments["diff"] = true }
            return AgentToolCall(name: "snapshot", arguments: arguments)
        case "click", "hover":
            let given = try expectOperands(operands, ["tab", "ref"], for: name)
            return AgentToolCall(name: name, arguments: ["tab": .string(given[0]), "ref": .string(given[1])])
        case "type":
            return try typeCall(operands, options)
        case "press":
            let given = try expectOperands(operands, ["tab", "keys"], for: name)
            var arguments: [String: AgentJSON] = ["tab": .string(given[0]), "keys": .string(given[1])]
            if let ref = options["--ref"] { arguments["ref"] = .string(ref) }
            return AgentToolCall(name: "press", arguments: arguments)
        case "select":
            guard operands.count >= 3 else { throw AgentUsageError(message: "select takes <tab> <ref> and at least one value.") }
            return AgentToolCall(name: "select_option", arguments: ["tab": .string(operands[0]), "ref": .string(operands[1]), "values": .array(operands.dropFirst(2).map(AgentJSON.string))])
        case "scroll":
            let given = try expectOperands(operands, ["tab", "ref or direction"], for: name)
            var arguments: [String: AgentJSON] = ["tab": .string(given[0])]
            if ["up", "down", "left", "right"].contains(given[1]) {
                arguments["direction"] = .string(given[1])
                if let amount = options["--amount"] { arguments["amount"] = .number(Double(try whole(amount, for: "--amount"))) }
            } else {
                if options["--amount"] != nil { throw AgentUsageError(message: "scroll takes --amount only with a direction.") }
                arguments["ref"] = .string(given[1])
            }
            return AgentToolCall(name: "scroll", arguments: arguments)
        case "text":
            var arguments: [String: AgentJSON] = ["tab": .string(try expectOperands(operands, ["tab"], for: name)[0])]
            if let offset = options["--offset"] { arguments["offset"] = .number(Double(try whole(offset, for: "--offset"))) }
            return AgentToolCall(name: "read_text", arguments: arguments)
        case "wait":
            var arguments: [String: AgentJSON] = ["tab": .string(try expectOperands(operands, ["tab"], for: name)[0])]
            let conditions = ["--load", "--text", "--url"].filter { options[$0] != nil }
            guard conditions.count == 1 else { throw AgentUsageError(message: "wait takes one of --load, --text, or --url.") }
            if options["--load"] != nil { arguments["load"] = true }
            if let text = options["--text"] { arguments["text"] = .string(text) }
            if let url = options["--url"] { arguments["url"] = .string(url) }
            if let timeout = options["--timeout"] { arguments["timeout_ms"] = .number(Double(try whole(timeout, for: "--timeout"))) }
            return AgentToolCall(name: "wait_for", arguments: arguments)
        case "downloads":
            try expectNoOperands(operands, for: name)
            return AgentToolCall(name: "list_downloads")
        case "history":
            guard !operands.isEmpty else { throw AgentUsageError(message: "history needs a query.") }
            return AgentToolCall(name: "search_history", arguments: ["query": .string(operands.joined(separator: " "))])
        case "call":
            guard let tool = operands.first, operands.count <= 2 else { throw AgentUsageError(message: "call takes a tool's name and at most one JSON object.") }
            guard let text = operands.dropFirst().first else { return AgentToolCall(name: tool) }
            guard let arguments = (try? AgentJSON.decode(Data(text.utf8)))?.objectValue else { throw AgentUsageError(message: "call's arguments must be one JSON object, such as '{\"tab\": \"t1\"}'.") }
            return AgentToolCall(name: tool, arguments: arguments)
        default:
            throw AgentUsageError(message: "Unknown command \(name).")
        }
    }

    /// The operands of a command that takes exactly these, by name.
    private static func expectOperands(_ operands: [String], _ names: [String], for name: String) throws -> [String] {
        guard operands.count == names.count else { throw AgentUsageError(message: "\(name) takes \(names.map { "<\($0)>" }.joined(separator: " ")).") }
        return operands
    }

    private static func whole(_ text: String, for option: String) throws -> Int {
        guard let value = Int(text), value >= 0 else { throw AgentUsageError(message: "\(option) takes a whole number.") }
        return value
    }

    private static func expectNoOperands(_ operands: [String], for name: String) throws {
        if !operands.isEmpty { throw AgentUsageError(message: "\(name) takes no arguments.") }
    }
}
