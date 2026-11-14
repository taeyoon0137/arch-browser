// The built `arch-cli` as arch-mcp through pipes, as Claude Code and Codex start it: under the name `arch-mcp` through a link and as `arch-cli mcp`, with the recorded client lines of MCPServerTests on standard input. These copies run outside an app bundle, so `ARCH_AGENT_TEST_SOCKET` moves their socket to a path in the temporary folder where nothing listens, and a running Arch never sees them: the lists come from the catalog and tool calls end in the not-running error result. The `skills` commands run from a copy in a scratch app bundle, with `HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `--path` in the temporary folder, so they never write the user's own skill folders; they connect to no socket. `swift build` writes the executable beside this test bundle and must run before `swift test`.
import AgentControl
import Foundation
import Testing

private final class BundleMarker {}

/// The `arch-cli` that SwiftPM built beside this test bundle. `swift test` does not build an executable no test target depends on, so `swift build` runs first, as the plan's checks do.
private func builtExecutable() throws -> URL {
    let executable = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent(AgentBundleLayout.cliName)
    try #require(FileManager.default.isExecutableFile(atPath: executable.path), "Build arch-cli with swift build first: \(executable.path)")
    return executable
}

private struct Run {
    var status: Int32
    var lines: [AgentJSON]
    var output: String
    var errors: String
}

/// A socket path in the temporary folder where nothing listens.
private let absentSocket = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("act-none-\(UUID().uuidString.prefix(8)).sock").path

/// Runs the executable with the lines on standard input, closes it, and reads both outputs, decoding each line of standard output as JSON unless `json` is false. The socket is `absentSocket`, so no Arch is reached.
private func run(_ executable: URL, _ arguments: [String] = [], environment: [String: String] = [:], input: [String], json: Bool = true) throws -> Run {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.filter { $0.key != AgentMCPServer.ticketVariable }
        .merging([AgentSocketLocation.unbundledClientVariable: absentSocket]) { $1 }
        .merging(environment) { $1 }
    let standardInput = Pipe(), standardOutput = Pipe(), standardError = Pipe()
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    try standardInput.fileHandleForWriting.write(contentsOf: Data(input.map { $0 + "\n" }.joined().utf8))
    try standardInput.fileHandleForWriting.close()
    let errorData = ErrorData()
    let errorsRead = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        errorData.value = standardError.fileHandleForReading.readDataToEndOfFile()
        errorsRead.signal()
    }
    let output = String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    errorsRead.wait()
    let lines = json ? try output.split(separator: "\n").map { try AgentJSON.decode(Data($0.utf8)) } : []
    return Run(status: process.terminationStatus, lines: lines, output: output, errors: String(decoding: errorData.value, as: UTF8.self))
}

private final class ErrorData: @unchecked Sendable {
    var value = Data()
}

/// A temporary folder with `arch-mcp` as a link to the built executable, as in `Contents/Helpers`.
private func archMCPLink(to executable: URL) throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("act-mcp-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent(AgentBundleLayout.mcpName)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: executable.path)
    return link
}

private let claudeCodeStart = [
    #"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.323","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}}}}}"#,
    #"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.323","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"}},"jsonrpc":"2.0","id":0}"#,
    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    #"{"method":"tools/list","jsonrpc":"2.0","id":1}"#,
]

private let codexStart = [
    #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.164.0"}}}"#,
    #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"progressToken":0}}}"#,
]

@Suite(.serialized) struct MCPExecutableTests {
    @Test func archMCPThroughItsLinkAnswersClaudeCodesStart() throws {
        let link = try archMCPLink(to: try builtExecutable())
        defer { try? FileManager.default.removeItem(at: link.deletingLastPathComponent()) }
        let result = try run(link, input: claudeCodeStart + [
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_tabs","arguments":{}}}"#,
        ])
        #expect(result.status == 0)
        try #require(result.lines.count == 5, "\(result.output)")
        // `server/discover` before initialize gets -32601, and the initialize after it is accepted.
        #expect(result.lines[0]["id"] == "server-discover-probe-1")
        #expect(result.lines[0]["error"]?["code"] == .number(-32601))
        #expect(result.lines[1]["id"] == 0)
        #expect(result.lines[1]["result"]?["protocolVersion"] == "2025-11-25")
        #expect(result.lines[1]["result"]?["serverInfo"]?["name"] == "arch")
        #expect(result.lines[1]["result"]?["instructions"] == .string(AgentHarness.mcpInstructions))
        guard case .array(let tools)? = result.lines[2]["result"]?["tools"] else { Issue.record("no tool list: \(result.output)"); return }
        #expect(tools.compactMap { $0["name"]?.stringValue } == AgentToolCatalog.tools.map(\.name))
        #expect(result.lines[3] == ["jsonrpc": "2.0", "id": 2, "result": [:]])
        #expect(result.lines[4]["id"] == 3)
        #expect(result.lines[4]["result"]?["isError"] == true)
        #expect(result.lines[4]["result"]?["content"] == [["type": "text", "text": .string(AgentClientError.notRunning.message)]])
        // Standard output holds only MCP messages; the reason goes to standard error.
        #expect(result.errors.hasPrefix("arch-mcp: "))
    }

