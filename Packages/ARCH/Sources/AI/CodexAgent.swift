// Codex's `codex` as Arch runs it: the exact arguments of a session's first and resumed turns, of an ordinary request, and of deleting a thread; the feature derivation and its keep list, the effort levels from the bundled catalog, and the configuration probe, all in an empty `CODEX_HOME`; and the stream watcher (`docs/agents.md`, Codex). The recorded streams and `codex-features-list.txt` in `AITests/Fixtures/Agent` are the reference for what is read here.
import Darwin
import Foundation

/// The arguments, feature list, probes, and checks with which Arch runs Codex's `codex` for sessions and ordinary requests.
enum CodexAgent {
    /// Features a turn needs that Arch leaves on, each with its reason. A feature joins only when a turn needs it and it adds no tool of its own.
    static let keptFeatures: [String: String] = [
        // Every bundled model except gpt-5.5 calls tools only through the code-mode host; without it a session turn calls no tool (Risk 15).
        "code_mode_host": "The models call Arch's tools only through the code-mode host.",
    ]
    /// Without these two in the list, Arch could not confirm that the shell is off.
    static let shellFeatures = ["shell_tool", "unified_exec"]
    static let serverName = "arch"
    /// The first error item of an ordinary request, which turns the code-mode host off since it calls no tool.
    static let codeModeUnavailablePrefix = "Code Mode is unavailable"

    // MARK: Arguments

    /// The settings every run gets: read-only, no approvals, no web search, no prompt history or project document, no skills in the instructions, and no telemetry or update check.
    static let baseSettings = ["sandbox_mode=\"read-only\"", "approval_policy=\"never\"", "web_search=\"disabled\"",
                               "history.persistence=\"none\"", "project_doc_max_bytes=0", "skills.include_instructions=false",
                               "analytics.enabled=false", "otel.exporter=\"none\"", "check_for_update_on_startup=false"]

    /// Arch's server, with the ticket passed by name from the environment Arch gives `codex`, and the static harness.
    static func sessionSettings(server: AIAgentToolServer, instructions: String) -> [String] {
        ["mcp_servers.\(serverName).command=\(tomlString(server.executable.path))",
         "mcp_servers.\(serverName).args=\(tomlArray(server.arguments))",
         "mcp_servers.\(serverName).env_vars=\(tomlArray(server.environment.keys.sorted()))",
         "mcp_servers.\(serverName).required=true",
         "mcp_servers.\(serverName).startup_timeout_sec=20",
         "mcp_servers.\(serverName).tool_timeout_sec=900",
         "mcp_servers.\(serverName).default_tools_approval_mode=\"approve\"",
         "developer_instructions=\(tomlString(instructions))"]
    }

    /// The options shared by first and resumed turns: the settings as `-c` arguments and each derived `--disable`.
    static func options(settings: [String], disabled: [String]) -> [String] {
        ["--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"] + settings.flatMap { ["-c", $0] } + disabled.flatMap { ["--disable", $0] }
    }

    /// `-m` on every turn, so a resumed turn keeps the session's model, and the effort when the model's catalog lists it.
    static func modelArguments(model: String, effort: String?, levels: [String: [String]]) -> [String] {
        guard !model.isEmpty else { return [] }
        var arguments = ["-m", model]
        if let effort, levels[model]?.contains(effort) == true { arguments += ["-c", "model_reasoning_effort=\(tomlString(effort))"] }
        return arguments
    }

    /// A session's first turn. `--no-daemon` is a top-level flag, so it comes before `exec`.
    static func firstTurnArguments(server: AIAgentToolServer, instructions: String, disabled: [String], model: String, effort: String?, levels: [String: [String]], folder: URL, ephemeral: Bool = false) -> [String] {
        ["--no-daemon", "exec", "--json"] + (ephemeral ? ["--ephemeral"] : []) + options(settings: baseSettings + sessionSettings(server: server, instructions: instructions), disabled: disabled)
            + modelArguments(model: model, effort: effort, levels: levels) + ["-C", folder.path, "-"]
    }

