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
        AgentCLICommandSpec(name: "mcp", arguments: "[--session]", summary: "Runs as arch-mcp, the MCP server on standard input and output. Arch starts it with --session for its own agent sessions.", needsArch: true),
        AgentCLICommandSpec(name: "mcp-config", arguments: "[claude|codex|json]", summary: "Prints the configuration that adds arch-mcp, by its absolute path, to Claude Code, Codex, or another MCP client.", needsArch: false),
        AgentCLICommandSpec(name: "setup", arguments: "claude|codex", summary: "Shows the command that adds arch-mcp to Claude Code or Codex for your user, asks, and runs it.", needsArch: false),
        AgentCLICommandSpec(name: "links", arguments: "install|remove [--dir folder]", summary: "Links arch-cli and arch-mcp into a writable folder on your PATH inside your home folder, ~/.local/bin first, or removes those links.", needsArch: false),
        AgentCLICommandSpec(name: "skills", arguments: "list|install|remove [--target t] [--path folder]", summary: "Lists, installs, or removes the \(AgentHarness.entrySkillName) skill, which tells an agent how to use Arch, in Claude Code's skill folder (--target claude), Codex's (--target codex or codex-home), or a folder of skill folders (--path). Install and remove change only the places named.", needsArch: false),
    ]

    /// Tells `arch-mcp` from `arch-cli` by the name the process was started under, which for the link in `Contents/Helpers` or on PATH is `arch-mcp`, and by an `mcp` first argument.
    public static func invocation(arguments: [String]) -> AgentInvocation {
        let name = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        let rest = Array(arguments.dropFirst())
        if name == AgentBundleLayout.mcpName { return .mcp(rest) }
        if rest.first == "mcp" { return .mcp(Array(rest.dropFirst())) }
        return .cli(rest)
    }

    /// Parses `arch-cli`'s arguments without the program name. `--json`, `--help`, and `-h` may appear anywhere; `help` means `--help`. `--shared` belongs to `tabs`; `--dir` takes the next argument and belongs to `links`; `--target` and `--path` each take the next argument, may repeat, and belong to `skills`.
    public static func parse(_ arguments: [String]) throws -> AgentCLIRequest {
        var json = false
        var help = false
        var shared = false
        var folder: String?
        var places: [AgentSkillInstaller.Place] = []
        var words: [String] = []
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--json": json = true
            case "--help", "-h": help = true
            case "--shared": shared = true
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
            case _ where argument.hasPrefix("-") && argument != "-": throw AgentUsageError(message: "Unknown option \(argument).")
            default: words.append(argument)
            }
        }
        if help { return AgentCLIRequest(command: .help, json: json) }
        guard let name = words.first else { throw AgentUsageError(message: "Name a command.") }
        let operands = Array(words.dropFirst())
        if shared, name != "tabs" { throw AgentUsageError(message: "Only tabs takes --shared.") }
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
            command = .tabs(shared: shared)
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
        default:
            throw AgentUsageError(message: "Unknown command \(name).")
        }
        if case .links = command {} else if folder != nil { throw AgentUsageError(message: "--dir belongs to links.") }
        if case .skills = command {} else if !places.isEmpty { throw AgentUsageError(message: "--target and --path belong to skills.") }
        return AgentCLIRequest(command: command, json: json)
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

    private static func expectNoOperands(_ operands: [String], for name: String) throws {
        if !operands.isEmpty { throw AgentUsageError(message: "\(name) takes no arguments.") }
    }
}
