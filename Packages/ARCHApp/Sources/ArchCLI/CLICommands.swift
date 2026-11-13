// The commands `arch-cli` answers: `status`, `guide`, `tools`, `spaces`, `tabs`, `release`, and `--help` (docs/agents.md, arch-cli). Text goes to standard output, and an error to standard error as one sentence, with the exit code from `AgentExitCode`. A tool command prints the result's text, or its structured value with `--json`, and exits with its status's code.
import AgentControl
import Foundation

enum CLICommands {
    static func run(_ arguments: [String]) -> AgentExitCode {
        let request: AgentCLIRequest
        do {
            request = try AgentCommandLine.parse(arguments)
        } catch {
            let message = (error as? AgentUsageError)?.message ?? "\(error)"
            printError("arch-cli: \(message) Run arch-cli --help for the commands.")
            return .usage
        }
        switch request.command {
        case .help:
            print(AgentGuideTopic.cli.text)
            return .done
        case .guide(let topic):
            print(AgentHarness.text(for: topic))
            return .done
        case .tools:
            if request.json { return printJSON(AgentToolCatalog.mcpToolList) }
            print(toolsText())
            return .done
        case .status:
            return status(json: request.json)
        case .spaces:
            return runTool(AgentToolCall(name: "list_spaces"), json: request.json)
        case .tabs(let shared):
            return runTool(AgentToolCall(name: "list_tabs", arguments: shared ? ["scope": "shared"] : [:]), json: request.json)
        case .release:
            return release(json: request.json)
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printJSON(_ value: AgentJSON) -> AgentExitCode {
        do {
            print(String(decoding: try value.encoded(), as: UTF8.self))
            return .done
        } catch {
            printError("The result could not be written as JSON: \(error)")
            return .internalError
        }
    }

    // MARK: - Connecting

    private static var clientVersion: String {
        AgentBundleLayout.currentExecutable().flatMap(AgentBundleLayout.containing(helper:))?.version ?? "unknown"
    }

    /// Connects, checks that the socket is Arch's, says `hello`, and runs `body` on the connection with Arch's answer. Client errors print their sentence and exit with their code.
    private static func withConnection(_ body: (AgentControlConnection, AgentHelloAnswer) throws -> AgentExitCode) -> AgentExitCode {
        do {
            guard let location = AgentSocketLocation.current() else { throw AgentClientError.noSocketLocation }
            let connection = try AgentControlConnection(location: location, check: AgentControlConnection.archCheck())
            let answer = try connection.hello(AgentHello(client: .cli, version: clientVersion))
            return try body(connection, answer)
        } catch let error as AgentClientError {
            printError(error.message)
            return error.exitCode
        } catch {
            printError("\(error)")
            return .internalError
        }
    }

    // MARK: - status

    /// Connects, checks that the socket is Arch's, and reports Arch's answer to `hello`.
    private static func status(json: Bool) -> AgentExitCode {
        withConnection { _, answer in
            if json { return printJSON(try AgentJSON(encoding: answer)) }
            print(statusText(answer, clientVersion: clientVersion))
            return .done
        }
    }

    // MARK: - Tools

    /// Calls one tool. The first call of a client without a grant waits while Arch asks the user, and says so on standard error.
    private static func runTool(_ call: AgentToolCall, json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            let result = try connection.callTool(call) { printError($0) }
            if json {
                if printJSON(result.structured ?? .null) != .done { return .internalError }
            } else if result.status == .ok {
                print(result.text)
            } else {
                printError(result.text)
            }
            return AgentExitCode(status: result.status)
        }
    }

    /// Gives up this client's grant.
    private static func release(json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            let released = try connection.call(AgentControlMethod.grantRelease)["released"] == .bool(true)
            if json { return printJSON(["released": .bool(released)]) }
            print(released ? "This client no longer has access to Arch. Its next command asks again." : "This client had no access to give up.")
            return .done
        }
    }

    private static func statusText(_ answer: AgentHelloAnswer, clientVersion: String) -> String {
        let access: String
        switch answer.status {
        case .bound:
            access = "This connection belongs to an agent session in Arch."
        case .granted(let grant):
            access = "Grant: \(grant.level.title) in the \(grant.persona) Persona, \(expiryText(grant.expiry))."
        case .noGrant:
            access = "Grant: none yet. The first tool call asks in Arch."
        case .refused(let refusal):
            access = refusal.message
        }
        return """
            Arch \(answer.version) is running, and agent access is on.
            This arch-cli: \(clientVersion), control protocol \(AgentControlProtocol.version).
            \(access)
            """
    }

    private static func expiryText(_ expiry: AgentGrantExpiry) -> String {
        switch expiry {
        case .whenArchQuits: return "until Arch quits"
        case .whenRevoked: return "until you revoke it"
        case .at(let date): return "until \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    // MARK: - tools

    /// Each tool with its class and description, then its parameters with their types.
    private static func toolsText() -> String {
        AgentToolCatalog.tools.map { tool in
            var lines = ["\(tool.name) (\(tool.toolClass.title))", "  \(tool.description)"]
            let width = (tool.parameters.map(\.name.count).max() ?? 0) + 2
            for parameter in tool.parameters {
                let name = parameter.name.padding(toLength: width, withPad: " ", startingAt: 0)
                let required = parameter.isRequired ? ", required" : ""
                lines.append("    \(name)\(parameter.typeName)\(required). \(parameter.description)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