    /// A follow-up turn on the thread. `exec resume` takes neither `-C` nor `-s`, so the runner starts it in the session folder.
    static func resumeArguments(thread: String, server: AIAgentToolServer, instructions: String, disabled: [String], model: String, effort: String?, levels: [String: [String]]) -> [String] {
        ["--no-daemon", "exec", "resume", thread, "--json"] + options(settings: baseSettings + sessionSettings(server: server, instructions: instructions), disabled: disabled)
            + modelArguments(model: model, effort: effort, levels: levels) + ["-"]
    }

    /// A request of another feature: ephemeral, no server or harness, and the code-mode host off too, since it calls no tool.
    static func ordinaryArguments(disabled: [String], model: String) -> [String] {
        ["--no-daemon", "exec", "--json", "--ephemeral"] + options(settings: baseSettings, disabled: disabled + ["code_mode_host"])
            + (model.isEmpty ? [] : ["-m", model]) + ["-"]
    }

    /// Removes the thread's rollout file and its rows in Codex's databases. Without `--force` it refuses outside a terminal.
    static func deleteArguments(thread: String) -> [String] {
        ["--no-daemon", "delete", "--force", thread]
    }

    // MARK: TOML

    /// A TOML basic string, so that no text can be read as TOML.
    static func tomlString(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    static func tomlArray(_ items: [String]) -> String {
        "[" + items.map(tomlString).joined(separator: ",") + "]"
    }

    // MARK: Feature derivation

    /// Every listed feature gets `--disable`, whatever its reported state, except those at stage `removed`, deprecated ones listed as off, whose `--disable` only adds a deprecation error item, and the keep list. Lines are `<name> <stage words> <true|false>`. Throws when the list lacks a shell feature.
    static func disabledFeatures(fromList list: String) throws -> [String] {
        var disabled: [String] = []
        var names = Set<String>()
        for line in list.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 3, let state = Bool(words[words.count - 1]) else { continue }
            let name = words[0]
            let stage = words[1..<(words.count - 1)].joined(separator: " ")
            names.insert(name)
            if stage == "removed" || (stage == "deprecated" && !state) || keptFeatures[name] != nil { continue }
            disabled.append(name)
        }
        if let missing = shellFeatures.first(where: { !names.contains($0) }) {
            throw AIAgentToolError(detail: localized("Codex does not list the feature \(missing), so Arch cannot confirm that its shell is off. Update Codex in the terminal."))
        }
        return disabled
    }

