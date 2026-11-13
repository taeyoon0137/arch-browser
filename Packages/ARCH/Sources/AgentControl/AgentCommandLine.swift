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
}

public struct AgentCLIRequest: Equatable, Sendable {
    public var command: AgentCLICommand
    /// `--json`: print the result's structured value instead of text. `guide` and `--help` print text either way.
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
    ]

    /// Tells `arch-mcp` from `arch-cli` by the name the process was started under, which for the link in `Contents/Helpers` or on PATH is `arch-mcp`, and by an `mcp` first argument.
    public static func invocation(arguments: [String]) -> AgentInvocation {
        let name = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        let rest = Array(arguments.dropFirst())
        if name == AgentBundleLayout.mcpName { return .mcp(rest) }
        if rest.first == "mcp" { return .mcp(Array(rest.dropFirst())) }
        return .cli(rest)
    }

    /// Parses `arch-cli`'s arguments, without the program name. `--json`, `--help`, and `-h` may come anywhere; `help` is `--help`.
    public static func parse(_ arguments: [String]) throws -> AgentCLIRequest {
        var json = false
        var help = false
        var shared = false
        var words: [String] = []
        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "--help", "-h": help = true
            case "--shared": shared = true
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
        default:
            throw AgentUsageError(message: "Unknown command \(name).")
        }
        return AgentCLIRequest(command: command, json: json)
    }

    private static func expectNoOperands(_ operands: [String], for name: String) throws {
        if !operands.isEmpty { throw AgentUsageError(message: "\(name) takes no arguments.") }
    }
}
