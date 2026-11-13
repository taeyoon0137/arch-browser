// The built `arch-cli` as arch-mcp through pipes, as Claude Code and Codex start it: under the name `arch-mcp` through a link and as `arch-cli mcp`, with the recorded client lines of MCPServerTests on standard input. Nothing listens for these copies, which run outside an app bundle; were an Arch listening, the client check would refuse it, so the lists come from the catalog and tool calls end in an error result either way. `swift build` writes the executable beside this test bundle and must run before `swift test`.
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

/// Runs the executable with the lines on standard input, closes it, and reads both outputs.
private func run(_ executable: URL, _ arguments: [String] = [], environment: [String: String] = [:], input: [String]) throws -> Run {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.filter { $0.key != AgentMCPServer.ticketVariable }.merging(environment) { $1 }
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
    let lines = try output.split(separator: "\n").map { try AgentJSON.decode(Data($0.utf8)) }
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
        // With a ticket but no Arch to bind it, it ends before answering anything: 69 while nothing listens, 77 for a listener this unbundled copy cannot check.
        let unbound = try run(executable, ["mcp", "--session"], environment: [AgentMCPServer.ticketVariable: "dGlja2V0"], input: codexStart)
        #expect([AgentExitCode.unavailable.rawValue, AgentExitCode.notArch.rawValue].contains(unbound.status))
        #expect(unbound.output.isEmpty)
        let extra = try run(executable, ["mcp", "--stdio"], input: [])
        #expect(extra.status == AgentExitCode.usage.rawValue)
    }

    @Test func setupCommandsOutsideABundleExit77() throws {
        let executable = try builtExecutable()
        for arguments in [["mcp-config"], ["setup", "claude"], ["links", "install"]] {
            let result = try run(executable, arguments, input: [])
            #expect(result.status == AgentExitCode.notArch.rawValue, "\(arguments)")
            #expect(result.errors.contains("does not run from inside an Arch bundle"), "\(arguments)")
        }
        #expect(try run(executable, ["setup", "cursor"], input: []).status == AgentExitCode.usage.rawValue)
    }
}