    /// Each model's effort levels from `codex debug models --bundled`, by slug. Nothing else of the catalog is read.
    static func effortLevels(fromCatalog data: Data) -> [String: [String]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let models = object["models"] as? [[String: Any]] else { return [:] }
        var levels: [String: [String]] = [:]
        for model in models {
            guard let slug = model["slug"] as? String else { continue }
            levels[slug] = (model["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
        }
        return levels
    }

    // MARK: Probe

    /// `--version`, the feature list, the bundled catalog, and the configuration probe, each run with `CODEX_HOME` set to a new empty folder, since the user's `config.toml` would change what they report. Runs no model and works signed out.
    static func probe(executable: URL, environment: [String: String]) async throws -> AIAgentProbeResult {
        let version = AIAgentToolStatus.versionNumber(in: try await AIAgentCommand.run(executable, ["--version"], environment: environment).output)
        let name = "Codex\(version.map { " \($0)" } ?? "")"
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Arch-Codex-Probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AIAgentToolError(detail: localized("\(name) could not be checked: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: home) }
        var probeEnvironment = environment
        probeEnvironment["CODEX_HOME"] = home.path

        let features = try await AIAgentCommand.run(executable, ["--no-daemon", "features", "list"], environment: probeEnvironment)
        guard features.succeeded else {
            throw AIAgentToolError(detail: localized("\(name) could not list its features: \(features.errorLine ?? localized("it exited with an error")). Update Codex in the terminal."))
        }
        let disabled = try disabledFeatures(fromList: features.output)
        let catalog = try await AIAgentCommand.run(executable, ["--no-daemon", "debug", "models", "--bundled"], environment: probeEnvironment)
        let levels = catalog.succeeded ? effortLevels(fromCatalog: Data(catalog.output.utf8)) : [:]
        try await checkConfiguration(executable: executable, environment: probeEnvironment, disabled: disabled, name: name)
        let ephemeral = try await AIAgentCommand.run(executable, ["--no-daemon", "exec", "--ephemeral", "--help"], environment: probeEnvironment)
        return AIAgentProbeResult(version: version, supportsRunOption: ephemeral.succeeded && ephemeral.output.contains("--ephemeral"),
                                  disabledFeatures: disabled, effortLevels: levels)
    }

    /// The session's settings with placeholder values of the same types, since the probe validates keys, feature names, and value types, and the two free texts are TOML strings whatever they hold.
    static let probeSettings = baseSettings + sessionSettings(server: AIAgentToolServer(executable: URL(fileURLWithPath: "/arch-mcp"), arguments: ["--session"],
                                                                                         environment: ["ARCH_AGENT_TICKET": ""], tools: []), instructions: "Arch")

    /// `--strict-config` with every `-c` and `--disable` of the session, which starts nothing. The tool names an unknown feature itself; for an unknown key or value it says only that the configuration is unavailable, so Arch then probes the settings in groups and names the first the tool refuses: each `-c` alone, except the server's, which go together because the server is invalid without its command.
    static func checkConfiguration(executable: URL, environment: [String: String], disabled: [String], name: String) async throws {
        func probe(_ settings: [String], _ disabled: [String]) async throws -> AIAgentCommandResult {
            try await AIAgentCommand.run(executable, ["--no-daemon", "--strict-config"] + settings.flatMap { ["-c", $0] } + disabled.flatMap { ["--disable", $0] }
                                         + ["app-server", "--print-startup-config"], environment: environment)
        }
        let all = try await probe(probeSettings, disabled)
        if all.succeeded { return }
        if let line = all.errorLine, line.contains("Unknown feature") {
            throw AIAgentToolError(detail: localized("\(name) refuses Arch's settings: \(line). Update Codex in the terminal."))
        }
        for group in settingGroups(probeSettings) {
            if try await !probe(group.settings, []).succeeded {
                throw AIAgentToolError(detail: localized("\(name) does not accept `\(group.key)`. Update Codex in the terminal."))
            }
        }
        throw AIAgentToolError(detail: localized("\(name) refuses Arch's settings: \(all.errorLine ?? localized("the startup configuration is unavailable")). Update Codex in the terminal."))
    }

    /// Each setting alone, named by its key, except the server's settings, which form one group named after the server.
    static func settingGroups(_ settings: [String]) -> [(key: String, settings: [String])] {
        let serverPrefix = "mcp_servers.\(serverName)."
        var groups: [(key: String, settings: [String])] = []
        for setting in settings {
            let key = String(setting.prefix { $0 != "=" })
            if key.hasPrefix(serverPrefix) {
                if let index = groups.firstIndex(where: { $0.key == "mcp_servers.\(serverName)" }) {
                    groups[index].settings.append(setting)
                } else {
                    groups.append((key: "mcp_servers.\(serverName)", settings: [setting]))
                }
            } else {
                groups.append((key: key, settings: [setting]))
            }
        }
        return groups
    }
}

// MARK: - Stream watcher

/// Turns Codex's JSON lines into the runner's events and watches them. Codex has no start event that lists tools, so only the item types `agent_message`, `reasoning`, `mcp_tool_call` to Arch's server in a session, `todo_list`, and `error` pass; any other item, or a call to another server, throws `blockedByPolicy(.agentUsedOwnTools)` at once.
struct CodexStreamDecoder {
    static let acceptedItems: Set<String> = ["agent_message", "reasoning", "mcp_tool_call", "todo_list", "error"]

    /// A session turn may call Arch's server; an ordinary request calls nothing and skips the code-mode error item.
    let isSession: Bool
    let provider: AIProviderID
    /// The last error the stream reported, for a turn that ends without `turn.completed`.
    private(set) var lastError: String?

    init(isSession: Bool, provider: AIProviderID) {
        self.isSession = isSession
        self.provider = provider
    }

    mutating func decode(_ object: [String: Any]) throws -> [AIAgentStreamEvent] {
        switch object["type"] as? String {
        case "thread.started":
            return [.started(threadID: object["thread_id"] as? String)]
        case "item.started", "item.updated", "item.completed":
            let item = object["item"] as? [String: Any] ?? [:]
            try watch(item)
            // Any item but an error is the model's output.
            let output: [AIAgentStreamEvent] = item["type"] as? String == "error" ? [] : [.output]
            guard object["type"] as? String == "item.completed" else { return output }
            return output + completed(item)
        case "turn.completed":
            // The thread's running total, which the session turns into the turn's own usage.
            let usage = (object["usage"] as? [String: Any]).map(Self.usage)
            return (usage.map { [AIAgentStreamEvent.usage($0)] } ?? []) + [.turnEnded(.completed)]
        case "turn.failed":
            let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? lastError ?? localized("Codex ended the turn with an error.")
            return [.turnFailed(Self.isUsageLimit(message) ? .rateLimited(provider, until: nil) : .providerUnavailable(provider, detail: message))]
        case "error":
            // Codex can report a retry this way and go on; a turn that then ends without `turn.completed` fails with it.
            lastError = object["message"] as? String ?? lastError
            return lastError.map { [.notice($0)] } ?? []
        default:
            return []
        }
    }

    private func watch(_ item: [String: Any]) throws {
        let type = item["type"] as? String ?? "unknown"
        guard Self.acceptedItems.contains(type) else { throw AIError.blockedByPolicy(.agentUsedOwnTools(Self.sentence(forItem: type))) }
        guard type == "mcp_tool_call" else { return }
        let server = item["server"] as? String ?? "?"
        guard isSession, server == CodexAgent.serverName else {
            throw AIError.blockedByPolicy(.agentUsedOwnTools(localized("Codex called a tool of the server \(server), which Arch did not ask for.")))
        }
    }

    private mutating func completed(_ item: [String: Any]) -> [AIAgentStreamEvent] {
        switch item["type"] as? String {
        case "agent_message":
            guard let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.text(text)]
        case "reasoning":
            guard let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.thinking(text)]
        case "error":
            guard let message = item["message"] as? String else { return [] }
            if !isSession, message.hasPrefix(CodexAgent.codeModeUnavailablePrefix) { return [] }
            return [.notice(message)]
        default:
            return []
        }
    }

    static func sentence(forItem type: String) -> String {
        switch type {
        case "command_execution": return localized("Codex ran a command.")
        case "file_change": return localized("Codex changed a file.")
        case "web_search": return localized("Codex searched the web.")
        default: return localized("Codex used \(type.replacingOccurrences(of: "_", with: " ")), which Arch did not ask for.")
        }
    }

    /// Codex's sentences for a usage limit ("You’ve hit your usage limit…") and for retries that ended on a 429.
    static func isUsageLimit(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("usage limit") || message.contains("Too Many Requests")
    }

    /// As the `chatCompletions` format counts: `input_tokens` includes the cached tokens, which `inputTokens` leaves out.
    static func usage(_ object: [String: Any]) -> AIUsage {
        let input = object["input_tokens"] as? Int ?? 0
        let cached = object["cached_input_tokens"] as? Int ?? 0
        return AIUsage(inputTokens: max(input - cached, 0), outputTokens: object["output_tokens"] as? Int ?? 0, cachedInputTokens: cached)
    }
}
