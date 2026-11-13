// Command-line providers: the prompt on standard input, plain text and JSON lines output, errors, the environment and working folder, output held open by a background process, timeouts, cancellation that ends the process group, the rule that keeps page data from tools that may run their own tools, the login shell's PATH, and the `ai.json` shape. Shell scripts in temporary folders stand in for real tools.
import Darwin
import Foundation
import Testing
@testable import AI

@Suite struct CommandLineOutputTests {
    @Test func promptGoesToStandardInputNotTheArguments() async throws {
        let provider = commandLineProvider(URL(fileURLWithPath: "/bin/cat"), arguments: ["-u"])
        let result = await collect(provider.stream(providerRequest("Hello")))
        #expect(result.error == nil)
        #expect(replyText(result.events) == "Be brief.\n\nUser:\nHello")
        #expect(result.events.last == "finished:completed")
    }

    @Test func plainTextDropsBlankLinesAtEitherEnd() async throws {
        let tool = try toolScript(#"printf '\n\none\n\n\ntwo\n\n'"#)
        let result = await collect(commandLineProvider(tool).stream(providerRequest()))
        #expect(result.events == ["text:one", "text:\n\n\ntwo", "finished:completed"])
    }

    @Test func charactersSplitBetweenReadsStayWhole() async throws {
        // The three bytes of a Hangul syllable, written in two parts.
        let tool = try toolScript(#"printf '\355\225'; sleep 0.2; printf '\234\n'"#)
        let result = await collect(commandLineProvider(tool).stream(providerRequest()))
        #expect(result.events == ["text:\u{D55C}", "finished:completed"])
    }

    @Test func jsonLinesStreamDeltasAndUsage() async throws {
        let tool = try toolScript("""
        echo 'Starting the session'
        echo '{"type":"delta","delta":{"text":"Hel"},"error":null}'
        echo '{"type":"delta","delta":{"text":"lo"}}'
        echo '{"type":"done","usage":{"input":12,"output":3}}'
        """)
        let paths = AIJSONLinePaths(textDelta: "delta.text", inputTokens: "usage.input", outputTokens: "usage.output", error: "error")
        let result = await collect(commandLineProvider(tool, output: .jsonLines(paths)).stream(providerRequest()))
        #expect(result.events == ["text:Hel", "text:lo", "usage:12/3/0", "finished:completed"])
    }

    @Test func finalTextServesToolsThatReplyOnceAtTheEnd() async throws {
        let tool = try toolScript(#"echo '{"result":{"content":[{"text":"Done"}]}}'"#)
        let paths = AIJSONLinePaths(textDelta: "delta.text", finalText: "result.content.0.text")
        let result = await collect(commandLineProvider(tool, output: .jsonLines(paths)).stream(providerRequest()))
        #expect(result.events == ["text:Done", "finished:completed"])
    }

    @Test func jsonReplyIsAskedForInTheInstructions() async throws {
        let schema = Data(#"{"type":"object"}"#.utf8)
        let result = await collect(commandLineProvider(URL(fileURLWithPath: "/bin/cat")).stream(providerRequest(output: .json(schema: schema))))
        let prompt = replyText(result.events)
        #expect(prompt.hasPrefix("Be brief.\n\nReply with only one JSON value that matches this JSON Schema"))
        #expect(prompt.contains(#"{"type":"object"}"#))
    }

    @Test func modelArgumentsFollowTheModel() {
        let tool = AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/cat"), arguments: ["--print", "--model={model}", "{model}"])
        #expect(tool.arguments(forModel: "model-a") == ["--print", "--model=model-a", "model-a"])
        #expect(tool.arguments(forModel: "") == ["--print"])
    }
}

@Suite struct CommandLineErrorTests {
    @Test func nonzeroExitReportsTheLastLineOfStandardError() async throws {
        let tool = try toolScript("""
        echo partial
        echo 'Checking the sign-in' >&2
        echo 'Please sign in first.' >&2
        exit 3
        """)
        let result = await collect(commandLineProvider(tool).stream(providerRequest()))
        #expect(result.events == ["text:partial"])
        guard case .providerUnavailable(_, let detail) = result.error else {
            Issue.record("Expected providerUnavailable, got \(String(describing: result.error))")
            return
        }
        #expect(detail == "Please sign in first.")
    }

    @Test func anErrorFieldEndsTheRequest() async throws {
        let tool = try toolScript(#"echo '{"error":{"message":"Not signed in"}}'"#)
        let result = await collect(commandLineProvider(tool, output: .jsonLines(AIJSONLinePaths(textDelta: "delta.text", error: "error.message"))).stream(providerRequest()))
        guard case .providerUnavailable(_, "Not signed in") = result.error else {
            Issue.record("Expected providerUnavailable, got \(String(describing: result.error))")
            return
        }
    }

    @Test func exitingWithoutAReplyIsMalformed() async throws {
        let tool = try toolScript("echo '' ; exit 0")
        guard case .malformedReply = await collect(commandLineProvider(tool).stream(providerRequest())).error else {
            Issue.record("Expected malformedReply")
            return
        }
    }

    @Test func aMissingExecutableIsUnavailable() async {
        let result = await collect(commandLineProvider(URL(fileURLWithPath: "/nonexistent/tool")).stream(providerRequest()))
        guard case .providerUnavailable(_, let detail) = result.error else {
            Issue.record("Expected providerUnavailable, got \(String(describing: result.error))")
            return
        }
        #expect(detail.hasPrefix("tool could not start:"))
    }

    @Test func filesThatAreNotTextAreRefused() async {
        var request = providerRequest()
        request.messages[0].parts.append(.file(AIFile(name: "photo.png", mediaType: "image/png", data: Data([0x89, 0x50]))))
        guard case .invalidRequest = await collect(commandLineProvider(URL(fileURLWithPath: "/bin/cat")).stream(request)).error else {
            Issue.record("Expected invalidRequest")
            return
        }
    }
}

/// A tool that a regression leaves running fails its test at the time limit instead of stopping the run.
@Suite(.timeLimit(.minutes(1))) struct CommandLineProcessTests {
    @Test func runsWithASmallEnvironmentInAnEmptyFolderThatIsRemoved() async throws {
        setenv("ARCH_TEST_INHERITED", "1", 1)
        let tool = try toolScript("env; pwd; ls -A | wc -l")
        let result = await collect(commandLineProvider(tool, environment: ["EXTRA": "value"]).stream(providerRequest()))
        let lines = replyText(result.events).components(separatedBy: "\n")
        #expect(lines.contains("TERM=dumb"))
        #expect(lines.contains("EXTRA=value"))
        #expect(lines.contains("PATH=/usr/bin:/bin"))
        #expect(lines.contains("HOME=\(NSHomeDirectory())"))
        #expect(!lines.contains { $0.hasPrefix("ARCH_TEST_INHERITED=") })
        let folder = try #require(lines.dropLast().last)
        #expect(folder.contains("/Arch-"))
        #expect(lines.last?.trimmingCharacters(in: .whitespaces) == "0")
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    /// A tool that exits while a process it started keeps standard output open still ends its reply then, not at the output timeout.
    @Test func aBackgroundProcessDoesNotHoldTheReplyOpen() async throws {
        let pidFile = pidFileURL()
        let tool = try toolScript("echo $$ > \"$PID_FILE\"\necho reply\nsleep 30 &\nexit 0")
        let start = ContinuousClock.now
        let result = await collect(commandLineProvider(tool, environment: ["PID_FILE": pidFile.path]).stream(providerRequest()))
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(result.error == nil)
        #expect(result.events == ["text:reply", "finished:completed"])
        if let group = try? await processGroup(in: pidFile) { kill(-group, SIGKILL) }
    }

    @Test func cancellingEndsTheProcessGroup() async throws {
        let pidFile = pidFileURL()
        // The background sleep is in the same process group.
        let tool = try toolScript("echo $$ > \"$PID_FILE\"\necho started\nsleep 30 &\nwait")
        let stream = commandLineProvider(tool, environment: ["PID_FILE": pidFile.path]).stream(providerRequest())
        let reader = Task { await collect(stream) }
        let group = try await processGroup(in: pidFile)
        reader.cancel()
        // Before the SIGKILL that follows two seconds after SIGTERM.
        #expect(await processGroupEnds(group, within: .seconds(1.5)))
    }

    @Test func aToolThatIgnoresSIGTERMGetsSIGKILL() async throws {
        let pidFile = pidFileURL()
        let tool = try toolScript("trap '' TERM\necho $$ > \"$PID_FILE\"\necho started\nsleep 30")
        let stream = commandLineProvider(tool, environment: ["PID_FILE": pidFile.path]).stream(providerRequest())
        let reader = Task { await collect(stream) }
        let group = try await processGroup(in: pidFile)
        reader.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(kill(-group, 0) == 0)
        #expect(await processGroupEnds(group, within: .seconds(4)))
    }

    @Test func noOutputBeforeTheTimeoutEndsTheTool() async throws {
        let pidFile = pidFileURL()
        let tool = try toolScript("echo $$ > \"$PID_FILE\"\nsleep 30")
        var provider = commandLineProvider(tool, environment: ["PID_FILE": pidFile.path])
        provider.firstOutputTimeout = .milliseconds(300)
        let result = await collect(provider.stream(providerRequest()))
        guard case .providerUnavailable(_, "The provider stopped responding.") = result.error else {
            Issue.record("Expected a timeout, got \(String(describing: result.error))")
            return
        }
        // Under load the timeout can end the tool before it writes its process group; that tool has already ended.
        guard let group = try? await processGroup(in: pidFile) else { return }
        // SIGTERM ends the group, or under load the SIGKILL two seconds later does.
        #expect(await processGroupEnds(group, within: .seconds(4)))
    }
}

@MainActor
@Suite struct CommandLineRoutingTests {
    private let pageRequest = AIRequest(feature: userFeature.id, messages: [AIMessage(role: .user, parts: [.page(AIPageContent(url: URL(string: "https://example.org/a")!, title: "A", text: "Text"))])])

    private func routed(_ providers: [AIProviderConfiguration], log: ProviderLog) -> AIService {
        let service = scriptedService(providers: providers, script: [
            "tool-model": [.event(.text("from tool")), .event(.finished(.completed))],
            "fallback": [.event(.text("from fallback")), .event(.finished(.completed))],
        ], log: log)
        service.register(userFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: providers.map { AIModelRef(provider: $0.id, model: $0.models[0].name) }), for: userFeature.id)
        return service
    }

    @Test func pageDataSkipsToolsThatMayRunTheirOwnTools() async {
        let log = ProviderLog()
        let service = routed([commandLineConfiguration(runsWithoutTools: false)], log: log)
        guard case .blockedByPolicy(.commandLineToolWithPageData) = await collect(service.stream(pageRequest)).error else {
            Issue.record("Expected commandLineToolWithPageData")
            return
        }
        #expect(log.requests.isEmpty)
        #expect(await collect(service.stream(textRequest(userFeature))).events == ["started:tool-model", "text:from tool", "finished:completed"])
    }

    @Test func pageDataGoesToTheFallbackOrToAToolWithoutItsOwnTools() async {
        let fallback = provider("HTTP", models: [AIModelConfiguration(name: "fallback")])
        let skipped = routed([commandLineConfiguration(runsWithoutTools: false), fallback], log: ProviderLog())
        #expect(await collect(skipped.stream(pageRequest)).events == ["started:fallback", "text:from fallback", "finished:completed"])
        let allowed = routed([commandLineConfiguration(runsWithoutTools: true)], log: ProviderLog())
        #expect(await collect(allowed.stream(pageRequest)).events == ["started:tool-model", "text:from tool", "finished:completed"])
    }

    @Test func toolsHaveOnlyJSONReplies() async {
        let service = routed([commandLineConfiguration(runsWithoutTools: true)], log: ProviderLog())
        var feature = userFeature
        feature.requirements = [.tools]
        service.register(feature)
        guard case .notConfigured(.noUsableModel) = await collect(service.stream(textRequest(feature))).error else {
            Issue.record("Expected noUsableModel")
            return
        }
    }

    @Test func serviceRunsARealToolAndChecksIt() async throws {
        let directory = temporaryDirectory()
        let keys = InMemoryKeys()
        let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
        let tool = commandLineProvider(URL(fileURLWithPath: "/bin/cat")).configuration
        settings.providers = [tool]
        let service = AIService(settings: settings, usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")), keys: keys) { configuration, _ in
            guard case .commandLine(let commandLine) = configuration.kind else { fatalError("Only command-line tools in this test") }
            return CommandLineProvider(configuration: configuration, tool: commandLine)
        }
        service.register(userFeature)
        let result = await collect(service.stream(textRequest(userFeature, "Hi")))
        #expect(result.events.first == "started:")
        #expect(replyText(result.events) == "User:\nHi")
        #expect(try await service.check(tool) == "User:\nReply with one short sentence.")
    }
}

@MainActor
@Suite struct CommandLineSettingsTests {
    @Test func savesTheDocumentedShape() throws {
        let store = AISettingsStore(fileURL: temporaryDirectory().appendingPathComponent("ai.json"), keys: InMemoryKeys())
        let text = AIProviderConfiguration(name: "Terminal tool", kind: .commandLine(AICommandLineConfiguration(
            executable: URL(fileURLWithPath: "/usr/local/bin/example-tool"), arguments: ["--print", "--model={model}"])), models: [AIModelConfiguration(name: "")], limits: .commandLine)
        let lines = AIProviderConfiguration(name: "JSON tool", kind: .commandLine(AICommandLineConfiguration(
            executable: URL(fileURLWithPath: "/opt/tools/other"), environment: ["MODE": "quiet"],
            output: .jsonLines(AIJSONLinePaths(textDelta: "delta.text", outputTokens: "usage.output")), runsWithoutTools: true)), limits: .commandLine)
        store.providers = [text, lines]
        store.saveNow()

        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let first = try #require((object["providers"] as? [[String: Any]])?.first)
        let tool = try #require((first["kind"] as? [String: Any])?["commandLine"] as? [String: Any])
        #expect(tool["executable"] as? String == "/usr/local/bin/example-tool")
        #expect(tool["arguments"] as? [String] == ["--print", "--model={model}"])
        #expect((tool["output"] as? [String: Any])?["text"] is [String: Any])
        #expect(tool["runsWithoutTools"] as? Bool == false)
        #expect((first["limits"] as? [String: Any])?["concurrentRequests"] as? Int == 1)

        let reloaded = AISettingsStore(fileURL: store.fileURL, keys: InMemoryKeys())
        #expect(reloaded.providers == store.providers)
    }

    @Test func readsTheDocumentedExample() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("ai.json")
        try Data("""
        {
          "version": 1,
          "providers": [
            {
              "id": "A9D2",
              "name": "Terminal tool",
              "kind": { "commandLine": { "executable": "/usr/local/bin/example-tool", "arguments": ["--print", "--model", "{model}"], "environment": {}, "output": { "text": {} }, "runsWithoutTools": false } },
              "models": [ { "name": "", "inputCharacterLimit": 100000 } ],
              "limits": { "concurrentRequests": 1 }
            }
          ]
        }
        """.utf8).write(to: file)
        let store = AISettingsStore(fileURL: file, keys: InMemoryKeys())
        #expect(!store.replacedUnreadableFile)
        guard case .commandLine(let tool) = store.providers.first?.kind else {
            Issue.record("Expected a command-line provider")
            return
        }
        #expect(tool.executable.path == "/usr/local/bin/example-tool")
        #expect(tool.output == .text)
        #expect(store.providers.first?.defaultCapabilities == [.jsonOutput])
        #expect(store.route(for: .defaultRoute).models == [AIModelRef(provider: AIProviderID(rawValue: "A9D2"), model: "")])
    }
}

@Suite struct LoginShellTests {
    @Test func takesTheNamedVariablesBetweenTheMarkers() {
        // Another variable, an empty one, and a value with a line break that spells the end marker stay out.
        let entries = "TOKEN=secret\0PATH=/opt/tools/bin:/usr/bin\0HOME=/Users/me\0CLAUDE_CONFIG_DIR=/Users/me/claude config\0CODEX_HOME=\0NOTE=a\n\(LoginShell.endMarker)\nb\0"
        let output = "Welcome back\nnoise\(LoginShell.marker)\n\(entries)\(LoginShell.endMarker)\nbye\n"
        #expect(LoginShell.environment(inOutput: output) == ["PATH": "/opt/tools/bin:/usr/bin", "HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/Users/me/claude config"])
        // Not before the end marker's line is complete, and not without PATH.
        #expect(LoginShell.environment(inOutput: "\(LoginShell.marker)\nPATH=/usr/bin\0\(LoginShell.endMarker)") == nil)
        #expect(LoginShell.environment(inOutput: "\(LoginShell.marker)\nPATH=/usr/bin\0") == nil)
        #expect(LoginShell.environment(inOutput: "\(LoginShell.marker)\nHOME=/Users/me\0PATH=\0\(LoginShell.endMarker)\n") == nil)
        #expect(LoginShell.environment(inOutput: "no marker\n") == nil)
    }

    @Test func readsTheEnvironmentOfALoginShell() async {
        let environment = await LoginShell.readEnvironment(shell: URL(fileURLWithPath: "/bin/sh"))
        #expect(environment?["PATH"]?.split(separator: ":").contains("/usr/bin") == true)
        #expect(environment?["HOME"] == NSHomeDirectory())
    }

    @Test func readsOnlyExportedVariablesAndStopsAtTheEndMarker() async throws {
        // A stand-in login shell whose profile prints text, exports one variable and sets another without exporting it, and leaves a background process holding the output open, then runs the command it was given.
        let shell = try toolScript("""
            echo 'Welcome back'
            export CLAUDE_CONFIG_DIR=/opt/claude-config
            CODEX_HOME=/opt/unexported
            sleep 8 &
            exec /bin/sh -c "$4"
            """)
        let clock = ContinuousClock()
        let started = clock.now
        let environment = await LoginShell.readEnvironment(shell: shell)
        #expect(clock.now - started < .seconds(6))
        #expect(environment?["CLAUDE_CONFIG_DIR"] == "/opt/claude-config")
        #expect(environment?["CODEX_HOME"] == nil)
        #expect(environment?["PATH"] != nil)
    }

    @Test func locatesExecutablesInTheSearchPath() async throws {
        let tool = try toolScript("exit 0")
        let folder = tool.deletingLastPathComponent()
        try Data().write(to: folder.appendingPathComponent("plain"))
        #expect(AICommandLineConfiguration.locate("tool", searchPath: "/nonexistent:\(folder.path)") == tool)
        #expect(AICommandLineConfiguration.locate("plain", searchPath: folder.path) == nil)
        #expect(!AICommandLineConfiguration.isExecutable(at: folder))
        #expect(await AICommandLineConfiguration.locateExecutable(named: " /bin/cat ") == URL(fileURLWithPath: "/bin/cat"))
    }
}

// MARK: - Helpers

/// A shell script in a new temporary folder, made executable, standing in for a command-line AI tool.
private func toolScript(_ body: String) throws -> URL {
    let directory = temporaryDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tool")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// A provider for the tool with a fixed PATH, so tests never read the user's login shell.
private func commandLineProvider(_ executable: URL, output: AICommandLineOutput = .text, arguments: [String] = [], environment: [String: String] = [:]) -> CommandLineProvider {
    let tool = AICommandLineConfiguration(executable: executable, arguments: arguments, environment: environment.merging(["PATH": "/usr/bin:/bin"]) { configured, _ in configured }, output: output)
    return CommandLineProvider(configuration: AIProviderConfiguration(name: "Tool", kind: .commandLine(tool), models: [AIModelConfiguration(name: "")], limits: .commandLine), tool: tool)
}

private func commandLineConfiguration(runsWithoutTools: Bool) -> AIProviderConfiguration {
    AIProviderConfiguration(name: "Tool", kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/cat"), runsWithoutTools: runsWithoutTools)),
                            models: [AIModelConfiguration(name: "tool-model")], limits: .commandLine)
}

private func providerRequest(_ text: String = "Hello", output: AIOutputFormat = .text) -> AIProviderRequest {
    AIProviderRequest(model: "", instructions: "Be brief.", messages: [AIMessage(role: .user, parts: [.text(text)])], tools: [], output: output, maxOutputTokens: 100)
}

/// The reply's text, joined from its text events.
private func replyText(_ events: [String]) -> String {
    events.filter { $0.hasPrefix("text:") }.map { String($0.dropFirst("text:".count)) }.joined()
}

private func pidFileURL() -> URL {
    testRunFolder.appendingPathComponent("\(UUID().uuidString).pid")
}

/// The process group ID a tool script wrote, once it has started.
private func processGroup(in pidFile: URL) async throws -> pid_t {
    for _ in 0..<300 {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let group = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return group
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
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
