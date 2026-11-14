// Claude Code's `claude` as Arch runs it: the exact arguments and environment of a session and of an ordinary request, the session's MCP configuration, the `--help` probe, the start check on every `init` event, and the decoder of its stream-json output (`docs/agents.md`, Claude Code). The recorded streams in `AITests/Fixtures/Agent` are the reference for every event read here.
import Foundation

enum ClaudeCodeAgent {
    /// The listed flags Arch passes, which `claude --help` must list; `--max-turns` is not in `--help`, so its missing-value diagnostic checks support for a bounded run.
    static let requiredFlags = ["--print", "--verbose", "--input-format", "--output-format", "--include-partial-messages", "--no-session-persistence",
                                "--session-id", "--restricted", "--tools", "--strict-mcp-config", "--mcp-config", "--allowedTools", "--permission-mode",
                                "--permission-prompts", "--disable-slash-commands", "--append-system-prompt", "--model", "--effort", "--plugin-dir",
                                "--settings"]
    /// The levels `--effort` takes.
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    /// The MCP server name, which makes the tools `mcp__arch__<name>`.
    static let serverName = "arch"
    static let maxTurns = 150
    /// With a session skill folder: turns off `plugin-authoring`, the skill of a reviewed built-in plugin that the model could call and that writes files of its own. A `Skill(<name>)` rule in `--allowedTools` does not narrow the skill tool: 2.1.323 ran a skill that such a rule left out.
    static let skillSettings = #"{"skillOverrides":{"plugin-authoring":"off"}}"#

    // MARK: Arguments

    /// One long-lived session process (agent decision 11). With `skills`, the skill tool, the session's skill folder, and `skillSettings` replace `--disable-slash-commands` (agent decision 16).
    static func sessionArguments(sessionID: UUID, configuration: URL, instructions: String, model: String, effort: String?, skills: AIAgentSkills?, maxTurns: Int? = nil) -> [String] {
        var arguments = ["-p", "--verbose",
                         "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages",
                         "--no-session-persistence", "--session-id", sessionID.uuidString.lowercased(),
                         "--restricted", "--tools", skills == nil ? "" : "Skill",
                         "--strict-mcp-config", "--mcp-config", configuration.path,
                         "--allowedTools", skills == nil ? "mcp__\(serverName)__*" : "mcp__\(serverName)__*,Skill",
                         "--permission-mode", "dontAsk", "--permission-prompts", "none"]
        if let skills {
            arguments += ["--plugin-dir", skills.folder.path, "--settings", skillSettings]
        } else {
            arguments.append("--disable-slash-commands")
        }
        arguments += ["--append-system-prompt", instructions, "--max-turns", String(maxTurns ?? Self.maxTurns)]
        if !model.isEmpty { arguments += ["--model", model] }
        if let effort, effortLevels.contains(effort) { arguments += ["--effort", effort] }
        return arguments
    }

