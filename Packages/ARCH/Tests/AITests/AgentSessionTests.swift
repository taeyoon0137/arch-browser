// Agent sessions on the user's CLI (docs/agents.md, Tests ▸ AITests): the exact arguments and environments of Claude Code and Codex, the start check and the stream watcher, the feature derivation and the configuration probe, the probes that run again when the executable changes, the open input mode, Stop, the idle timer, fallbacks before `ready`, Codex's thread deletion, usage under `agent`, an automatic feature's turns under the daily limit and behind the user's requests, the derived `agent` capability, and the presets' ordinary requests. Shell scripts stand in for `claude` and `codex` and replay the recorded streams in `Fixtures/Agent`, so no test reaches a real tool or a model.
import Darwin
import Foundation
import Testing
@testable import AI

private let agentFixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Agent", isDirectory: true)
private let harness = "You are a browser agent in Arch.\nUse only Arch's tools; say \"done\" when finished."
private let ticketServer = AIAgentToolServer(executable: URL(fileURLWithPath: "/Applications/Arch.app/Contents/Helpers/arch-mcp"), arguments: ["--session"],
                                             environment: ["ARCH_AGENT_TICKET": "ticket-1"], tools: ["click", "list_tabs", "session_info"])
/// The skill folder of the recorded `claude-skills` run.
private let recordedSkills = AIAgentSkills(folder: URL(fileURLWithPath: "/private/var/folders/xx/fixture/T/arch-skills"), plugin: "arch", names: ["arch-browser"])
private let agentFeature = AIFeature(id: .agent, name: "Agent", summary: "", trigger: .user, data: AIDataScope(kinds: [.page, .selection, .file]), requirements: [.agent])
/// An agent hook's feature, whose runs start sessions on a route of their own.
private let automaticAgentFeature = AIFeature(id: AIFeatureID(rawValue: "agentHook.test"), name: "Hook Test", summary: "", trigger: .automatic, data: .textOnly,
                                              requirements: [.agent], routing: .perRequest)

// MARK: - Arguments and environment

@Suite(.timeLimit(.minutes(1))) @MainActor struct AgentArgumentTests {
    @Test func claudeCodeSessionArgumentsAndEnvironment() async throws {
        let cli = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(cli: cli, model: "haiku", environment: ["ANTHROPIC_API_KEY": "sk-never", "CLAUDE_CONFIG_DIR": "/custom"])
        let session = try fixture.start(effort: "low")
        let log = AgentEventLog(session)
        try session.send("Call the session_info tool, then reply with only the code word it returned.")
        try await log.wait { $0.contains("finished:completed") }
        await session.end()

        let call = try #require(cli.calls().last)
        let sessionID = try #require(call.firstIndex(of: "--session-id").map { call[$0 + 1] })
        #expect(UUID(uuidString: sessionID) != nil)
        #expect(call == ["-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json", "--include-partial-messages",
                         "--no-session-persistence", "--session-id", sessionID, "--restricted", "--tools", "", "--strict-mcp-config",
                         "--mcp-config", fixture.folder.appendingPathComponent("mcp.json").path, "--allowedTools", "mcp__arch__*",
                         "--permission-mode", "dontAsk", "--permission-prompts", "none", "--disable-slash-commands",
                         "--append-system-prompt", harness, "--max-turns", "150", "--model", "haiku", "--effort", "low"])
        #expect(!call.contains("--fallback-model"))

        let environment = cli.environment()
        #expect(environment["DISABLE_TELEMETRY"] == "1")
        #expect(environment["DISABLE_ERROR_REPORTING"] == "1")
        #expect(environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(environment["ENABLE_TOOL_SEARCH"] == "false")
        #expect(environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] == "1")
        #expect(environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1")
        #expect(environment["MCP_TIMEOUT"] == "20000")
        #expect(environment["MCP_TOOL_TIMEOUT"] == "900000")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/custom")
        #expect(environment["TERM"] == "dumb")
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ARCH_AGENT_TICKET"] == nil)
        #expect(environment["CLAUDE_CODE_DISABLE_BUNDLED_SKILLS"] == nil)
    }

    @Test func claudeCodeKeepsTheTicketInModeSixHundredMCPConfiguration() async throws {
        let cli = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(cli: cli)
        let session = try fixture.start()
        let log = AgentEventLog(session)
        let folderMode = try FileManager.default.attributesOfItem(atPath: fixture.folder.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        try session.send("Hello")
        try await log.wait { $0.contains("finished:completed") }
        let configuration = fixture.folder.appendingPathComponent("mcp.json")
        let mode = try FileManager.default.attributesOfItem(atPath: configuration.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any])
        let arch = try #require((object["mcpServers"] as? [String: Any])?["arch"] as? [String: Any])
        #expect(arch["type"] as? String == "stdio")
        #expect(arch["command"] as? String == "/Applications/Arch.app/Contents/Helpers/arch-mcp")
        #expect(arch["args"] as? [String] == ["--session"])
        #expect(arch["env"] as? [String: String] == ["ARCH_AGENT_TICKET": "ticket-1"])
        await session.end()
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.path))
    }

    @Test func claudeCodeWithSessionSkillsLoadsTheirFolderWithTheSkillTool() {
        let skills = AIAgentSkills(folder: URL(fileURLWithPath: "/private/tmp/arch-skills"), plugin: "arch", names: ["arch-browser"])
        let arguments = ClaudeCodeAgent.sessionArguments(sessionID: UUID(), configuration: URL(fileURLWithPath: "/private/tmp/session/mcp.json"),
                                                         instructions: harness, model: "", effort: "extreme", skills: skills)
        #expect(arguments.contains("--plugin-dir"))
        #expect(arguments[arguments.firstIndex(of: "--plugin-dir")! + 1] == "/private/tmp/arch-skills")
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "Skill")
        #expect(arguments[arguments.firstIndex(of: "--allowedTools")! + 1] == "mcp__arch__*,Skill")
        #expect(arguments[arguments.firstIndex(of: "--settings")! + 1] == #"{"skillOverrides":{"plugin-authoring":"off"}}"#)
        #expect(!arguments.contains("--disable-slash-commands"))
        #expect(!arguments.contains("--model"))
        // An effort the tool does not take is left out.
        #expect(!arguments.contains("--effort"))
        let environment = ClaudeCodeAgent.sessionEnvironment(["HOME": "/h"], skills: skills)
        #expect(environment["CLAUDE_CODE_DISABLE_BUNDLED_SKILLS"] == "1")
        #expect(environment["CLAUDE_CODE_DISABLE_POLICY_SKILLS"] == "1")
        #expect(environment["DISABLE_DOCTOR_COMMAND"] == "1")
        #expect(environment["DISABLE_EXTRA_USAGE_COMMAND"] == "1")
        #expect(environment["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1")
        let plain = ClaudeCodeAgent.sessionEnvironment(["HOME": "/h"], skills: nil)
        #expect(plain["DISABLE_DOCTOR_COMMAND"] == nil && plain["CLAUDE_CODE_DISABLE_FAST_MODE"] == nil)
    }

    @Test func codexFirstAndResumedTurnArgumentsAndEnvironment() async throws {
        let cli = try FakeCLI.codex()
        let fixture = try AgentFixture(cli: cli, kind: .codex, model: "gpt-6-luna", environment: ["OPENAI_API_KEY": "sk-never"])
        let session = try fixture.start(effort: "low")
        let resolved = try #require(realpath(fixture.folder.path, nil))
        let folder = String(cString: resolved)
        free(resolved)
        let log = AgentEventLog(session)
        try session.send("First")
        try await log.wait { $0.contains("finished:completed") }
        try session.send("Second")
        try await log.wait { $0.filter { $0 == "finished:completed" }.count == 2 }
        await session.end(keepingThread: true)

        let disabled = try CodexAgent.disabledFeatures(fromList: String(contentsOf: agentFixtures.appendingPathComponent("codex-features-list.txt"), encoding: .utf8))
        let settings = ["sandbox_mode=\"read-only\"", "approval_policy=\"never\"", "web_search=\"disabled\"", "history.persistence=\"none\"",
                        "project_doc_max_bytes=0", "skills.include_instructions=false", "analytics.enabled=false", "otel.exporter=\"none\"",
                        "check_for_update_on_startup=false",
                        "mcp_servers.arch.command=\"/Applications/Arch.app/Contents/Helpers/arch-mcp\"", "mcp_servers.arch.args=[\"--session\"]",
                        "mcp_servers.arch.env_vars=[\"ARCH_AGENT_TICKET\"]", "mcp_servers.arch.required=true", "mcp_servers.arch.startup_timeout_sec=20",
                        "mcp_servers.arch.tool_timeout_sec=900", "mcp_servers.arch.default_tools_approval_mode=\"approve\"",
                        "developer_instructions=\"You are a browser agent in Arch.\\nUse only Arch's tools; say \\\"done\\\" when finished.\""]
        let options = ["--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"] + settings.flatMap { ["-c", $0] } + disabled.flatMap { ["--disable", $0] }
        let model = ["-m", "gpt-6-luna", "-c", "model_reasoning_effort=\"low\""]
        let turns = cli.calls().filter { $0.contains("exec") }
        #expect(turns.count == 2)
        #expect(turns.first == ["--no-daemon", "exec", "--json"] + options + model + ["-C", fixture.folder.path, "-"])
        #expect(turns.last == ["--no-daemon", "exec", "resume", "00000000-0000-4000-8000-000000000136", "--json"] + options + model + ["-"])
        #expect(cli.text("stdin-first.log") == "First")
        #expect(cli.text("stdin-resume.log") == "Second")
        #expect(cli.text("pwd-resume.log").trimmingCharacters(in: .whitespacesAndNewlines) == folder)
        let environment = cli.environment("env-first.log")
        #expect(environment["ARCH_AGENT_TICKET"] == "ticket-1")
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["TERM"] == "dumb")
        #expect(!cli.calls().contains { $0.contains("delete") })
    }

    @Test func codexEffortNeedsTheModelsCatalogToListIt() {
        let levels = ["gpt-6-luna": ["low", "medium"]]
        #expect(CodexAgent.modelArguments(model: "gpt-6-luna", effort: "ultra", levels: levels) == ["-m", "gpt-6-luna"])
        #expect(CodexAgent.modelArguments(model: "gpt-6-luna", effort: "medium", levels: levels) == ["-m", "gpt-6-luna", "-c", "model_reasoning_effort=\"medium\""])
        #expect(CodexAgent.modelArguments(model: "", effort: "low", levels: levels).isEmpty)
    }

    @Test func ordinaryRequestArguments() {
        #expect(ClaudeCodeAgent.ordinaryArguments(model: "sonnet") == ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                                                                       "--no-session-persistence", "--restricted", "--tools", "", "--strict-mcp-config",
                                                                       "--permission-mode", "dontAsk", "--permission-prompts", "none", "--disable-slash-commands",
                                                                       "--model", "sonnet"])
        let arguments = CodexAgent.ordinaryArguments(disabled: ["shell_tool"], model: "gpt-6-luna")
        #expect(arguments.prefix(4) == ["--no-daemon", "exec", "--json", "--ephemeral"])
        #expect(arguments.suffix(7) == ["--disable", "shell_tool", "--disable", "code_mode_host", "-m", "gpt-6-luna", "-"])
        #expect(!arguments.contains { $0.hasPrefix("mcp_servers") || $0.hasPrefix("developer_instructions") })
        #expect(CodexAgent.deleteArguments(thread: "t-1") == ["--no-daemon", "delete", "--force", "t-1"])
    }

    @Test func tomlStringsCannotBreakOut() {
        #expect(CodexAgent.tomlString("a\"b\\c\nd\te\u{1}") == "\"a\\\"b\\\\c\\nd\\te\\u0001\"")
        #expect(CodexAgent.tomlArray(["--session", "x\"y"]) == "[\"--session\",\"x\\\"y\"]")
    }
}

