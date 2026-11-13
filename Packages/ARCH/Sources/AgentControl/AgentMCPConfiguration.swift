// The configuration that adds arch-mcp to an MCP client, for `arch-cli mcp-config` and `setup` and for Settings ▸ AI ▸ Agents (docs/agents.md, arch-cli). Each names arch-mcp by its absolute path. Arch never edits another tool's configuration files: `setup` runs the tool's own command after the user agrees.
import Foundation

/// A configuration `mcp-config` prints.
public enum AgentMCPConfigurationFormat: String, CaseIterable, Sendable {
    /// The command that adds the server to Claude Code for the user.
    case claude
    /// Codex's table for its `config.toml`.
    case codex
    /// The `mcpServers` JSON that other MCP clients read.
    case json

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex, in config.toml"
        case .json: return "Other MCP clients"
        }
    }
}

/// A tool that `setup` adds the server to through the tool's own command.
public enum AgentMCPSetupClient: String, CaseIterable, Sendable {
    case claude
    case codex

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

public enum AgentMCPConfiguration {
    /// Codex's tool timeout in the printed table, above the 45 seconds within which every call answers.
    public static let codexToolTimeoutSeconds = 120

    /// The command `setup` shows and runs, program first.
    public static func setupArguments(for client: AgentMCPSetupClient, mcpPath: String) -> [String] {
        switch client {
        case .claude: return ["claude", "mcp", "add", "--scope", "user", AgentMCPServer.serverName, "--", mcpPath]
        case .codex: return ["codex", "mcp", "add", AgentMCPServer.serverName, "--", mcpPath]
        }
    }

    public static func text(_ format: AgentMCPConfigurationFormat, mcpPath: String) -> String {
        switch format {
        case .claude:
            return shellCommand(setupArguments(for: .claude, mcpPath: mcpPath))
        case .codex:
            return """
                [mcp_servers.\(AgentMCPServer.serverName)]
                command = \(tomlString(mcpPath))
                tool_timeout_sec = \(codexToolTimeoutSeconds)
                """
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let configuration: AgentJSON = ["mcpServers": [AgentMCPServer.serverName: ["command": .string(mcpPath)]]]
            // An `AgentJSON` value always encodes.
            return String(decoding: (try? encoder.encode(configuration)) ?? Data(), as: UTF8.self)
        }
    }

    /// The words as one command line for a POSIX shell.
    public static func shellCommand(_ words: [String]) -> String {
        words.map(shellQuoted).joined(separator: " ")
    }

    /// A word as is when the shell reads it so, otherwise in single quotes.
    static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A TOML basic string.
    static func tomlString(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"" + escaped + "\""
    }
}