    /// A request of another feature: no tools, no server, and the prompt as text on standard input (agent decision 4).
    static func ordinaryArguments(model: String) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--no-session-persistence",
                         "--restricted", "--tools", "", "--strict-mcp-config", "--permission-mode", "dontAsk", "--permission-prompts", "none",
                         "--disable-slash-commands"]
        if !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    /// The telemetry, update, instruction file, and memory switches every run gets, on top of the tool's run environment.
    static let quietEnvironment = ["DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1", "DISABLE_AUTOUPDATER": "1",
                                   "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "ENABLE_TOOL_SEARCH": "false",
                                   "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"]

    static func ordinaryEnvironment(_ base: [String: String]) -> [String: String] {
        base.merging(quietEnvironment) { _, fixed in fixed }
    }

    /// The MCP timeouts bound the server's start and sit above the approval wait. With skills, the bundled and policy skills, `doctor`, the extra usage commands, and fast mode stay out, so only the session's skills and the reviewed built-in commands remain.
    static func sessionEnvironment(_ base: [String: String], skills: AIAgentSkills?) -> [String: String] {
        var environment = ordinaryEnvironment(base)
        environment["MCP_TIMEOUT"] = "20000"
        environment["MCP_TOOL_TIMEOUT"] = "900000"
        if skills != nil {
            environment["CLAUDE_CODE_DISABLE_BUNDLED_SKILLS"] = "1"
            environment["CLAUDE_CODE_DISABLE_POLICY_SKILLS"] = "1"
            environment["DISABLE_DOCTOR_COMMAND"] = "1"
            environment["DISABLE_EXTRA_USAGE_COMMAND"] = "1"
            environment["CLAUDE_CODE_DISABLE_FAST_MODE"] = "1"
        }
        return environment
    }

    /// `mcp.json`, which keeps the ticket out of the argument list.
    static func mcpConfiguration(_ server: AIAgentToolServer) throws -> Data {
        let entry: [String: Any] = ["type": "stdio", "command": server.executable.path, "args": server.arguments, "env": server.environment]
        return try JSONSerialization.data(withJSONObject: ["mcpServers": [serverName: entry]], options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// One user message on standard input.
    static func userMessage(_ text: String) -> Data {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        return jsonLine(message)
    }

    /// Stops the turn; the process stays for the next message.
    static func interrupt(requestID: String) -> Data {
        jsonLine(["type": "control_request", "request_id": requestID, "request": ["subtype": "interrupt"]])
    }

    private static func jsonLine(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    // MARK: Probe

    /// `--version`, then whether `--help` lists every flag Arch passes. Runs no model.
    static func probe(executable: URL, environment: [String: String]) async throws -> AIAgentProbeResult {
        let version = AIAgentToolStatus.versionNumber(in: try await AIAgentCommand.run(executable, ["--version"], environment: environment).output)
        let help = try await AIAgentCommand.run(executable, ["--help"], environment: environment)
        let missing = missingFlags(inHelp: help.output)
        if !missing.isEmpty {
            throw AIAgentToolError(detail: "Claude Code\(version.map { " \($0)" } ?? "") does not accept \(missing.joined(separator: ", ")). Update Claude Code in the terminal.")
        }
        // The option is hidden from help. With no value, its parser reports a missing argument before it can start a model.
        let limit = try await AIAgentCommand.run(executable, ["--max-turns"], environment: environment)
        let acceptsLimit = !limit.succeeded && limit.errorLine?.contains("--max-turns") == true && limit.errorLine?.contains("argument missing") == true
        return AIAgentProbeResult(version: version, supportsRunOption: acceptsLimit)
    }

    static func missingFlags(inHelp help: String) -> [String] {
        requiredFlags.filter { flag in
            help.firstMatch(of: try! Regex("(^|[\\s,])\(flag)([\\s,<=]|$)").anchorsMatchLineEndings()) == nil
        }
    }
}

// MARK: - Start check

/// What every `init` event must show (`docs/agents.md`, Claude Code ▸ Start check). The reviewed lists hold the built-in plugins, agent types, and commands of 2.1.323 under Arch's arguments and environment; a name joins only after review, so a version that adds one is refused until the presets are updated. With a session skill folder, `skills` may list only the folder's skills.
struct ClaudeCodeStartCheck {
    static let reviewedPlugins: Set<String> = ["cc-plugin-agents-md", "cc-plugin-privacy", "cc-plugin-plugin-authoring"]
    static let reviewedAgentTypes: Set<String> = ["claude", "Explore", "general-purpose", "Plan", "statusline-setup"]
    /// With a session skill folder and its environment and settings: the built-in commands that `init` still lists (`claude-skills` in the fixtures). A message that starts with `/` runs one, which `AIAgentSession.send(_:)` refuses; the model cannot call them.
    static let reviewedCommands: Set<String> = ["agents", "auto-mode-setup", "autocompact", "clear", "color", "compact", "config", "output-style", "context",
                                                "effort", "fast", "focus", "heapdump", "init", "mcp", "model", "__remote-workflow", "workflow-launch-exec",
                                                "reload-plugins", "reload-skills", "rename", "security-review", "usage", "insights", "recap", "goal",
                                                "list-agents", "team-onboarding"]

    /// nil for an ordinary request, which may list no tool and no server.
    var session: Session?

    struct Session {
        /// The server's `tools/list` answers on the session's connection, the first one first, by MCP name.
        var offeredTools: [[String]]
        var skills: AIAgentSkills?
    }

    /// Whether `event` passes; otherwise the sentence the user sees. `isFirst` is true for the process's first `init`, which must list every tool of the first `tools/list` answer.
    func failure(of event: [String: Any], isFirst: Bool) -> String? {
        var extra: [String] = []
        var disconnected = false
        let prefix = "mcp__\(ClaudeCodeAgent.serverName)__"
        let tools = event["tools"] as? [String] ?? []
        let servers = event["mcp_servers"] as? [[String: Any]] ?? []

        // Tools and servers.
        var listed = Set<String>()
        for tool in tools {
            if tool.hasPrefix(prefix), session != nil {
                listed.insert(String(tool.dropFirst(prefix.count)))
            } else if tool == "Skill", session?.skills != nil {
                continue
            } else {
                extra.append(tool)
            }
        }
        if let session {
            let offered = session.offeredTools
            let all = offered.reduce(into: Set<String>()) { $0.formUnion($1) }
            let common = offered.dropFirst().reduce(Set(offered.first ?? [])) { $0.intersection($1) }
            let required = isFirst ? Set(offered.first ?? []) : common
            extra += listed.subtracting(all).sorted().map { prefix + $0 }
            if !required.isSubset(of: listed) { disconnected = true }
            let arch = servers.filter { $0["name"] as? String == ClaudeCodeAgent.serverName }
            if arch.count != 1 || arch.first?["status"] as? String != "connected" { disconnected = true }
        }
        extra += servers.compactMap { $0["name"] as? String }.filter { session == nil || $0 != ClaudeCodeAgent.serverName }.map { "the server \($0)" }

        // Skills, commands, plugins, and agent types.
        let skills = session?.skills
        let allowedSkills = skills.map { skills in Set(skills.names.map { "\(skills.plugin):\($0)" }) } ?? []
        let listedSkills = event["skills"] as? [String] ?? []
        extra += listedSkills.filter { !allowedSkills.contains($0) }.map { "the skill \($0)" }
        let allowedCommands = skills == nil ? Set<String>() : Set(listedSkills).union(Self.reviewedCommands)
        extra += (event["slash_commands"] as? [String] ?? []).filter { !allowedCommands.contains($0) }.map { "the command /\($0)" }
        for plugin in event["plugins"] as? [[String: Any]] ?? [] {
            let name = plugin["name"] as? String ?? "?"
            let path = plugin["path"] as? String
            let isReviewed = path == "builtin" && plugin["source"] as? String == "\(name)@builtin" && Self.reviewedPlugins.contains(name)
            let isSessionSkills = skills.map { name == $0.plugin && path.map(Self.resolved) == Self.resolved($0.folder.path) } ?? false
            if !isReviewed && !isSessionSkills { extra.append("the plugin \(name)") }
        }
        extra += (event["agents"] as? [String] ?? []).filter { !Self.reviewedAgentTypes.contains($0) }.map { "the agent type \($0)" }

        // Settings that must hold.
        if let mode = event["permissionMode"] as? String, mode != "dontAsk" { extra.append("the permission mode \(mode)") }
        if event["permissionMode"] == nil { extra.append("an unknown permission mode") }
        if Self.hasMemory(event["memory_paths"]) { extra.append("its memory") }
        if event["analytics_disabled"] as? Bool != true { extra.append("its telemetry") }

        if !extra.isEmpty { return "Claude Code started with tools Arch did not ask for: \(extra.joined(separator: ", "))." }
        if disconnected { return "Arch's tools did not connect." }
        return nil
    }

    /// `memory_paths` is absent or null while no memory loads, and an object such as `{"auto": "<folder>"}` when it does.
    private static func hasMemory(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let object as [String: Any]: return !object.isEmpty
        case let array as [Any]: return !array.isEmpty
        default: return true
        }
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

// MARK: - Stream

/// Turns Claude Code's stream-json lines into the runner's events. Text comes only from `stream_event` deltas; `user`, `assistant`, `control_response`, and unknown line types are skipped. Every `init` goes through the start check, and one that fails throws `blockedByPolicy(.agentUsedOwnTools)`. Each `message_start` is the model's output, which the runner's `ready` waits for.
struct ClaudeCodeStreamDecoder {
    var check: ClaudeCodeStartCheck
    let provider: AIProviderID
    private var hasPassedInit = false
    /// Each model request's last reported usage in the current turn, for a turn that an interrupt ended.
    private var requestUsages: [AIUsage] = []
    /// Whether a `rate_limit_event` since the last `result` reported `rejected`, and the reset time it gave.
    private var isLimitRejected = false
    private var limitResetsAt: Date?

    init(check: ClaudeCodeStartCheck, provider: AIProviderID) {
        self.check = check
        self.provider = provider
    }

    mutating func decode(_ object: [String: Any]) throws -> [AIAgentStreamEvent] {
        switch object["type"] as? String {
        case "system":
            guard object["subtype"] as? String == "init" else { return [] }
            if let failure = check.failure(of: object, isFirst: !hasPassedInit) {
                throw AIError.blockedByPolicy(.agentUsedOwnTools(failure))
            }
            requestUsages = []
            defer { hasPassedInit = true }
            return hasPassedInit ? [] : [.started(threadID: nil)]
        case "stream_event":
            return streamEvent(object["event"] as? [String: Any] ?? [:])
        case "rate_limit_event":
            let info = object["rate_limit_info"] as? [String: Any] ?? [:]
            if info["status"] as? String == "rejected" {
                isLimitRejected = true
                limitResetsAt = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            }
            return Self.rateLimitNotice(info).map { [.notice($0)] } ?? []
        case "result":
            return result(object)
        default:
            return []
        }
    }

    private mutating func streamEvent(_ event: [String: Any]) -> [AIAgentStreamEvent] {
        switch event["type"] as? String {
        case "message_start":
            if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] { requestUsages.append(Self.usage(usage)) }
            return [.output]
        case "message_delta":
            if let usage = event["usage"] as? [String: Any], !requestUsages.isEmpty {
                requestUsages[requestUsages.count - 1] = Self.usage(usage, over: requestUsages[requestUsages.count - 1])
            }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty { return [.text(text)] }
            case "thinking_delta":
                if let text = delta["thinking"] as? String, !text.isEmpty { return [.thinking(text)] }
            default:
                break
            }
        default:
            break
        }
        return []
    }

    /// The turn's end. After an interrupt, `result.usage` leaves out the interrupted request, so the turn's usage is the sum of each request's last stream usage instead.
    private mutating func result(_ object: [String: Any]) -> [AIAgentStreamEvent] {
        defer {
            requestUsages = []
            isLimitRejected = false
            limitResetsAt = nil
        }
        let subtype = object["subtype"] as? String
        let reason = object["terminal_reason"] as? String
        let usage: AIUsage? = reason == "aborted_streaming"
            ? requestUsages.reduce(AIUsage(inputTokens: 0, outputTokens: 0), +)
            : (object["usage"] as? [String: Any]).map { Self.usage($0) }
        var events = usage.map { [AIAgentStreamEvent.usage($0)] } ?? []
        if subtype == "error_max_turns" {
            events.append(.turnEnded(.turnLimit))
        } else if object["is_error"] as? Bool == true || subtype != "success" {
            let detail = (object["result"] as? String) ?? (object["errors"] as? [String])?.joined(separator: " ") ?? "Claude Code ended the turn with \(subtype ?? "an error")."
            events.append(.turnFailed(error(of: object, detail: detail)))
        } else {
            events.append(.turnEnded(reason == "aborted_streaming" ? .stopped : .completed))
        }
        return events
    }

    /// A usage limit (HTTP 429, `api_error` `usage_limit_reached`, or a `rate_limit_event` that reported `rejected`) as `rateLimited` until the reset time the tool gave, and a sign-in the tool asks for again as `authentication`.
    private func error(of object: [String: Any], detail: String) -> AIError {
        let status = object["api_error_status"] as? Int
        if status == 429 || object["api_error"] as? String == "usage_limit_reached" || isLimitRejected {
            return .rateLimited(provider, until: limitResetsAt)
        }
        if status == 401 || detail.contains("/login") { return .authentication(provider) }
        return .providerUnavailable(provider, detail: detail)
    }

    /// As the `messages` format counts: tokens written to the cache count as input, tokens read from it as cached input.
    static func usage(_ object: [String: Any], over earlier: AIUsage? = nil) -> AIUsage {
        var usage = earlier ?? AIUsage(inputTokens: 0, outputTokens: 0)
        if let input = object["input_tokens"] as? Int { usage.inputTokens = input + (object["cache_creation_input_tokens"] as? Int ?? 0) }
        if let cached = object["cache_read_input_tokens"] as? Int { usage.cachedInputTokens = cached }
        if let output = object["output_tokens"] as? Int { usage.outputTokens = output }
        return usage
    }

    /// A notice only when the tool reports a limit other than `allowed`, with its reset time when it gives one.
    static func rateLimitNotice(_ info: [String: Any]) -> String? {
        guard let status = info["status"] as? String, status != "allowed" else { return nil }
        let kind = (info["rateLimitType"] as? String).map { " (\($0.replacingOccurrences(of: "_", with: " ")))" } ?? ""
        guard let reset = info["resetsAt"] as? Double else { return "Claude Code reports its usage limit\(kind): \(status)." }
        let date = Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened)
        return "Claude Code reports its usage limit\(kind): \(status), until \(date)."
    }
}