// MARK: - Start check and watcher

@Suite struct AgentStartCheckTests {
    private static let tools = ["click", "list_tabs", "session_info"]

    private func recordedInit(_ file: String = "claude-session") throws -> [String: Any] {
        let text = try String(contentsOf: agentFixtures.appendingPathComponent("\(file).stdout.jsonl"), encoding: .utf8)
        for line in text.split(separator: "\n") {
            if let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["subtype"] as? String == "init" { return object }
        }
        throw CancellationError()
    }

    private func session(_ offered: [[String]] = [tools], skills: AIAgentSkills? = nil) -> ClaudeCodeStartCheck {
        ClaudeCodeStartCheck(session: ClaudeCodeStartCheck.Session(offeredTools: offered, skills: skills))
    }

    @Test func theRecordedInitPasses() throws {
        #expect(session().failure(of: try recordedInit(), isFirst: true) == nil)
        #expect(ClaudeCodeStartCheck(session: nil).failure(of: try recordedInit("claude-ordinary"), isFirst: true) == nil)
    }

    /// Each field's value as JSON, since test arguments must be `Sendable`.
    @Test(arguments: [
        ("tools", #"["mcp__arch__click","mcp__arch__list_tabs","mcp__arch__session_info","Bash"]"#, "Bash"),
        ("tools", #"["mcp__arch__click","mcp__arch__list_tabs","mcp__arch__session_info","mcp__arch__type"]"#, "mcp__arch__type"),
        ("mcp_servers", #"[{"name":"arch","status":"connected"},{"name":"late","status":"failed"}]"#, "the server late"),
        ("skills", #"["deep-research"]"#, "the skill deep-research"),
        ("slash_commands", #"["review"]"#, "the command /review"),
        ("plugins", #"[{"name":"cc-plugin-telemetry","path":"builtin","source":"cc-plugin-telemetry@builtin"}]"#, "the plugin cc-plugin-telemetry"),
        ("plugins", #"[{"name":"cc-plugin-privacy","path":"/opt/plugins/privacy","source":"cc-plugin-privacy@market"}]"#, "the plugin cc-plugin-privacy"),
        ("agents", #"["claude","browser-helper"]"#, "the agent type browser-helper"),
        ("memory_paths", #"{"auto":"/private/tmp/memory"}"#, "its memory"),
        ("analytics_disabled", "false", "its telemetry"),
        ("permissionMode", #""default""#, "the permission mode default"),
    ])
    func eachFailingInitIsRefused(field: String, json: String, named: String) throws {
        var event = try recordedInit()
        event[field] = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        let failure = try #require(session().failure(of: event, isFirst: true))
        #expect(failure.hasPrefix("Claude Code started with tools Arch did not ask for:"))
        #expect(failure.contains(named))
    }

    @Test func toolsThatDidNotConnectAreRefused() throws {
        var event = try recordedInit()
        event["mcp_servers"] = [["name": "arch", "status": "failed"]]
        #expect(session().failure(of: event, isFirst: true) == "Arch's tools did not connect.")
        event = try recordedInit()
        event["tools"] = ["mcp__arch__click", "mcp__arch__list_tabs"]
        #expect(session().failure(of: event, isFirst: true) == "Arch's tools did not connect.")
    }

    @Test func anOrdinaryRequestMayListNoToolOrServer() throws {
        #expect(ClaudeCodeStartCheck(session: nil).failure(of: try recordedInit(), isFirst: true)?.contains("mcp__arch__click") == true)
    }

    @Test func aLaterInitMayListTheEarlierOrTheNewToolList() throws {
        let raised = [Self.tools, Self.tools + ["type"]]
        var event = try recordedInit()
        #expect(session(raised).failure(of: event, isFirst: false) == nil)
        event["tools"] = (Self.tools + ["type"]).map { "mcp__arch__\($0)" }
        #expect(session(raised).failure(of: event, isFirst: false) == nil)
        // Lowered again: the raised list or the lower one.
        let lowered = [Self.tools + ["type"], Self.tools]
        #expect(session(lowered).failure(of: event, isFirst: false) == nil)
        event["tools"] = Self.tools.map { "mcp__arch__\($0)" }
        #expect(session(lowered).failure(of: event, isFirst: false) == nil)
        // A tool no answer offered, or one every answer offered left out.
        event["tools"] = ["mcp__arch__click", "mcp__arch__list_tabs", "mcp__arch__session_info", "mcp__arch__press"]
        #expect(session(raised).failure(of: event, isFirst: false)?.contains("mcp__arch__press") == true)
        event["tools"] = ["mcp__arch__click", "mcp__arch__list_tabs"]
        #expect(session(raised).failure(of: event, isFirst: false) == "Arch's tools did not connect.")
        // The first init must list the whole first answer.
        event["tools"] = Self.tools.map { "mcp__arch__\($0)" }
        #expect(session([Self.tools + ["type"]]).failure(of: event, isFirst: true) == "Arch's tools did not connect.")
    }

    @Test func theRecordedSkillFolderInitPassesOnlyWithItsSkills() throws {
        let event = try recordedInit("claude-skills")
        #expect(session(skills: recordedSkills).failure(of: event, isFirst: true) == nil)
        // Every built-in command it lists is on the reviewed list, which holds nothing else.
        #expect(Set(event["slash_commands"] as? [String] ?? []) == ClaudeCodeStartCheck.reviewedCommands.union(["arch:arch-browser"]))
        let refused = try #require(session().failure(of: event, isFirst: true))
        #expect(refused.contains("Skill") && refused.contains("the skill arch:arch-browser") && refused.contains("the command /model") && refused.contains("the plugin arch"))
        // The skill that `skillOverrides` turns off, a skill of the user's own, and the folder at another path.
        for skill in ["plugin-authoring", "doctor", "deep-research"] {
            var other = event
            other["skills"] = ["arch:arch-browser", skill]
            #expect(session(skills: recordedSkills).failure(of: other, isFirst: true)?.contains("the skill \(skill)") == true)
        }
        let otherFolder = AIAgentSkills(folder: URL(fileURLWithPath: "/private/tmp/other"), plugin: "arch", names: ["arch-browser"])
        #expect(session(skills: otherFolder).failure(of: event, isFirst: true)?.contains("the plugin arch") == true)
    }

    @Test(arguments: [("command_execution", "Codex ran a command."), ("file_change", "Codex changed a file."),
                      ("web_search", "Codex searched the web."), ("collab_tool_call", "Codex used collab tool call, which Arch did not ask for.")])
    func theWatcherEndsOnForbiddenAndUnknownItems(type: String, sentence: String) {
        for event in ["item.started", "item.completed"] {
            var decoder = CodexStreamDecoder(isSession: true, provider: AIProviderID())
            #expect(refusal { try decoder.decode(["type": event, "item": ["id": "item_0", "type": type]]) } == sentence)
        }
    }

    @Test func theWatcherAcceptsArchsServerOnlyInASession() throws {
        let call: [String: Any] = ["type": "item.started", "item": ["id": "item_0", "type": "mcp_tool_call", "server": "arch", "tool": "click"]]
        var session = CodexStreamDecoder(isSession: true, provider: AIProviderID())
        // A call to Arch's server is the model's output, which `ready` waits for.
        let events = try session.decode(call)
        guard events.count == 1, case .output = events[0] else {
            Issue.record("Expected only the output event, got \(events)")
            return
        }
        var other = call
        other["item"] = ["id": "item_0", "type": "mcp_tool_call", "server": "files", "tool": "read"]
        #expect(refusal { try session.decode(other) } == "Codex called a tool of the server files, which Arch did not ask for.")
        var ordinary = CodexStreamDecoder(isSession: false, provider: AIProviderID())
        #expect(refusal { try ordinary.decode(call) } != nil)
        for type in ["agent_message", "reasoning", "todo_list", "error"] {
            #expect(refusal { try session.decode(["type": "item.completed", "item": ["id": "item_1", "type": type, "text": "x", "message": "x"]]) } == nil)
        }
    }

    @Test func usageLimitsEndTurnsAsRateLimits() throws {
        var codex = CodexStreamDecoder(isSession: true, provider: AIProviderID())
        let limited = try codex.decode(["type": "turn.failed", "error": ["message": "You\u{2019}ve hit your usage limit. Try again at 3:00 PM."]])
        guard case .turnFailed(.rateLimited(_, nil))? = limited.first else {
            Issue.record("Expected rateLimited, got \(limited)")
            return
        }
        var claude = ClaudeCodeStreamDecoder(check: ClaudeCodeStartCheck(session: nil), provider: AIProviderID())
        let ended = try claude.decode(["type": "result", "subtype": "success", "is_error": true, "api_error": "usage_limit_reached", "result": "You've hit your limit"])
        guard case .turnFailed(.rateLimited(_, nil))? = ended.last else {
            Issue.record("Expected rateLimited, got \(ended)")
            return
        }
        let signedOut = try claude.decode(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in \u{B7} Please run /login"])
        guard case .turnFailed(.authentication)? = signedOut.last else {
            Issue.record("Expected authentication, got \(signedOut)")
            return
        }
    }

    /// The sentence of the `agentUsedOwnTools` refusal that `body` throws, or nil when it throws none.
    private func refusal(_ body: () throws -> [AIAgentStreamEvent]) -> String? {
        do {
            _ = try body()
            return nil
        } catch AIError.blockedByPolicy(.agentUsedOwnTools(let detail)) {
            return detail
        } catch {
            return "unexpected: \(error)"
        }
    }

    @Test func featureDerivationFromTheRecordedList() throws {
        let list = try String(contentsOf: agentFixtures.appendingPathComponent("codex-features-list.txt"), encoding: .utf8)
        let disabled = try CodexAgent.disabledFeatures(fromList: list)
        #expect(disabled.count == 132)
        // Features listed as off are disabled too; removed ones, deprecated ones listed as off, and the keep list are not.
        #expect(disabled.contains("shell_tool") && disabled.contains("unified_exec") && disabled.contains("daemon_auto_start"))
        #expect(disabled.contains("agent_message_board"))
        #expect(!disabled.contains("apply_patch_freeform"))
        #expect(!disabled.contains("web_search_cached") && !disabled.contains("use_legacy_landlock"))
        #expect(!disabled.contains("code_mode_host"))
        let withoutShell = list.split(separator: "\n").filter { !$0.hasPrefix("shell_tool ") }.joined(separator: "\n")
        #expect(throws: AIAgentToolError.self) { try CodexAgent.disabledFeatures(fromList: withoutShell) }
    }

    @Test func effortLevelsComeFromTheCatalog() {
        let catalog = Data(#"{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"}]},{"slug":"gpt-5.5"}]}"#.utf8)
        #expect(CodexAgent.effortLevels(fromCatalog: catalog) == ["gpt-6-luna": ["low", "max"], "gpt-5.5": []])
    }

    @Test func helpCheckNamesMissingFlags() {
        let help = ClaudeCodeAgent.requiredFlags.filter { $0 != "--restricted" }.map { "  \($0) <value>  Something" }.joined(separator: "\n")
        #expect(ClaudeCodeAgent.missingFlags(inHelp: help) == ["--restricted"])
        #expect(ClaudeCodeAgent.missingFlags(inHelp: help + "\n  --restricted-mode  Other").contains("--restricted"))
    }
}

// MARK: - Probes

@Suite(.timeLimit(.minutes(1))) @MainActor struct AgentProbeTests {
    @Test func probesRunAgainWhenTheExecutableChanges() async throws {
        let cli = try FakeCLI.claude(turns: [])
        let store = AIAgentProbeStore()
        let environment = ["PATH": "/usr/bin:/bin"]
        _ = try await store.result(kind: .claudeCode, executable: cli.executable, environment: environment)
        _ = try await store.result(kind: .claudeCode, executable: cli.executable, environment: environment)
        #expect(cli.calls().filter { $0 == ["--help"] }.count == 1)
        // A new size.
        let handle = try FileHandle(forWritingTo: cli.executable)
        handle.seekToEndOfFile()
        handle.write(Data("# updated\n".utf8))
        try handle.close()
        _ = try await store.result(kind: .claudeCode, executable: cli.executable, environment: environment)
        #expect(cli.calls().filter { $0 == ["--help"] }.count == 2)
        // A new modification time alone.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: cli.executable.path)
        _ = try await store.result(kind: .claudeCode, executable: cli.executable, environment: environment)
        #expect(cli.calls().filter { $0 == ["--help"] }.count == 3)
        // A link switched to another release, as the installers update.
        let link = cli.folder.appendingPathComponent("claude-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli.executable)
        _ = try await store.result(kind: .claudeCode, executable: link, environment: environment)
        #expect(cli.calls().filter { $0 == ["--help"] }.count == 3)
        let release = cli.folder.appendingPathComponent("claude-next")
        try FileManager.default.copyItem(at: cli.executable, to: release)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: release)
        _ = try await store.result(kind: .claudeCode, executable: link, environment: environment)
        #expect(cli.calls().filter { $0 == ["--help"] }.count == 4)
    }

    @Test func aMissingFlagRefusesTheVersion() async throws {
        let cli = try FakeCLI.claude(turns: [], help: "  --print  Print\n")
        await #expect(throws: AIAgentToolError.self) {
            try await AIAgentProbeStore().result(kind: .claudeCode, executable: cli.executable, environment: ["PATH": "/usr/bin:/bin"])
        }
    }

    @Test func codexProbesRunInAnEmptyCodexHome() async throws {
        let cli = try FakeCLI.codex()
        let result = try await AIAgentProbeStore().result(kind: .codex, executable: cli.executable, environment: ["PATH": "/usr/bin:/bin", "CODEX_HOME": "/users/own"])
        #expect(result.version == "0.164.0")
        #expect(result.disabledFeatures.count == 132)
        #expect(result.effortLevels["gpt-6-luna"] == ["low", "medium", "high", "xhigh", "max"])
        let homes = cli.text("codex-home.log").split(separator: "\n").map(String.init)
        #expect(homes.count == 3)
        #expect(homes.allSatisfy { $0.contains("/Arch-Codex-Probe-") && !FileManager.default.fileExists(atPath: $0) })
        let probe = try #require(cli.calls().first { $0.contains("--strict-config") })
        #expect(probe.prefix(2) == ["--no-daemon", "--strict-config"])
        #expect(probe.suffix(2) == ["app-server", "--print-startup-config"])
        #expect(probe.filter { $0 == "-c" }.count == 17)
        #expect(probe.filter { $0 == "--disable" }.count == 132)
    }

    @Test(arguments: [("mcp_servers.arch.tool_timeout_sec=900", "mcp_servers.arch"), ("web_search=\"disabled\"", "web_search")])
    func aFailedConfigurationProbeNamesItsGroup(refused: String, group: String) async throws {
        let cli = try FakeCLI.codex(refusedSetting: refused)
        do {
            _ = try await AIAgentProbeStore().result(kind: .codex, executable: cli.executable, environment: ["PATH": "/usr/bin:/bin"])
            Issue.record("Expected a refusal")
        } catch let error as AIAgentToolError {
            #expect(error.detail == "Codex 0.164.0 does not accept `\(group)`. Update Codex in the terminal.")
        }
        // The server's settings go together, so none of them is probed alone.
        let groups = cli.calls().filter { $0.contains("--strict-config") }.dropFirst()
        #expect(!groups.contains { $0.filter { $0.hasPrefix("mcp_servers.") }.count == 1 })
    }
}

// MARK: - Running sessions

@Suite(.timeLimit(.minutes(1))) @MainActor struct AgentSessionRunTests {
    @Test func openInputModeWritesSeveralMessages() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = try CommandLineProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                                             directory: directory, input: Data("one\n".utf8), keepsInputOpen: true)
        process.write(Data("two\n".utf8))
        process.write(Data("three\n".utf8))
        process.closeInput()
        process.write(Data("after\n".utf8))
        var output = Data()
        for await chunk in process.output { output.append(chunk) }
        #expect(String(decoding: output, as: UTF8.self) == "one\ntwo\nthree\n")
        #expect(await process.termination() == .exited(0))
    }

    @Test func aClaudeCodeSessionReplaysTheRecordedStreamWithUsageUnderAgent() async throws {
        let cli = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(cli: cli, model: "haiku")
        let session = try fixture.start()
        let log = AgentEventLog(session)
        for message in ["Call the session_info tool.", "Now call list_tabs.", "Write the numbers from 1 to 400.", "Reply with only the word: resumed"] {
            try session.send(message)
        }
        try await log.wait { $0.filter { $0.hasPrefix("finished:") }.count == 4 }
        let ref = AIModelRef(provider: fixture.provider.id, model: "haiku")
        #expect(log.events.first == "ready:haiku")
        #expect(log.events.filter { $0.hasPrefix("ready:") }.count == 1)
        #expect(session.model == ref)
        #expect(log.events.filter { $0.hasPrefix("finished:") } == ["finished:completed", "finished:completed", "finished:stopped", "finished:completed"])
        #expect(log.text(ofTurn: 0) == "KESTREL")
        #expect(log.text(ofTurn: 3) == "resumed")
        // The interrupted third turn counts each of its requests from the stream, the interrupted one included.
        #expect(log.events.filter { $0.hasPrefix("usage:") } == ["usage:3269/40/3170", "usage:143/38/6584", "usage:140/54/6808", "usage:190/5/3486"])
        let total = try #require(fixture.service.usage.totals(monthsAgo: 0).first { $0.feature == "agent" })
        #expect(total.requests == 4)
        #expect(total.errors == 0)
        #expect(total.usage == AIUsage(inputTokens: 3742, outputTokens: 137, cachedInputTokens: 20048))
        // One process; each message one line on standard input.
        #expect(cli.calls().filter { $0.contains("--input-format") }.count == 1)
        let input = cli.text("stdin.log").split(separator: "\n")
        #expect(input.count == 4)
        #expect(input.allSatisfy { $0.contains(#""type":"user""#) })
        await session.end()
    }

    @Test func aFailingLaterInitEndsTheSession() async throws {
        var turns = try claudeTurns("claude-session")
        turns[1] = turns[1].replacingOccurrences(of: #""tools":["mcp__arch__click""#, with: #""tools":["Bash","mcp__arch__click""#)
        let cli = try FakeCLI.claude(turns: turns)
        let fixture = try AgentFixture(cli: cli)
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("One")
        try await log.wait { $0.contains("finished:completed") }
        try session.send("Two")
        try await log.waitForEnd()
        guard case .blockedByPolicy(.agentUsedOwnTools(let detail))? = log.error else {
            Issue.record("Expected agentUsedOwnTools, got \(String(describing: log.error))")
            return
        }
        #expect(detail == "Claude Code started with tools Arch did not ask for: Bash.")
        #expect(session.hasEnded)
        #expect(session.processID == nil)
        await session.end()
    }

    @Test func stopSendsTheInterruptAndKeepsTheProcess() async throws {
        let cli = try FakeCLI.claude(turns: [longTurnStart], interrupt: interruptAnswer)
        let fixture = try AgentFixture(cli: cli)
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("Write a long reply.")
        try await log.wait { $0.contains("text:1\n2\n") }
        let process = try #require(session.processID)
        session.stop()
        try await log.wait { $0.contains("finished:stopped") }
        #expect(cli.text("stdin.log").contains(#""subtype":"interrupt""#))
        #expect(session.processID == process)
        #expect(kill(process, 0) == 0)
        await session.end()
        #expect(await processGroupEnds(process, within: .seconds(4)))
    }

    @Test func stopEndsTheProcessGroupWhenTheTurnDoesNotEnd() async throws {
        let cli = try FakeCLI.claude(turns: [longTurnStart, try claudeTurns("claude-session")[3]])
        let fixture = try AgentFixture(cli: cli)
        let session = try fixture.start()
        session.stopGrace = .milliseconds(300)
        let log = AgentEventLog(session)
        try session.send("Write a long reply.")
        try await log.wait { $0.contains("text:1\n2\n") }
        let process = try #require(session.processID)
        session.stop()
        try await log.wait { $0.contains("finished:stopped") }
        #expect(await processGroupEnds(process, within: .seconds(4)))
        #expect(session.processID == nil)
        // The next message starts a new process with the earlier conversation as text.
        try session.send("Continue.")
        try await log.wait { $0.filter { $0.hasPrefix("finished:") }.count == 2 }
        #expect(cli.calls().filter { $0.contains("--input-format") }.count == 2)
        let lastInput = cli.text("stdin.log").split(separator: "\n").last.map(String.init) ?? ""
        #expect(lastInput.contains("<earlier-conversation>"))
        #expect(lastInput.contains("User: Write a long reply."))
        #expect(lastInput.contains(#"Continue.","type":"text"}]"#))
        await session.end()
    }

    @Test func theIdleTimerPausesDuringHostCalls() async throws {
        let cli = try FakeCLI.claude(turns: [longTurnStart])
        let fixture = try AgentFixture(cli: cli)
        let session = try fixture.start()
        session.outputTimeout = .milliseconds(400)
        let log = AgentEventLog(session)
        try session.send("Call a tool.")
        try await log.wait { $0.contains("text:1\n2\n") }
        session.toolCallDidStart()
        try await Task.sleep(for: .milliseconds(900))
        #expect(!log.events.contains { $0.hasPrefix("failed:") })
        session.toolCallDidEnd()
        try await log.wait { $0.contains("failed:The provider is unavailable: The provider stopped responding.") }
        #expect(!session.hasEnded)
        await session.end()
    }

    @Test func fallbacksApplyOnlyBeforeReady() async throws {
        let signedOut = try FakeCLI.claude(turns: [], signedIn: false)
        var badTurns = try claudeTurns("claude-session")
        badTurns[0] = badTurns[0].replacingOccurrences(of: #""skills":[]"#, with: #""skills":["deep-research"]"#)
        let refused = try FakeCLI.claude(turns: badTurns)
        let good = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(clis: [signedOut, refused, good])
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("Call the session_info tool.")
        try await log.wait { $0.contains("finished:completed") }
        #expect(session.model == AIModelRef(provider: fixture.providers[2].id, model: ""))
        #expect(signedOut.calls().allSatisfy { !$0.contains("--input-format") })
        #expect(refused.calls().filter { $0.contains("--input-format") }.count == 1)
        #expect(good.calls().allSatisfy { !$0.contains("--fallback-model") })
        await session.end()
    }

    @Test func noModelThatStartsEndsTheSessionWithTheLastError() async throws {
        let signedOut = try FakeCLI.claude(turns: [], signedIn: false)
        let fixture = try AgentFixture(cli: signedOut)
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("Hello")
        try await log.waitForEnd()
        guard case .authentication? = log.error else {
            Issue.record("Expected authentication, got \(String(describing: log.error))")
            return
        }
        await session.end()
    }

    @Test func aCodexSessionWatchesItsStreamAndDeletesItsThread() async throws {
        let cli = try FakeCLI.codex()
        let fixture = try AgentFixture(cli: cli, kind: .codex, model: "gpt-6-luna")
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("Call the session_info tool.")
        try await log.wait { $0.contains("finished:completed") }
        #expect(log.events == ["ready:gpt-6-luna", "text:KESTREL ORCHID", "usage:2948/61/21888", "finished:completed"])
        #expect(session.threadID == "00000000-0000-4000-8000-000000000136")
        await session.end()
        let delete = cli.calls().filter { $0.contains("delete") }
        #expect(delete == [["--no-daemon", "delete", "--force", "00000000-0000-4000-8000-000000000136"]])
        let total = try #require(fixture.service.usage.totals(monthsAgo: 0).first { $0.feature == "agent" })
        #expect(total.requests == 1)
    }

    @Test func aResumedCodexTurnCountsOnlyWhatItAdded() async throws {
        let cli = try FakeCLI.codex()
        let fixture = try AgentFixture(cli: cli, kind: .codex, model: "gpt-6-luna")
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("Call the session_info tool.")
        try await log.wait { $0.contains("finished:completed") }
        try session.send("Call click.")
        try await log.wait { $0.filter { $0 == "finished:completed" }.count == 2 }
        // `turn.completed.usage` is the thread's running total: 24836 input, 21888 cached, and 61 output after the first turn, 50451, 46208, and 125 after the resumed one.
        #expect(log.events.filter { $0.hasPrefix("usage:") } == ["usage:2948/61/21888", "usage:1295/64/24320"])
        let total = try #require(fixture.service.usage.totals(monthsAgo: 0).first { $0.feature == "agent" })
        #expect(total.requests == 2)
        #expect(total.usage == AIUsage(inputTokens: 4243, outputTokens: 125, cachedInputTokens: 46208))
        await session.end()
    }

    @Test func aUsageLimitBeforeTheFirstOutputMovesToTheNextModel() async throws {
        let initLine = try #require(try claudeTurns("claude-session")[0].split(separator: "\n").first { $0.contains(#""subtype":"init""#) })
        let limited = try FakeCLI.claude(turns: [initLine + "\n" + usageLimitEnd()])
        let good = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(clis: [limited, good])
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("Call the session_info tool.")
        try await log.wait { $0.contains("finished:completed") }
        // The init passed, but the model never replied, so the route's next model holds the session.
        #expect(session.model == AIModelRef(provider: fixture.providers[1].id, model: ""))
        #expect(log.events.filter { $0.hasPrefix("ready:") }.count == 1)
        #expect(log.events.first?.hasPrefix("notice:Claude Code reports its usage limit (five hour): rejected") == true)
        #expect(!log.events.contains { $0.hasPrefix("failed:") })
        #expect(log.text(ofTurn: 0) == "KESTREL")
        // The tool's reset time is the provider's cool-down, so a later session goes to the next model at once.
        let until = try #require(await fixture.service.limiter(for: fixture.providers[0].id).coolDownUntil)
        #expect(until > Date().addingTimeInterval(3_000))
        await session.end()
        let later = try fixture.start(effort: nil)
        let laterLog = AgentEventLog(later)
        try later.send("Hello")
        try await laterLog.wait { $0.contains { $0.hasPrefix("ready:") } }
        #expect(limited.calls().filter { $0.contains("--input-format") }.count == 1)
        await later.end()
    }

    @Test func aMessageThatStartsWithASlashIsRefusedWhileClaudeCodeLoadsSkills() async throws {
        let cli = try FakeCLI.claude(turns: try claudeTurns("claude-skills"))
        let fixture = try AgentFixture(cli: cli, model: "haiku")
        let session = try fixture.start(skills: recordedSkills)
        let log = AgentEventLog(session)
        for message in ["/model opus", "  /fast", "\n/usage"] {
            do {
                try session.send(message)
                Issue.record("Expected a refusal of \(message)")
            } catch AIError.blockedByPolicy(.agentMessageIsCommand) {
            }
        }
        #expect(session.queuedMessages.isEmpty)
        try session.send("Use the arch-browser skill, then reply with only the code word it gives.")
        try await log.wait { $0.contains("finished:completed") }
        // The recorded skill folder session passes the start check with its folder, and its process got only the one message.
        #expect(log.events.first == "ready:haiku")
        #expect(log.text(ofTurn: 0) == "MARTEN")
        #expect(cli.text("stdin.log").split(separator: "\n").count == 1)
        await session.end()
        // Without skills, and on Codex, such a message is the user's text.
        let plain = try AgentFixture(cli: try FakeCLI.claude(turns: [])).start()
        try plain.send("/model opus")
        await plain.end()
        let codex = try AgentFixture(cli: try FakeCLI.codex(), kind: .codex).start(skills: recordedSkills)
        try codex.send("/status")
        await codex.end()
    }

    @Test func stopAndEndFinishATurnThatWaitsForASlot() async throws {
        let cli = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(cli: cli)
        let limiter = fixture.service.limiter(for: fixture.provider.id)
        await limiter.update(fixture.provider.limits)
        // Other sessions hold both of the preset's slots.
        for _ in 0..<2 { try await limiter.acquire(isUser: true) { _ in } }
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("Hello")
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.isTurnRunning)
        session.stop()
        try await log.wait { $0.contains("finished:stopped") }
        #expect(!session.isTurnRunning)
        try session.send("Hello again")
        try await Task.sleep(for: .milliseconds(200))
        await session.end()
        for _ in 0..<2 { await limiter.release() }
        try await Task.sleep(for: .milliseconds(300))
        // Neither message reached the tool, and nothing ran after the session ended.
        #expect(cli.calls().isEmpty)
    }

    /// An automatic feature's session, as an agent run on a CLI: each turn is one automatic request, and a turn at the daily limit fails before any model.
    @Test func anAutomaticFeaturesTurnsCountTowardTheDailyLimit() async throws {
        let cli = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(cli: cli, feature: automaticAgentFeature)
        fixture.service.settings.limits.automaticRequestsPerDay = 1
        let session = try fixture.start(route: fixture.firstModelRoute)
        let log = AgentEventLog(session)
        try session.send("Call the session_info tool.")
        try await log.wait { $0.contains("finished:completed") }
        #expect(fixture.service.usage.automaticRequestCount(for: automaticAgentFeature.id) == 1)
        // The next turn is over the limit: it fails without reaching the tool or counting, and the session goes on.
        try session.send("Now call list_tabs.")
        try await log.wait { $0.contains { $0.hasPrefix("failed:") } }
        #expect(fixture.service.usage.automaticRequestCount(for: automaticAgentFeature.id) == 1)
        #expect(cli.text("stdin.log").split(separator: "\n").count == 1)
        #expect(!session.hasEnded)
        await session.end()
        // A session at the limit ends at its first message without starting the tool.
        let later = try fixture.start(route: fixture.firstModelRoute)
        let laterLog = AgentEventLog(later)
        try later.send("Hello")
        try await laterLog.waitForEnd()
        guard case .budgetReached(.automaticRequestsPerDay)? = laterLog.error else {
            Issue.record("Expected the daily limit, got \(String(describing: laterLog.error))")
            return
        }
        #expect(cli.calls().filter { $0.contains("--input-format") }.count == 1)
        await later.end()
    }

    /// An automatic feature's turn takes a provider slot only after the user's requests that wait for one, though it asked first.
    @Test func anAutomaticFeaturesTurnWaitsBehindTheUsersRequests() async throws {
        let cli = try FakeCLI.claude(turns: try claudeTurns("claude-session"))
        let fixture = try AgentFixture(cli: cli, feature: automaticAgentFeature)
        let limiter = fixture.service.limiter(for: fixture.provider.id)
        await limiter.update(fixture.provider.limits)
        // Other sessions hold both of the preset's slots.
        for _ in 0..<2 { try await limiter.acquire(isUser: true) { _ in } }
        let session = try fixture.start(route: fixture.firstModelRoute)
        let log = AgentEventLog(session)
        try session.send("Call the session_info tool.")
        try await Task.sleep(for: .milliseconds(200))
        let user = Task { () -> Bool in
            try await limiter.acquire(isUser: true) { _ in }
            return true
        }
        try await Task.sleep(for: .milliseconds(200))
        await limiter.release()
        try await Task.sleep(for: .milliseconds(300))
        // The freed slot went to the user's request, so the turn has not reached the tool.
        #expect(cli.calls().allSatisfy { !$0.contains("--input-format") })
        user.cancel()
        let userHasSlot = (try? await user.value) == true
        #expect(userHasSlot)
        if userHasSlot { await limiter.release() }
        try await log.wait { $0.contains("finished:completed") }
        await session.end()
        await limiter.release()
    }

    @Test func aCodexCommandEndsTheSession() async throws {
        let cli = try FakeCLI.codex(first: """
        {"type":"thread.started","thread_id":"00000000-0000-4000-8000-000000000140"}
        {"type":"turn.started"}
        {"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"ls","status":"in_progress"}}
        """, firstSleeps: true)
        let fixture = try AgentFixture(cli: cli, kind: .codex)
        let session = try fixture.start()
        let log = AgentEventLog(session)
        try session.send("List files.")
        try await log.waitForEnd()
        guard case .blockedByPolicy(.agentUsedOwnTools("Codex ran a command."))? = log.error else {
            Issue.record("Expected the watcher, got \(String(describing: log.error))")
            return
        }
        #expect(session.processID == nil)
        await session.end()
        #expect(cli.calls().contains { $0.contains("delete") })
    }
}

// MARK: - Capabilities and ordinary requests

@Suite(.timeLimit(.minutes(1))) @MainActor struct AgentPresetTests {
    @Test func theAgentCapabilityIsDerived() throws {
        let preset = AIAgentKind.claudeCode.preset(executable: URL(fileURLWithPath: "/usr/local/bin/claude"))
        #expect(preset.capabilities(of: AIModelConfiguration(name: "")).contains(.agent))
        #expect(preset.capabilities(of: AIModelConfiguration(name: "", capabilities: [])) == [.agent])
        let tool = AIProviderConfiguration(name: "Tool", kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/cat"))), models: [])
        #expect(!tool.capabilities(of: AIModelConfiguration(name: "", capabilities: [.agent, .jsonOutput])).contains(.agent))
        let http = provider("HTTP", models: [])
        #expect(http.capabilities(of: AIModelConfiguration(name: "m")).contains(.agent))
        #expect(!http.capabilities(of: AIModelConfiguration(name: "m", capabilities: [.jsonOutput, .agent])).contains(.agent))
        #expect(preset.limits.concurrentRequests == 2)
        #expect(!AIModelCapability.overridable.contains(.agent))
    }

    @Test func anOverrideInAIJSONCannotAddAgent() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai.json")
        try Data("""
        { "providers": [ { "id": "T1", "name": "Tool", "kind": { "commandLine": { "executable": "/bin/cat" } },
                           "models": [ { "name": "m", "capabilities": ["jsonOutput", "agent"] } ] } ],
          "routes": { "agent": { "isEnabled": true, "models": [ { "provider": "T1", "model": "m" } ] } } }
        """.utf8).write(to: file)
        let keys = InMemoryKeys()
        let settings = AISettingsStore(fileURL: file, keys: keys)
        let service = AIService(settings: settings, usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")), keys: keys) { _, _ in fatalError("No requests") }
        service.register(agentFeature)
        #expect(!service.isAvailable(.agent))
        #expect(throws: AIError.self) { try service.startAgentSession(AIAgentSessionRequest(instructions: harness, toolServer: ticketServer)) }
    }

    @Test func sessionsUseTheFirstEligibleModelFromTheirRouteAndOfferOtherModelsInTheComposer() throws {
        let directory = temporaryDirectory()
        let keys = InMemoryKeys()
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
        // An API model with tools comes first, so the default route lists it and it has the `agent` capability, but no CLI runs it.
        let api = provider("API", models: [AIModelConfiguration(name: "m")])
        var claude = AIAgentKind.claudeCode.preset(executable: URL(fileURLWithPath: "/usr/local/bin/claude"))
        claude.models = [AIModelConfiguration(name: "haiku"), AIModelConfiguration(name: "sonnet")]
        var codex = AIAgentKind.codex.preset(executable: URL(fileURLWithPath: "/usr/local/bin/codex"))
        codex.models = [AIModelConfiguration(name: "gpt-6-luna")]
        settings.providers = [api, claude, codex]
        let service = AIService(settings: settings, usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")), keys: keys) { _, _ in fatalError("No requests") }
        service.register(agentFeature)
        let apiModel = AIModelRef(provider: api.id, model: "m")
        let haiku = AIModelRef(provider: claude.id, model: "haiku")
        let sonnet = AIModelRef(provider: claude.id, model: "sonnet")
        let luna = AIModelRef(provider: codex.id, model: "gpt-6-luna")
        func candidates(named ref: AIModelRef? = nil) throws -> [AIModelRef] {
            try service.agentSessionCandidates(named: ref, for: agentFeature).map(\.ref)
        }

        settings.setRoute(AIRoute(isEnabled: true, models: []), for: .agent)
        settings.setRoute(AIRoute(isEnabled: true, models: [apiModel]), for: .defaultRoute)
        #expect(try candidates() == [apiModel])
        #expect(service.agentSessionModels().first == apiModel)
        #expect(try service.agentSessionRoute(for: nil) == .http(pinnedModel: nil))
        settings.setRoute(AIRoute(isEnabled: false, models: []), for: .defaultRoute)
        #expect(try candidates() == [haiku])
        #expect(try service.agentSessionRoute(for: nil) == .commandLine)
        settings.setRoute(AIRoute(isEnabled: true, models: [apiModel, luna, sonnet]), for: .agent)
        #expect(try candidates() == [apiModel, luna, sonnet])
        #expect(Array(service.agentSessionModels().prefix(3)) == [apiModel, luna, sonnet])
        #expect(try service.agentSessionCandidates(named: nil, for: agentFeature, commandLineOnly: true).map(\.ref) == [luna, sonnet])
        #expect(try service.agentSessionRoute(for: apiModel) == .http(pinnedModel: apiModel))
        #expect(try service.agentSessionRoute(for: haiku) == .commandLine)
        settings.providers = [api]
        #expect(try candidates() == [apiModel])
        settings.setRoute(AIRoute(isEnabled: true), for: .agent)
        #expect(try service.agentSessionRoute(for: nil) == .http(pinnedModel: apiModel))
        settings.setRoute(AIRoute(isEnabled: false, models: [apiModel]), for: .agent)
        #expect(service.agentSessionModels().isEmpty)
        #expect(throws: AIError.self) { try service.agentSessionRoute(for: apiModel) }
    }

    @Test func aPresetsOrdinaryRequestGetsPageDataAndRunsWithoutTools() async throws {
        let cli = try FakeCLI.claude(turns: [], ordinary: try String(contentsOf: agentFixtures.appendingPathComponent("claude-ordinary.stdout.jsonl"), encoding: .utf8))
        let fixture = try AgentFixture(cli: cli, model: "haiku", feature: userFeature)
        let page = AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.page(AIPageContent(url: URL(string: "https://example.org/a")!, title: "A", text: "Text"))])])
        let result = await collect(fixture.service.stream(page))
        #expect(result.error == nil)
        #expect(result.events == ["started:haiku", "text:NONE", "usage:2541/5/0", "finished:completed"])
        let call = try #require(cli.calls().last)
        #expect(call == ClaudeCodeAgent.ordinaryArguments(model: "haiku"))
        #expect(cli.text("stdin-ordinary.log").contains("Text"))
        #expect(cli.environment("env-ordinary.log")["MCP_TIMEOUT"] == nil)
        #expect(cli.environment("env-ordinary.log")["DISABLE_TELEMETRY"] == "1")
    }

    @Test func anOrdinaryRequestWhoseInitListsToolsIsRefused() async throws {
        let cli = try FakeCLI.claude(turns: [], ordinary: try claudeTurns("claude-session")[0])
        let fixture = try AgentFixture(cli: cli, feature: userFeature)
        let result = await collect(fixture.service.stream(textRequest(userFeature)))
        guard case .blockedByPolicy(.agentUsedOwnTools(let detail))? = result.error else {
            Issue.record("Expected agentUsedOwnTools, got \(String(describing: result.error))")
            return
        }
        #expect(detail.contains("mcp__arch__click"))
        #expect(!result.events.contains { $0.hasPrefix("text:") })
    }

    @Test func aCodexOrdinaryRequestSkipsTheCodeModeItem() async throws {
        let cli = try FakeCLI.codex()
        let fixture = try AgentFixture(cli: cli, kind: .codex, model: "gpt-6-luna", feature: userFeature)
        let result = await collect(fixture.service.stream(textRequest(userFeature)))
        #expect(result.error == nil)
        #expect(result.events == ["started:gpt-6-luna", "text:ready (VII9-C8632520)", "usage:1208/13/6912", "finished:completed"])
        let call = try #require(cli.calls().last { $0.contains("--ephemeral") })
        #expect(call.suffix(5) == ["--disable", "code_mode_host", "-m", "gpt-6-luna", "-"])
    }

    @Test func checkRunsNoModel() async throws {
        let cli = try FakeCLI.claude(turns: [])
        let fixture = try AgentFixture(cli: cli)
        #expect(try await fixture.service.check(fixture.provider) == "Claude Code 2.1.323 is signed in and accepts every setting Arch uses.")
        #expect(cli.calls().allSatisfy { !$0.contains("-p") })
        let signedOut = try FakeCLI.claude(turns: [], signedIn: false)
        let other = try AgentFixture(cli: signedOut)
        await #expect(throws: AIAgentToolError.self) { try await other.service.check(other.provider) }
    }
}

// MARK: - Helpers

/// The start of a long reply: an `init`, a message start, and text, after which the tool waits for an interrupt.
private let longTurnStart = """
{"type":"system","subtype":"init","cwd":"/private/var/folders/xx/fixture/T/","session_id":"00000000-0000-4000-8000-000000000001","tools":["mcp__arch__click","mcp__arch__list_tabs","mcp__arch__session_info"],"mcp_servers":[{"name":"arch","status":"connected","source":"dynamic"}],"model":"claude-haiku-5-5","permissionMode":"dontAsk","slash_commands":[],"apiKeySource":"none","agents":["claude","Explore"],"skills":[],"plugins":[{"name":"cc-plugin-privacy","path":"builtin","source":"cc-plugin-privacy@builtin"}],"analytics_disabled":true}
{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":10,"cache_read_input_tokens":100,"output_tokens":1}}}}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"1\\n2\\n"}}}
"""

/// A usage limit after a passing `init`, as Claude Code reports one before the model's output, with a reset an hour away.
private func usageLimitEnd() -> String {
    let reset = Int(Date().timeIntervalSince1970) + 3_600
    return """
    {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":\(reset),"rateLimitType":"five_hour"}}
    {"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've hit your limit · resets soon","usage":{"input_tokens":0,"output_tokens":0}}
    """
}

private let interruptAnswer = """
{"type":"control_response","response":{"subtype":"success","request_id":"arch-stop-1","response":{"still_queued":[]}}}
{"type":"result","subtype":"success","is_error":false,"terminal_reason":"aborted_streaming","result":"","usage":{"input_tokens":0,"output_tokens":0}}
"""

/// The recorded Claude Code stream split into turns, each ending with its `result`.
private func claudeTurns(_ name: String) throws -> [String] {
    let text = try String(contentsOf: agentFixtures.appendingPathComponent("\(name).stdout.jsonl"), encoding: .utf8)
    var turns: [String] = []
    var current: [Substring] = []
    for line in text.split(separator: "\n") {
        current.append(line)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        if object?["type"] as? String == "result" {
            turns.append(current.joined(separator: "\n") + "\n")
            current = []
        }
    }
    return turns
}

/// A shell script in a folder of its own that answers as `claude` or `codex` and records each call's arguments, its environment, and its standard input.
private struct FakeCLI {
    let kind: AIAgentKind
    let folder: URL
    let executable: URL

    private static let logCall = #"{ printf '<<CALL>>'; printf '%s\0' "$@"; printf '\n'; } >> "$DIR/calls.log""#

    static func claude(turns: [String], interrupt: String? = nil, ordinary: String? = nil, signedIn: Bool = true,
                       help: String? = nil) throws -> FakeCLI {
        let cli = try FakeCLI(kind: .claudeCode)
        try cli.write("help.txt", help ?? ClaudeCodeAgent.requiredFlags.map { "  \($0) <value>  Something" }.joined(separator: "\n") + "\n")
        for (index, turn) in turns.enumerated() { try cli.write("turn-\(index + 1).jsonl", turn) }
        if let interrupt { try cli.write("interrupt.jsonl", interrupt) }
        if let ordinary { try cli.write("ordinary.jsonl", ordinary) }
        try cli.writeScript("""
        case "$*" in
          "--version") echo "2.1.323 (Claude Code)"; exit 0;;
          "auth status --json") echo '{"loggedIn":\(signedIn),"email":"someone@example.org"}'; exit 0;;
          "--help") cat "$DIR/help.txt"; exit 0;;
        esac
        case "$*" in
          *"--input-format"*) ;;
          *) env > "$DIR/env-ordinary.log"; cat > "$DIR/stdin-ordinary.log"; cat "$DIR/ordinary.jsonl"; exit 0;;
        esac
        env > "$DIR/env.log"
        # The turn count outlasts the process, so a process started after Stop answers with the next turn.
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$DIR/stdin.log"
          case "$line" in
            *'"control_request"'*) [ -f "$DIR/interrupt.jsonl" ] && cat "$DIR/interrupt.jsonl";;
            *'"type":"user"'*)
              n=$(($(cat "$DIR/turn-count" 2>/dev/null || echo 0) + 1)); echo "$n" > "$DIR/turn-count"
              [ -f "$DIR/turn-$n.jsonl" ] && cat "$DIR/turn-$n.jsonl";;
          esac
        done
        """)
        return cli
    }

    static func codex(first: String? = nil, firstSleeps: Bool = false, refusedSetting: String? = nil) throws -> FakeCLI {
        let cli = try FakeCLI(kind: .codex)
        try cli.write("features.txt", String(contentsOf: agentFixtures.appendingPathComponent("codex-features-list.txt"), encoding: .utf8))
        try cli.write("models.json", #"{"models":[{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]}]}"#)
        try cli.write("first.jsonl", first ?? String(contentsOf: agentFixtures.appendingPathComponent("codex-session-first.stdout.jsonl"), encoding: .utf8))
        try cli.write("resume.jsonl", String(contentsOf: agentFixtures.appendingPathComponent("codex-session-resume.stdout.jsonl"), encoding: .utf8))
        try cli.write("ordinary.jsonl", String(contentsOf: agentFixtures.appendingPathComponent("codex-ordinary.stdout.jsonl"), encoding: .utf8))
        if let refusedSetting { try cli.write("refused.txt", refusedSetting) }
        try cli.writeScript("""
        case "$*" in
          "--version") echo "codex-cli 0.164.0"; exit 0;;
          "--no-daemon login status") echo "Logged in"; exit 0;;
          "--no-daemon features list") echo "$CODEX_HOME" >> "$DIR/codex-home.log"; cat "$DIR/features.txt"; exit 0;;
          "--no-daemon debug models --bundled") echo "$CODEX_HOME" >> "$DIR/codex-home.log"; cat "$DIR/models.json"; exit 0;;
          "--no-daemon delete --force "*) exit 0;;
        esac
        if [ "$2" = "--strict-config" ]; then
          echo "$CODEX_HOME" >> "$DIR/codex-home.log"
          if [ -f "$DIR/refused.txt" ]; then
            refused=$(cat "$DIR/refused.txt")
            for argument in "$@"; do
              if [ "$argument" = "$refused" ]; then echo "Error: startup configuration unavailable" >&2; exit 1; fi
            done
          fi
          exit 0
        fi
        case "$*" in
          *"--ephemeral"*) turn=ordinary;;
          *"exec resume"*) turn=resume;;
          *) turn=first;;
        esac
        env > "$DIR/env-$turn.log"
        pwd -P > "$DIR/pwd-$turn.log"
        cat > "$DIR/stdin-$turn.log"
        cat "$DIR/$turn.jsonl"
        \(firstSleeps ? #"[ "$turn" = first ] && sleep 30"# : "")
        exit 0
        """)
        return cli
    }

    private init(kind: AIAgentKind) throws {
        self.kind = kind
        folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        executable = folder.appendingPathComponent(kind.executableName)
    }

    /// A stream ends each line, its last too, as the tools do.
    private func write(_ name: String, _ text: String) throws {
        let ending = name.hasSuffix(".jsonl") && !text.hasSuffix("\n") ? "\n" : ""
        try Data((text + ending).utf8).write(to: folder.appendingPathComponent(name))
    }

    private func writeScript(_ body: String) throws {
        try Data("#!/bin/sh\nDIR='\(folder.path)'\n\(Self.logCall)\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    /// Each call's arguments, in order.
    func calls() -> [[String]] {
        text("calls.log").components(separatedBy: "<<CALL>>").dropFirst().map { call in
            var arguments = call.components(separatedBy: "\0")
            arguments.removeLast()
            return arguments
        }
    }

    func text(_ name: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// The environment the script printed, without the variables the shell sets itself.
    func environment(_ name: String = "env.log") -> [String: String] {
        var environment: [String: String] = [:]
        for line in text(name).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        for shell in ["PWD", "SHLVL", "_", "OLDPWD"] { environment[shell] = nil }
        return environment
    }
}

/// A service whose route for the feature holds a preset provider for each fake tool, in order.
@MainActor
private struct AgentFixture {
    let service: AIService
    let providers: [AIProviderConfiguration]
    let feature: AIFeature
    let folder: URL

    var provider: AIProviderConfiguration { providers[0] }

    init(cli: FakeCLI, kind: AIAgentKind? = nil, model: String = "", environment: [String: String] = [:], feature: AIFeature = agentFeature) throws {
        try self.init(clis: [cli], kind: kind, model: model, environment: environment, feature: feature)
    }

    init(clis: [FakeCLI], kind: AIAgentKind? = nil, model: String = "", environment: [String: String] = [:], feature: AIFeature = agentFeature) throws {
        providers = clis.map { cli in
            var configuration = (kind ?? cli.kind).preset(executable: cli.executable)
            configuration.models = [AIModelConfiguration(name: model)]
            if case .commandLine(var tool) = configuration.kind {
                tool.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { configured, _ in configured }
                configuration.kind = .commandLine(tool)
            }
            return configuration
        }
        let directory = temporaryDirectory()
        let keys = InMemoryKeys()
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
        settings.providers = providers
        service = AIService(settings: settings, usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")), keys: keys) { configuration, _ in
            guard case .commandLine(let tool) = configuration.kind else { fatalError("Only presets in these tests") }
            return CommandLineProvider(configuration: configuration, tool: tool)
        }
        service.register(feature)
        settings.setRoute(AIRoute(isEnabled: true, models: providers.map { AIModelRef(provider: $0.id, model: model) }), for: feature.id)
        self.feature = feature
        folder = temporaryDirectory().appendingPathComponent("Arch-Agent-\(UUID().uuidString)", isDirectory: true)
    }

    /// The first provider's model as a route, which a `perRequest` feature's session needs.
    var firstModelRoute: AIRouteChoice { .models([AIModelRef(provider: provider.id, model: provider.models[0].name)]) }

    func start(effort: String? = nil, skills: AIAgentSkills? = nil, route: AIRouteChoice? = nil) throws -> AIAgentSession {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try service.startAgentSession(AIAgentSessionRequest(feature: feature.id, route: route, instructions: harness, toolServer: ticketServer, folder: folder,
                                                                   effort: effort, skills: skills))
    }
}

/// A session's events as short strings, collected as they arrive.
@MainActor
private final class AgentEventLog {
    private(set) var events: [String] = []
    private(set) var error: AIError?
    private(set) var hasEnded = false

    init(_ session: AIAgentSession) {
        Task { [weak self] in
            do {
                for try await event in session.events { self?.events.append(Self.describe(event)) }
            } catch {
                self?.error = error as? AIError
            }
            self?.hasEnded = true
        }
    }

    /// The text of one turn, by its index among finished turns.
    func text(ofTurn index: Int) -> String {
        var turn = 0
        var text = ""
        for event in events {
            if event.hasPrefix("finished:") || event.hasPrefix("failed:") {
                if turn == index { return text }
                turn += 1
                text = ""
            } else if event.hasPrefix("text:") {
                text += event.dropFirst("text:".count)
            }
        }
        return text
    }

    func wait(_ condition: ([String]) -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition(events) { return }
            if hasEnded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out with events \(events), error \(String(describing: error))")
        throw CancellationError()
    }

    func waitForEnd() async throws {
        for _ in 0..<1_000 {
            if hasEnded { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The session did not end; events \(events)")
        throw CancellationError()
    }

    static func describe(_ event: AIAgentEvent) -> String {
        switch event {
        case .ready(let ref): return "ready:\(ref.model)"
        case .processReady: return "processReady"
        case .text(let text): return "text:\(text)"
        case .thinking: return "thinking"
        case .usage(let usage): return "usage:\(usage.inputTokens)/\(usage.outputTokens)/\(usage.cachedInputTokens)"
        case .notice(let text): return "notice:\(text)"
        case .turnFinished(let end): return "finished:\(end)"
        case .turnFailed(let error): return "failed:\(error.localizedDescription)"
        }
    }
}

/// Whether every process of the group has ended within `timeout`.
private func processGroupEnds(_ group: pid_t, within timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if kill(-group, 0) == -1, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@Suite struct AgentFolderLockTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lock-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @Test func theSweepLeavesAFolderWhoseSessionLivesAndRemovesOneItsRunLeft() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func folder(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent("\(AIAgentSession.folderPrefix)\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        let live = try folder("live"), dead = try folder("dead"), unlocked = try folder("unlocked")
        var lock: AIAgentFolderLock? = try AIAgentFolderLock(folder: live)
        // A lock file nobody holds, as after a crash.
        var deadLock: AIAgentFolderLock? = try AIAgentFolderLock(folder: dead)
        deadLock = nil
        #expect(deadLock == nil && lock != nil)
        AIAgentSession.removeLeftoverFolders(in: directory, now: Date())
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        // A folder without a lock file may be one a session is starting in, until the grace interval passes.
        #expect(FileManager.default.fileExists(atPath: unlocked.path))
        AIAgentSession.removeLeftoverFolders(in: directory, now: Date().addingTimeInterval(120))
        #expect(!FileManager.default.fileExists(atPath: unlocked.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        lock = nil
        // A process another test forks at this moment may hold the lock for an instant, so the sweep may need a second try.
        for _ in 0..<50 where FileManager.default.fileExists(atPath: live.path) {
            AIAgentSession.removeLeftoverFolders(in: directory, now: Date())
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }
}