    @Test func archCLIMCPAnswersCodexsStart() throws {
        let result = try run(try builtExecutable(), ["mcp"], input: codexStart)
        #expect(result.status == 0)
        try #require(result.lines.count == 2, "\(result.output)")
        #expect(result.lines[0]["result"]?["protocolVersion"] == "2025-06-18")
        #expect(result.lines[0]["result"]?["capabilities"] == ["tools": ["listChanged": true]])
        guard case .array(let tools)? = result.lines[1]["result"]?["tools"] else { Issue.record("no tool list: \(result.output)"); return }
        #expect(tools.count == AgentToolCatalog.tools.count)
    }

    @Test func itExitsWhenStandardInputCloses() throws {
        let result = try run(try builtExecutable(), ["mcp"], input: [])
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test func aSessionsServerNeedsItsTicketAndArch() throws {
        let executable = try builtExecutable()
        let missing = try run(executable, ["mcp", "--session"], input: codexStart)
        #expect(missing.status == AgentExitCode.usage.rawValue)
        #expect(missing.output.isEmpty)
        #expect(missing.errors.contains(AgentMCPServer.ticketVariable))
        // With a ticket but no Arch to bind it, it ends with 69 before answering anything.
        let unbound = try run(executable, ["mcp", "--session"], environment: [AgentMCPServer.ticketVariable: "dGlja2V0"], input: codexStart)
        #expect(unbound.status == AgentExitCode.unavailable.rawValue)
        #expect(unbound.output.isEmpty)
        #expect(unbound.errors.contains(AgentClientError.notRunning.message))
        let extra = try run(executable, ["mcp", "--stdio"], input: [])
        #expect(extra.status == AgentExitCode.usage.rawValue)
    }

    @Test func setupCommandsOutsideABundleExit77() throws {
        let executable = try builtExecutable()
        for arguments in [["mcp-config"], ["setup", "claude"], ["links", "install"], ["skills", "list"], ["skills", "install", "--path", NSTemporaryDirectory()]] {
            let result = try run(executable, arguments, input: [])
            #expect(result.status == AgentExitCode.notArch.rawValue, "\(arguments)")
            #expect(result.errors.contains("does not run from inside an Arch bundle"), "\(arguments)")
        }
        #expect(try run(executable, ["setup", "cursor"], input: []).status == AgentExitCode.usage.rawValue)
    }

    @Test func skillsFromABundleWriteListAndRemoveTheEntrySkill() throws {
        // A scratch bundle with a copy of the built executable as its Contents/Helpers/arch-cli, and the skill folders beside it.
        // The temporary folder's real path, which the copy finds itself at (`realpath`), so that the skill's text names the same path.
        let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(temporary) }
        let root = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent("act-skillcli-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = AgentBundleLayout(bundleURL: root.appendingPathComponent("Arch.app"))
        try FileManager.default.createDirectory(at: layout.helpersURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try builtExecutable(), to: layout.cliExecutableURL)
        let folder = root.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let environment = ["HOME": root.path, "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path, "CODEX_HOME": root.appendingPathComponent("codex").path]
        let places = ["--target", "claude", "--target", "codex-home", "--path", folder.path]
        let files = ["claude/skills", "codex/skills", "skills"].map { root.appendingPathComponent($0).appendingPathComponent("arch-browser/SKILL.md") }
        let skill = AgentHarness.entrySkill(cliPath: layout.cliExecutableURL.path)

        let install = try run(layout.cliExecutableURL, ["skills", "install"] + places, environment: environment, input: [], json: false)
        #expect(install.status == 0, "\(install.errors)")
        // The exact paths come before the write, and each copy names this bundle's arch-cli.
        for file in files {
            #expect(install.output.contains("  \(file.path)\n"), "\(file.path)")
            #expect((try? String(contentsOf: file, encoding: .utf8)) == skill.markdown, "\(file.path)")
        }
        let list = try run(layout.cliExecutableURL, ["skills", "list"] + places, environment: environment, input: [], json: false)
        #expect(list.status == 0)
        #expect(list.output.components(separatedBy: "Installed, with this Arch's text.").count == 4, "\(list.output)")
        // Without a place, list names the three targets; codex's folder is under HOME.
        let targets = try run(layout.cliExecutableURL, ["skills", "list"], environment: environment, input: [], json: false)
        #expect(targets.status == 0)
        #expect(targets.output.contains("Codex: \(root.appendingPathComponent(".agents/skills/arch-browser").path)\n  Not installed."), "\(targets.output)")

        // A foreign folder in the last place stops install before any path is listed or written: the first place keeps its older copy, and the second stays absent.
        try FileManager.default.removeItem(at: files[2])
        try Data("my notes".utf8).write(to: files[2].deletingLastPathComponent().appendingPathComponent("notes.md"))
        let older = AgentHarness.entrySkill(cliPath: "/Other/Arch.app/Contents/Helpers/arch-cli").markdown
        try Data(older.utf8).write(to: files[0])
        try FileManager.default.removeItem(at: files[1].deletingLastPathComponent())
        let refused = try run(layout.cliExecutableURL, ["skills", "install"] + places, environment: environment, input: [], json: false)
        #expect(refused.status == AgentExitCode.refused.rawValue)
        #expect(refused.errors.contains("Arch did not write"))
        #expect(!refused.output.contains("Writing"), "\(refused.output)")
        #expect((try? String(contentsOf: files[0], encoding: .utf8)) == older)
        #expect(!FileManager.default.fileExists(atPath: files[1].deletingLastPathComponent().path))
        // An Arch copy of other text is listed as outdated, and one changed since Arch wrote it as changed.
        let outdated = try run(layout.cliExecutableURL, ["skills", "list", "--target", "claude"], environment: environment, input: [], json: false)
        #expect(outdated.output.contains("older than this Arch"))
        try Data((older + "My note.\n").utf8).write(to: files[0])
        let modified = try run(layout.cliExecutableURL, ["skills", "list", "--target", "claude"], environment: environment, input: [], json: false)
        #expect(modified.output.contains("changes made after Arch wrote it"), "\(modified.output)")
        try Data(older.utf8).write(to: files[0])

        // remove processes every place: a missing --path folder and the foreign folder are reported after Arch's copy is removed, with the higher exit code.
        let missing = root.appendingPathComponent("missing").path
        let remove = try run(layout.cliExecutableURL, ["skills", "remove", "--path", missing] + places, environment: environment, input: [], json: false)
        #expect(remove.status == AgentExitCode.refused.rawValue)
        #expect(remove.errors.contains("\(missing) is not a folder."), "\(remove.errors)")
        #expect(remove.errors.contains("Arch did not write"))
        #expect(remove.output.contains("Removed \(files[0].deletingLastPathComponent().path)."), "\(remove.output)")
        #expect(remove.output.contains("No skill of Arch's is at \(files[1].deletingLastPathComponent().path)."), "\(remove.output)")
        #expect(!FileManager.default.fileExists(atPath: files[0].deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: files[2].deletingLastPathComponent().appendingPathComponent("notes.md").path))
        // A missing folder before a valid target exits 2 after removing the target's copy.
        #expect(try run(layout.cliExecutableURL, ["skills", "install", "--target", "codex-home"], environment: environment, input: [], json: false).status == 0)
        let usage = try run(layout.cliExecutableURL, ["skills", "remove", "--path", missing, "--target", "codex-home"], environment: environment, input: [], json: false)
        #expect(usage.status == AgentExitCode.usage.rawValue)
        #expect(!FileManager.default.fileExists(atPath: files[1].deletingLastPathComponent().path))
        let again = try run(layout.cliExecutableURL, ["skills", "remove", "--target", "claude"], environment: environment, input: [], json: false)
        #expect(again.status == 0)
        #expect(again.output.contains("No skill of Arch's is at"))
    }
}
