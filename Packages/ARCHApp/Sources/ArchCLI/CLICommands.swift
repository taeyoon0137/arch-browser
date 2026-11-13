// The commands `arch-cli` answers: `status`, `guide`, `tools`, `spaces`, `tabs`, `release`, `--help`, and the setup commands `mcp-config`, `setup`, and `links` (docs/agents.md, arch-cli). Text goes to standard output, and an error to standard error as one sentence, with the exit code from `AgentExitCode`. A tool command prints the result's text, or its structured value with `--json`, and exits with its status's code.
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
        case .mcpConfig(let format):
            return mcpConfig(format)
        case .setup(let client):
            return setup(client)
        case .links(let action, let folder):
            return links(action, folder: folder)
        }
    }

    /// The version of the bundle around this executable, as `hello` and arch-mcp's `serverInfo` report it.
    static var clientVersion: String {
        bundleLayout?.version ?? "unknown"
    }

    /// The app bundle around this executable, or nil outside one, as for `.build/debug/arch-cli`.
    private static var bundleLayout: AgentBundleLayout? {
        AgentBundleLayout.currentExecutable().flatMap(AgentBundleLayout.containing(helper:))
    }

    /// One sentence on standard error, after what standard output holds so far, so that the two keep their order in a pipe.
    static func printError(_ message: String) {
        fflush(stdout)
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

    /// Connects, checks that the socket is Arch's, says `hello`, and runs `body` on the connection with Arch's answer. Client errors print their sentence and exit with their code.
    private static func withConnection(_ body: (AgentControlConnection, AgentHelloAnswer) throws -> AgentExitCode) -> AgentExitCode {
        do {
            guard let location = AgentSocketLocation.forClient() else { throw AgentClientError.noSocketLocation }
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

    // MARK: - mcp-config, setup, links

    /// The bundle whose `arch-mcp` the configuration names; outside a bundle there is none, which exits 77 as the client checks do.
    private static func requireBundle() -> AgentBundleLayout? {
        guard let layout = bundleLayout else {
            printError("This arch-cli does not run from inside an Arch bundle. Use Arch.app/Contents/Helpers/arch-cli.")
            return nil
        }
        return layout
    }

    private static func mcpConfig(_ format: AgentMCPConfigurationFormat?) -> AgentExitCode {
        guard let layout = requireBundle() else { return .notArch }
        let path = layout.mcpExecutableURL.path
        if let format {
            print(AgentMCPConfiguration.text(format, mcpPath: path))
        } else {
            print(AgentMCPConfigurationFormat.allCases.map { "\($0.title):\n\(AgentMCPConfiguration.text($0, mcpPath: path))" }.joined(separator: "\n\n"))
        }
        return .done
    }

    /// Shows the tool's own command, asks, and runs it with this process's terminal, so that the tool writes its own configuration.
    private static func setup(_ client: AgentMCPSetupClient) -> AgentExitCode {
        guard let layout = requireBundle() else { return .notArch }
        let arguments = AgentMCPConfiguration.setupArguments(for: client, mcpPath: layout.mcpExecutableURL.path)
        print("This adds Arch's MCP server to \(client.title) for your user with:\n  \(AgentMCPConfiguration.shellCommand(arguments))")
        guard let executable = locate(arguments[0]) else {
            printError("\(arguments[0]) is not on your PATH. Install \(client.title), or run the command above once it is installed.")
            return .toolError
        }
        print("Run it? [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine(), ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased()) else {
            print("Nothing was changed.")
            return .denied
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = Array(arguments.dropFirst())
        do {
            try process.run()
        } catch {
            printError("\(executable.path) could not be started: \(error.localizedDescription)")
            return .toolError
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            printError("\(arguments[0]) mcp add ended with status \(process.terminationStatus).")
            return .toolError
        }
        print("\(client.title) now starts arch-mcp when it uses Arch's tools.")
        return .done
    }

    /// The first executable of that name in PATH's folders.
    private static func locate(_ name: String) -> URL? {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func links(_ action: AgentLinksAction, folder name: String?) -> AgentExitCode {
        guard let home = AgentLinkInstaller.userHomeFolder else {
            printError("The home folder could not be read.")
            return .internalError
        }
        let installer = AgentLinkInstaller(homeFolder: home, searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "")
        do {
            switch action {
            case .install:
                guard let layout = requireBundle() else { return .notArch }
                let folder = try installer.installFolder(named: name)
                let links = AgentLinkInstaller.links(in: folder, for: layout)
                print("arch-cli and arch-mcp are in \(layout.helpersURL.path).")
                print("Linking them into \(folder.path):")
                for link in links { print("  \(link.location.path) -> \(link.destination.path)") }
                try installer.install(links)
                if !installer.isOnSearchPath(folder) { print("\(folder.path) is not on your PATH; add it to run arch-cli by name.") }
            case .remove:
                let removed = try installer.remove(from: installer.removalFolders(named: name))
                if removed.isEmpty { print("No links to Arch's tools were found.") }
                for location in removed { print("Removed \(location.path).") }
            }
            return .done
        } catch let failure as AgentLinkInstaller.Failure {
            printError(failure.message)
            return failure.exitCode
        } catch {
            printError("\(error)")
            return .internalError
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
