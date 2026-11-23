// Handles `arch-cli` commands (`docs/agents.md`, arch-cli).
// Commands include `status`, `guide`, `tools`, `spaces`, `tabs`, `release`, `task`, `sessions`, `events`, `hooks`, `agent run`, `rename`, and `--help`.
// Tool commands are `open`, `navigate`, `back`, `forward`, `reload`, `close`, `snapshot`, `screenshot`, `text`, `click`, `type`, `press`, `select`, `scroll`, `hover`, `wait`, `downloads`, `history`, and `call`.
// Setup commands are `mcp-config`, `setup`, `links`, and `skills`.
// Text goes to standard output. Errors go to standard error as one sentence, with an `AgentExitCode` exit code.
// A tool command prints result text or a structured value with `--json`, then exits with its status code.
// A step waiting for approval reports it on standard error and calls `approval_wait` until Arch answers.
// `type --text -` reads standard input. `screenshot` writes its image only to a file.
import AgentControl
import Foundation

/// Parses and runs an `arch-cli` command, and returns its exit code.
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
        case .skills(let action, let places):
            return skills(action, places: places)
        case .task(let start):
            return task(start, json: request.json)
        case .sessions(let action):
            return sessions(action, json: request.json)
        case .tool(let call):
            return runTool(call, json: request.json)
        case .typeFromStandardInput(var call):
            let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            // A trailing line break ends the input, as `echo` and here documents add one.
            call.arguments["text"] = .string(input.hasSuffix("\n") ? String(input.dropLast()) : input)
            return runTool(call, json: request.json)
        case .screenshot(let call, let output):
            return screenshot(call, output: output, json: request.json)
        case .events(let subscribe):
            return events(subscribe, json: request.json)
        case .hooks(let action):
            return hooks(action, json: request.json)
        case .agentRun(var options, let fromStandardInput):
            if fromStandardInput {
                let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                if case .object(var fields) = options {
                    fields["prompt"] = .string(input.hasSuffix("\n") ? String(input.dropLast()) : input)
                    options = .object(fields)
                }
            }
            return agentRun(options, json: request.json)
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

    /// Text from a page or a model without the controls a terminal acts on: C0 and C1 controls other than a line feed and a tab, and the bidirectional overrides and isolates. JSON output escapes them itself.
    static func terminalSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x0A, 0x09: return true
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: return false
            default: return true
            }
        }))
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

    /// Connects, checks that the socket is Arch's, says `hello`, and runs `body` on the connection with Arch's answer. Inside a shell hook's run, `hello` presents the run's ticket from `ARCH_HOOK_TICKET`, which binds the connection to the run or is refused, never falling back to a grant. Client errors print their sentence and exit with their code.
    private static func withConnection(_ body: (AgentControlConnection, AgentHelloAnswer) throws -> AgentExitCode) -> AgentExitCode {
        do {
            guard let location = AgentSocketLocation.forClient() else { throw AgentClientError.noSocketLocation }
            let connection = try AgentControlConnection(location: location, check: AgentControlConnection.archCheck())
            let ticket = ProcessInfo.processInfo.environment[AgentControlProtocol.hookTicketVariable].flatMap { $0.isEmpty ? nil : $0 }
            let answer = try connection.hello(AgentHello(client: .cli, version: clientVersion, ticket: ticket))
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

    /// Calls one tool, and keeps waiting through `approval_wait` while the step waits for the user. The first call of a client without a grant waits while Arch asks the user, and says so on standard error.
    private static func callWaiting(_ call: AgentToolCall, on connection: AgentControlConnection) throws -> AgentToolResult {
        var result = try connection.callTool(call) { printError($0) }
        var told = false
        while result.status == .approvalPending, let approval = result.approval {
            if !told { printError("Waiting for your approval in Arch\u{2026}") }
            told = true
            result = try connection.callTool(AgentToolCall(name: "approval_wait", arguments: ["approval": .string(approval)])) { printError($0) }
        }
        return result
    }

    /// Calls one tool. The first call of a client without a grant waits while Arch asks the user, and says so on standard error.
    private static func runTool(_ call: AgentToolCall, json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            let result = try callWaiting(call, on: connection)
            if json {
                if printJSON(result.structured ?? .null) != .done { return .internalError }
                if result.status != .ok { printError(terminalSafe(result.text)) }
            } else if result.status == .ok {
                print(terminalSafe(result.text))
            } else {
                printError(terminalSafe(result.text))
            }
            return AgentExitCode(status: result.status)
        }
    }

    /// Takes a screenshot and writes its image to `output`, or to `arch-screenshot-<time>.jpg` in the current folder, never to standard output, then prints the result's text or structured value with the file's path.
    private static func screenshot(_ call: AgentToolCall, output: String?, json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            let result = try callWaiting(call, on: connection)
            guard result.status == .ok, let image = result.content.lazy.compactMap(\.imageData).first else {
                if json { _ = printJSON(result.structured ?? .null) }
                if !json || result.status != .ok { printError(terminalSafe(result.text)) }
                return result.status == .ok ? .internalError : AgentExitCode(status: result.status)
            }
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime]).replacingOccurrences(of: ":", with: "")
            let file = URL(fileURLWithPath: output ?? "arch-screenshot-\(stamp).jpg")
            do {
                try image.write(to: file, options: output == nil ? .withoutOverwriting : .atomic)
            } catch {
                printError("The screenshot could not be written to \(file.path): \(error.localizedDescription)")
                return .internalError
            }
            if json {
                var structured = result.structured?.objectValue ?? [:]
                structured["file"] = .string(file.path)
                return printJSON(.object(structured))
            }
            print("\(terminalSafe(result.text))\nWrote \(file.path).")
            return .done
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

    // MARK: - events

    /// Subscribes to the grant's browser events and prints each as it arrives, one line each, or one JSON object per line in the outside view with `--json`, until interrupted. Events Arch dropped because this client read too slowly are counted on standard error. A grant without Watch Browser Events exits 6, and a filter Arch refuses, such as a space it does not know, exits 4.
    private static func events(_ subscribe: AgentEventSubscribe, json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            let subscription: AgentEventSubscription
            do {
                subscription = try connection.call(AgentControlMethod.eventsSubscribe, params: AgentJSON(encoding: subscribe)) { printError($0) }.decode(as: AgentEventSubscription.self)
            } catch AgentClientError.failed(let error) {
                printError(error.message)
                return .refused
            }
            if !json { printError("Following browser events in Arch after event \(subscription.sequence). Press Control-C to stop.") }
            let id = AgentJSON.number(Double(subscription.subscription))
            while true {
                switch try connection.receive() {
                case .notification(AgentControlMethod.eventNotification, let params):
                    guard params?["subscription"] == id, let event = params?["event"] else { continue }
                    if json {
                        if printJSON(event) != .done { return .internalError }
                    } else {
                        print(terminalSafe(AgentEventLine.text(for: event)))
                    }
                    fflush(stdout)
                case .notification(AgentControlMethod.eventsDroppedNotification, let params):
                    guard params?["subscription"] == id, case .number(let count)? = params?["count"] else { continue }
                    printError("Arch dropped \(Int(count)) events that this client did not read in time.")
                case .notification(AgentControlMethod.revokedNotification, let params):
                    throw AgentClientError.revoked(params?["message"]?.stringValue ?? "Your access to Arch ended.")
                default:
                    continue
                }
            }
        }
    }

    // MARK: - hooks

    /// Lists the hooks this client added, proposes one, or removes one. `add` reads the script and the agent options, which must be a JSON object, sends the proposal, says on standard error that it waits for the user, and prints the new hook's ID on Allow; Don't Allow exits 3 and a refusal, by Arch or of a script over 256 KB, exits 4.
    private static func hooks(_ action: AgentHooksAction, json: Bool) -> AgentExitCode {
        var proposal: AgentHookAdd?
        if case .add(var add, let scriptPath, let agentPath) = action {
            guard let script = FileManager.default.contents(atPath: scriptPath) else {
                printError("arch-cli could not read the script at \(scriptPath).")
                return .usage
            }
            guard script.count <= AgentHookAdd.scriptBytes, let text = String(data: script, encoding: .utf8) else {
                printError("A hook's script is UTF-8 text of at most 256 KB.")
                return .refused
            }
            add.script = text
            if let agentPath {
                guard let data = FileManager.default.contents(atPath: agentPath) else {
                    printError("arch-cli could not read the agent options at \(agentPath).")
                    return .usage
                }
                guard let options = try? AgentJSON.decode(data), options.objectValue != nil else {
                    printError("The agent options must be one JSON object, as arch.agent.run takes them.")
                    return .refused
                }
                add.agent = options
            }
            proposal = add
        }
        return withConnection { connection, _ in
            do {
                switch action {
                case .list:
                    let listing = try connection.call(AgentControlMethod.hooksList) { printError($0) }.decode(as: AgentHookListing.self)
                    if json { return printJSON(try AgentJSON(encoding: listing)) }
                    if listing.hooks.isEmpty { print("This client has added no hooks.") }
                    for hook in listing.hooks {
                        print("\(hook.id.uuidString)  \(terminalSafe(hook.name))\n  \(hook.trigger) \u{00B7} \(hook.state)\(hook.lastRun.map { " \u{00B7} last run \($0)" } ?? "")")
                    }
                    return .done
                case .remove(let id):
                    let removed = try connection.call(AgentControlMethod.hooksRemove, params: ["hook": .string(id.uuidString)])["removed"] == .bool(true)
                    if json { return printJSON(["removed": .bool(removed)]) }
                    print(removed ? "Removed the hook." : "This client added no hook with that ID.")
                    return removed ? .done : .toolError
                case .add:
                    let result = try connection.call(AgentControlMethod.hooksAdd, params: AgentJSON(encoding: proposal)) { printError($0) }.decode(as: AgentHookAddResult.self)
                    if json {
                        if printJSON(try AgentJSON(encoding: result)) != .done { return .internalError }
                    } else if let hook = result.hook {
                        print(hook.uuidString)
                    }
                    if !json, let message = result.message { printError(message) }
                    switch result.status {
                    case .added: return .done
                    case .declined: return .denied
                    case .refused: return .refused
                    }
                }
            } catch AgentClientError.failed(let error) {
                printError(error.message)
                return .refused
            }
        }
    }

    // MARK: - agent run

    /// Runs one agent in Arch and prints the result's sentence and the agent's reply, or the result as JSON with `--json`. It exits 0 when the run completed, 1 when it failed or was cancelled, 4 when a rule refused it, as for a grant without Start Agent Tasks' runs left, and 5 when it ran out of time.
    private static func agentRun(_ options: AgentJSON, json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            let result: AgentJSON
            do {
                result = try connection.call(AgentControlMethod.agentRun, params: options) { printError($0) }
            } catch AgentClientError.failed(let error) {
                printError(error.message)
                return .refused
            }
            let status = result["status"]?.stringValue ?? "failed"
            if json {
                if printJSON(result) != .done { return .internalError }
            } else {
                let sentences = ["completed": "The agent run completed.", "failed": "The agent run failed.", "timedOut": "The agent run ran out of time.",
                                 "cancelled": "The agent run was cancelled.", "refused": "Arch refused the agent run."]
                var line = sentences[status] ?? "The agent run ended."
                if let message = result["message"]?.stringValue { line += " " + message }
                if let code = result["code"]?.stringValue, result["message"] == nil { line += " (\(code))" }
                printError(terminalSafe(line))
                if let reply = result["reply"]?.stringValue { print(terminalSafe(reply)) }
            }
            switch status {
            case "completed": return .done
            case "refused": return .refused
            case "timedOut": return .timedOut
            default: return .toolError
            }
        }
    }

    // MARK: - task and sessions

    /// Starts a session in Arch and prints its progress: the agent's reply as it streams, each step Arch performs on its own line, and notices on standard error, until the turn ends. With `--json`, the session's summary and then each event as one JSON object per line. A refusal, such as a grant without Start Agent Tasks, exits 6, and a space or model Arch does not know exits 4.
    private static func task(_ start: AgentTaskStart, json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            let summary: AgentSessionSummary
            do {
                summary = try connection.call(AgentControlMethod.taskStart, params: AgentJSON(encoding: start)) { printError($0) }.decode(as: AgentSessionSummary.self)
            } catch AgentClientError.failed(let error) {
                printError(error.message)
                return .refused
            }
            if json {
                if printJSON(try AgentJSON(encoding: summary)) != .done { return .internalError }
            } else {
                printError("Session \(summary.id.uuidString) in \(summary.place), \(summary.mode.title). Approvals happen in Arch.")
            }
            var atLineStart = true
            while true {
                guard case .notification(AgentControlMethod.taskEventNotification, let params) = try connection.receive(),
                      let event = try? params?.decode(as: AgentTaskEvent.self), event.session == summary.id else { continue }
                if json {
                    if printJSON(try AgentJSON(encoding: event)) != .done { return .internalError }
                } else {
                    switch event.kind {
                    case .text:
                        print(terminalSafe(event.text), terminator: "")
                        fflush(stdout)
                        atLineStart = event.text.hasSuffix("\n")
                    case .step:
                        print((atLineStart ? "" : "\n") + "[Arch] \(terminalSafe(event.text))")
                        atLineStart = true
                    case .notice:
                        printError(terminalSafe(event.text))
                    case .turnFinished, .failed:
                        if !atLineStart { print("") }
                    }
                }
                switch event.kind {
                case .turnFinished: return .done
                case .failed:
                    if !json { printError(terminalSafe(event.text)) }
                    return .toolError
                case .text, .step, .notice: continue
                }
            }
        }
    }

    /// Lists the sessions this client started, shows one, or stops one's turn.
    private static func sessions(_ action: AgentSessionsAction, json: Bool) -> AgentExitCode {
        withConnection { connection, _ in
            do {
                switch action {
                case .list, .show:
                    var params: AgentJSON?
                    if case .show(let id) = action { params = try AgentJSON(encoding: AgentSessionReference(session: id)) }
                    let list = try connection.call(AgentControlMethod.sessionsList, params: params).decode(as: AgentSessionList.self)
                    if json { return printJSON(try AgentJSON(encoding: list)) }
                    if list.sessions.isEmpty { print("This client has started no agent sessions.") }
                    for session in list.sessions {
                        print("\(session.id.uuidString)  \(session.title)\n  \(session.state) \u{00B7} \(session.mode.title) \u{00B7} \(session.place)\(session.model.map { " \u{00B7} \($0)" } ?? "")")
                    }
                case .stop(let id):
                    let stopped = try connection.call(AgentControlMethod.taskStop, params: AgentJSON(encoding: AgentSessionReference(session: id)))["stopped"] == .bool(true)
                    if json { return printJSON(["stopped": .bool(stopped)]) }
                    print(stopped ? "The session's turn stopped." : "The session had no turn running.")
                }
                return .done
            } catch AgentClientError.failed(let error) {
                printError(error.message)
                return .toolError
            }
        }
    }

    private static func statusText(_ answer: AgentHelloAnswer, clientVersion: String) -> String {
        let access: String
        switch answer.status {
        case .bound:
            access = "This connection belongs to an agent session or a hook's run in Arch."
        case .granted(let grant):
            // A Persona's place reads as "Persona / Space".
            access = "Grant: \(grant.level.title) in \(grant.space.map { "\(grant.persona) / \($0)" } ?? "the \(grant.persona) Persona"), \(expiryText(grant.expiry))."
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
            if client == .claude {
                let remove = AgentMCPConfiguration.shellCommand(["claude", "mcp", "remove", "--scope", "user", AgentMCPServer.serverName])
                printError("If Claude Code already has an arch server, as after Arch moved, run \(remove), then arch-cli setup claude again.")
            }
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

    // MARK: - skills

    /// Lists, writes, or removes the entry skill. `list` and `install` need the bundle because the skill names its `arch-cli` by absolute path; `remove` works anywhere.
    private static func skills(_ action: AgentSkillsAction, places: [AgentSkillInstaller.Place]) -> AgentExitCode {
        guard let home = AgentLinkInstaller.userHomeFolder else {
            printError("The home folder could not be read.")
            return .internalError
        }
        let installer = AgentSkillInstaller(accountHomeFolder: home, environment: ProcessInfo.processInfo.environment)
        do {
            switch action {
            case .list:
                guard let layout = requireBundle() else { return .notArch }
                let skill = AgentHarness.entrySkill(cliPath: layout.cliExecutableURL.path)
                for place in places.isEmpty ? AgentSkillInstaller.Target.allCases.map(AgentSkillInstaller.Place.target) : places {
                    let destination = try installer.destination(for: place, skillName: skill.name)
                    print("\(place.title): \(destination.folder.path)\n  \(stateText(installer.state(of: destination, skill: skill), place: place))")
                }
                return .done
            case .install:
                guard let layout = requireBundle() else { return .notArch }
                let skill = AgentHarness.entrySkill(cliPath: layout.cliExecutableURL.path)
                let destinations = try places.map { try installer.destination(for: $0, skillName: skill.name) }
                // Refuses before listing paths to write, since nothing will be written.
                try installer.checkReplaceable(destinations)
                print("Writing the \(skill.name) skill, a copy that names \(layout.cliExecutableURL.path):")
                for destination in destinations { print("  \(destination.file.path)") }
                try installer.install(skill, at: destinations)
                print("Done. New sessions of the tool read it.")
                return .done
            case .remove:
                // Every place is processed; the highest exit code among the problems is returned.
                var code = AgentExitCode.done
                for place in places {
                    do {
                        let destination = try installer.destination(for: place, skillName: AgentHarness.entrySkillName)
                        print(try installer.remove(at: destination) ? "Removed \(destination.folder.path)." : "No skill of Arch's is at \(destination.folder.path).")
                    } catch let failure as AgentSkillInstaller.Failure {
                        printError(failure.message)
                        if failure.exitCode.rawValue > code.rawValue { code = failure.exitCode }
                    }
                }
                return code
            }
        } catch let failure as AgentSkillInstaller.Failure {
            printError(failure.message)
            return failure.exitCode
        } catch {
            printError("\(error)")
            return .internalError
        }
    }

    private static func stateText(_ state: AgentSkillInstaller.State, place: AgentSkillInstaller.Place) -> String {
        let option: String
        switch place {
        case .target(let target): option = "--target \(target.rawValue)"
        case .path(let path): option = "--path \(AgentMCPConfiguration.shellCommand([path]))"
        }
        switch state {
        case .absent: return "Not installed. arch-cli skills install \(option) writes it."
        case .current: return "Installed, with this Arch's text."
        case .outdated: return "Installed, but older than this Arch or written by a copy of Arch elsewhere. arch-cli skills install \(option) updates it."
        case .modified: return "Arch's copy with changes made after Arch wrote it, which arch-cli leaves alone."
        case .foreign: return "A folder that Arch did not write, which arch-cli leaves alone."
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
