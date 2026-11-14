// arch-mcp's MCP core against transcripts. The client lines of the first two tests were recorded from arch-mcp's standard input: Claude Code 2.1.323's start, from `claude mcp list` with a scratch `CLAUDE_CONFIG_DIR`, and Codex 0.164.0's, from `codex exec` in an empty, signed-out `CODEX_HOME`, which starts its MCP servers before its model request fails. The other exchanges are written by hand for what a start does not reach: version negotiation, errors, tool calls with text, image, and structured results, `approvalPending` and `approval_wait`, progress, cancellation, list changes, Arch not running or closing the connection, and an in-app session's server.
import AgentControl
import Foundation
import Testing

/// Drives an `AgentMCPServer` and writes each effect as one line: `client <- <JSON>`, `arch <- <JSON>`, `connect <hello>`, `log <sentence>`, or `exit <code>`.
private struct Transcript {
    var server: AgentMCPServer

    init(_ mode: AgentMCPServer.Mode = .outside) {
        server = AgentMCPServer(mode: mode, version: "0.1.0", instructions: "Call guide first.")
    }

    mutating func start() -> [String] { render(server.start()) }
    mutating func client(_ line: String) -> [String] { render(server.receive(line: Data(line.utf8))) }
    mutating func arch(_ line: String) -> [String] { render(server.receive(control: try! AgentRPCMessage.decode(Data(line.utf8)))) }
    mutating func connected(_ status: AgentConnectionStatus = .noGrant) -> [String] { render(server.connected(AgentHelloAnswer(version: "0.1.0", status: status))) }
    mutating func failed(_ error: AgentClientError) -> [String] { render(server.connectionFailed(error)) }
    mutating func inputEnded() -> [String] { render(server.inputEnded()) }

    /// Initializes at a version, as a client does before it lists or calls tools.
    mutating func initialize(_ version: String = "2025-11-25") {
        _ = client(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        _ = client(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    private func render(_ effects: [AgentMCPServer.Effect]) -> [String] {
        effects.map { effect in
            switch effect {
            case .reply(let message): return "client <- " + Self.text(try! message.encoded())
            case .send(let message): return "arch <- " + Self.text(try! message.encoded())
            case .connect(let hello): return "connect " + Self.text(try! AgentJSON(encoding: hello).encoded())
            case .log(let sentence): return "log " + sentence
            case .exit(let code): return "exit \(code.rawValue)"
            }
        }
    }

    private static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}

/// The JSON of a rendered `client <- …` line.
private func reply(_ rendered: String) throws -> AgentJSON {
    let prefix = "client <- "
    try #require(rendered.hasPrefix(prefix), "\(rendered)")
    return try AgentJSON.decode(Data(rendered.dropFirst(prefix.count).utf8))
}

/// The tools of a rendered `tools/list` answer.
private func tools(_ rendered: String) throws -> [AgentJSON] {
    guard case .array(let tools)? = try reply(rendered)["result"]?["tools"] else { throw AgentRPCError.invalidRequest("not a tool list: \(rendered)") }
    return tools
}

private func toolNames(_ rendered: String) throws -> [String] {
    try tools(rendered).compactMap { $0["name"]?.stringValue }
}

private let catalogNames = AgentToolCatalog.tools.map(\.name)
private let outsideHello = #"connect {"client":"arch-mcp","protocol":1,"version":"0.1.0"}"#
private let notRunning = AgentClientError.notRunning.message

@Suite struct MCPServerTests {
    @Test func claudeCodesRecordedStartWithArchNotRunning() throws {
        var transcript = Transcript()
        #expect(transcript.start() == [])
        // Recorded: Claude Code probes with `server/discover` first and initializes after the error.
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.323","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"},"io.modelcontextprotocol/clientCapabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}}}}}"#) == [
            #"client <- {"error":{"code":-32601,"message":"Method not found: server/discover"},"id":"server-discover-probe-1","jsonrpc":"2.0"}"#,
        ])
        #expect(transcript.client(#"{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.323","description":"Anthropic's agentic coding tool","websiteUrl":"https://claude.com/claude-code"}},"jsonrpc":"2.0","id":0}"#) == [
            #"client <- {"id":0,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":true}},"instructions":"Call guide first.","protocolVersion":"2025-11-25","serverInfo":{"name":"arch","version":"0.1.0"}}}"#,
        ])
        #expect(transcript.client(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == [])
        #expect(transcript.client(#"{"method":"tools/list","jsonrpc":"2.0","id":1}"#) == [outsideHello])
        let answer = transcript.failed(.notRunning)
        #expect(answer.count == 2)
        #expect(answer.first == "log " + notRunning)
        // Without Arch, the list is the compiled-in catalog, with annotations at this version.
        #expect(try toolNames(answer[1]) == catalogNames)
        #expect(try tools(answer[1]).first?["annotations"] == ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false])
        #expect(transcript.inputEnded() == ["exit 0"])
    }

    @Test func codexsRecordedStartWithAGrantlessConnection() throws {
        var transcript = Transcript()
        // Recorded: Codex initializes first, at 2025-06-18, and lists tools with a progress token.
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.164.0"}}}"#) == [
            #"client <- {"id":0,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":true}},"instructions":"Call guide first.","protocolVersion":"2025-06-18","serverInfo":{"name":"arch","version":"0.1.0"}}}"#,
        ])
        #expect(transcript.client(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == [])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"progressToken":0}}}"#) == [outsideHello])
        #expect(transcript.connected(.noGrant) == [#"arch <- {"id":1,"jsonrpc":"2.0","method":"tools/list"}"#])
        // Arch names the tools; arch-mcp describes them from its catalog, in Arch's order.
        let answer = transcript.arch(#"{"jsonrpc":"2.0","id":1,"result":{"tools":["list_tabs","session_info","no_such_tool"]}}"#)
        #expect(answer.count == 1)
        #expect(try toolNames(answer[0]) == ["list_tabs", "session_info"])
        #expect(try reply(answer[0])["id"] == 1)
    }

    @Test(arguments: [
        ("2024-11-05", "2024-11-05"), ("2025-03-26", "2025-03-26"), ("2025-06-18", "2025-06-18"), ("2025-11-25", "2025-11-25"),
        ("2026-07-28", "2025-11-25"), ("1.0", "2025-11-25"),
    ])
    func initializeNegotiatesTheVersion(requested: String, agreed: String) throws {
        var transcript = Transcript()
        let answer = transcript.client(#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"\#(requested)","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(answer.count == 1)
        #expect(try reply(answer[0])["result"]?["protocolVersion"] == .string(agreed))
        #expect(try reply(answer[0])["result"]?["capabilities"] == ["tools": ["listChanged": true]])
    }

    @Test func versionsShapeToolsAndResults() throws {
        // 2024-11-05 has no tool annotations, and neither it nor 2025-03-26 has structuredContent.
        for (version, annotations, structured) in [("2024-11-05", false, false), ("2025-03-26", true, false), ("2025-06-18", true, true)] {
            var transcript = Transcript()
            transcript.initialize(version)
            _ = transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            #expect(try tools(transcript.failed(.notRunning)[1]).allSatisfy { ($0["annotations"] != nil) == annotations }, "\(version)")
            _ = transcript.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_info"}}"#)
            _ = transcript.connected()
            let result = try reply(transcript.arch(#"{"jsonrpc":"2.0","id":1,"result":{"status":"ok","content":[{"type":"text","text":"Read Only."}],"structured":{"mode":"readOnly"}}}"#)[0])["result"]
            #expect((result?["structuredContent"] != nil) == structured, "\(version)")
        }
    }

    @Test func requestsBeforeInitializeAndProtocolErrors() {
        var transcript = Transcript()
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) == [#"client <- {"error":{"code":-32600,"message":"Send initialize first."},"id":1,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_info"}}"#) == [#"client <- {"error":{"code":-32600,"message":"Send initialize first."},"id":2,"jsonrpc":"2.0"}"#])
        // ping is answered at any time, and any method arch-mcp does not serve is -32601, before initialize too.
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#) == [#"client <- {"id":"p","jsonrpc":"2.0","result":{}}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#) == [#"client <- {"error":{"code":-32601,"message":"Method not found: resources/list"},"id":3,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"capabilities":{}}}"#) == [#"client <- {"error":{"code":-32602,"message":"initialize needs a protocolVersion."},"id":4,"jsonrpc":"2.0"}"#])
        transcript.initialize()
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#) == [#"client <- {"error":{"code":-32600,"message":"initialize was already answered."},"id":5,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":6,"method":"prompts/list"}"#) == [#"client <- {"error":{"code":-32601,"message":"Method not found: prompts/list"},"id":6,"jsonrpc":"2.0"}"#])
        // Text that is not JSON, a batch, and a malformed request; notifications and answers get nothing back.
        #expect(transcript.client("{not json") == [#"client <- {"error":{"code":-32700,"message":"The message is not valid JSON."},"id":null,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"[{"jsonrpc":"2.0","id":7,"method":"ping"}]"#) == [#"client <- {"error":{"code":-32600,"message":"A message must be a JSON object."},"id":null,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":8}"#) == [#"client <- {"error":{"code":-32600,"message":"An answer must carry either result or error."},"id":null,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#) == [])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == [])
    }

    @Test func toolCallsAreCheckedForTheProtocolOnly() {
        var transcript = Transcript()
        transcript.initialize()
        // An unknown tool and a malformed call never reach Arch. A known tool goes to Arch whatever its arguments, since the tool host checks them.
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_script","arguments":{}}}"#) == [#"client <- {"error":{"code":-32602,"message":"Unknown tool: run_script"},"id":1,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":{}}}"#) == [#"client <- {"error":{"code":-32602,"message":"tools/call needs a tool name."},"id":2,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":["t1"]}}"#) == [#"client <- {"error":{"code":-32602,"message":"A tool's arguments must be an object."},"id":3,"jsonrpc":"2.0"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click","arguments":{"tab":"nine"}}}"#) == [outsideHello])
        #expect(transcript.connected() == [#"arch <- {"id":1,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"tab":"nine"},"name":"click"}}"#])
    }

    @Test func aCallWithTextImageAndStructuredContent() throws {
        var transcript = Transcript()
        transcript.initialize()
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"screenshot","arguments":{"tab":"t1","area":"viewport"}}}"#) == [outsideHello])
        #expect(transcript.connected(.granted(AgentGrantSummary(level: .readOnly, persona: "Agents", expiry: .whenArchQuits))) == [
            #"arch <- {"id":1,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"area":"viewport","tab":"t1"},"name":"screenshot"}}"#,
        ])
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let result = AgentToolResult(status: .ok, content: [.text("Captured t1's viewport."), .image(image, mimeType: "image/jpeg")], structured: ["tab": "t1", "events": []])
        let message = String(decoding: try AgentRPCMessage.result(id: .number(1), result: AgentJSON(encoding: result)).encoded(), as: UTF8.self)
        #expect(transcript.arch(message) == [
            #"client <- {"id":11,"jsonrpc":"2.0","result":{"content":[{"text":"Captured t1's viewport.","type":"text"},{"data":"/9j/4A==","mimeType":"image/jpeg","type":"image"}],"isError":false,"structuredContent":{"events":[],"status":"ok","tab":"t1"}}}"#,
        ])
        // A result that is not ok is an error for the client, with its status and the rule that refused in the structured facts.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"type","arguments":{"tab":"t1","ref":"e6","text":"x"}}}"#)
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":2,"result":{"status":"refused","code":"P1","content":[{"type":"text","text":"Agents never type into password fields. Use hand_to_user."}]}}"#) == [
            #"client <- {"id":12,"jsonrpc":"2.0","result":{"content":[{"text":"Agents never type into password fields. Use hand_to_user.","type":"text"}],"isError":true,"structuredContent":{"code":"P1","status":"refused"}}}"#,
        ])
        // An answer Arch's tool host could not have written, and a JSON-RPC error, become error results.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"list_tabs"}}"#)
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":3,"result":{"status":"fine"}}"#) == [#"client <- {"id":13,"jsonrpc":"2.0","result":{"content":[{"text":"Arch's answer could not be read.","type":"text"}],"isError":true}}"#])
        _ = transcript.client(#"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"list_tabs"}}"#)
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"busy"}}"#) == [#"client <- {"id":14,"jsonrpc":"2.0","result":{"content":[{"text":"busy","type":"text"}],"isError":true}}"#])
        // An answer to no running call is dropped.
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":99,"result":{"status":"ok","content":[]}}"#) == [])
    }

    @Test func theGuideToolGoesToArchAndBackAsText() throws {
        var transcript = Transcript()
        transcript.initialize("2025-06-18")
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"guide","arguments":{"topic":"forms"}}}"#) == [outsideHello])
        #expect(transcript.connected() == [#"arch <- {"id":1,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"topic":"forms"},"name":"guide"}}"#])
        // The tool host answers with the harness's result, which reaches the client as the topic's text.
        let result = AgentHarness.guideResult(arguments: ["topic": "forms"])
        let answer = try reply(try #require(transcript.arch(String(decoding: try AgentRPCMessage.result(id: .number(1), result: AgentJSON(encoding: result)).encoded(), as: UTF8.self)).first))
        #expect(answer["id"] == 5)
        #expect(answer["result"]?["content"] == [["type": "text", "text": .string(AgentHarness.text(for: .forms))]])
        #expect(answer["result"]?["isError"] == false)
        #expect(answer["result"]?["structuredContent"]?["topic"] == "forms")
        #expect(answer["result"]?["structuredContent"]?["status"] == "ok")
    }

    @Test func approvalPendingAtTheCapAndApprovalWait() throws {
        var transcript = Transcript()
        transcript.initialize()
        _ = transcript.client(#"{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"click","arguments":{"tab":"t2","ref":"e7"}}}"#)
        _ = transcript.connected()
        // Arch answers a call that still waits for the user after 45 seconds with approvalPending and the approval's ID.
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":1,"result":{"status":"approvalPending","approval":"a7","content":[{"type":"text","text":"Clicking “Place order” on example.org asks the user."}]}}"#) == [
            #"client <- {"id":21,"jsonrpc":"2.0","result":{"content":[{"text":"Waiting for the user in Arch; call approval_wait with this ID: a7","type":"text"},{"text":"Clicking “Place order” on example.org asks the user.","type":"text"}],"isError":false,"structuredContent":{"approval":"a7","status":"approvalPending"}}}"#,
        ])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"approval_wait","arguments":{"approval":"a7"}}}"#) == [
            #"arch <- {"id":2,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"approval":"a7"},"name":"approval_wait"}}"#,
        ])
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":2,"result":{"status":"ok","content":[{"type":"text","text":"Clicked “Place order”."}]}}"#) == [
            #"client <- {"id":22,"jsonrpc":"2.0","result":{"content":[{"text":"Clicked “Place order”.","type":"text"}],"isError":false,"structuredContent":{"status":"ok"}}}"#,
        ])
        // approvalPending without an approval cannot be waited on.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"click","arguments":{"tab":"t2","ref":"e8"}}}"#)
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":3,"result":{"status":"approvalPending","content":[]}}"#) == [
            #"client <- {"id":23,"jsonrpc":"2.0","result":{"content":[{"text":"Arch's answer could not be read: it waits for an approval it does not name.","type":"text"}],"isError":true}}"#,
        ])
    }

    @Test func progressGoesOnlyToCallsWithAToken() {
        for (version, message) in [("2025-11-25", true), ("2024-11-05", false)] {
            var transcript = Transcript()
            transcript.initialize(version)
            _ = transcript.client(#"{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"request_approval","arguments":{"summary":"Send the form.","kind":"submit"},"_meta":{"progressToken":"p31"}}}"#)
            _ = transcript.client(#"{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"ask_user","arguments":{"question":"Which plan?"}}}"#)
            _ = transcript.connected()
            let first = message
                ? #"client <- {"jsonrpc":"2.0","method":"notifications/progress","params":{"message":"Waiting for your approval in Arch","progress":1,"progressToken":"p31"}}"#
                : #"client <- {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1,"progressToken":"p31"}}"#
            #expect(transcript.arch(#"{"jsonrpc":"2.0","method":"progress","params":{"call":1,"message":"Waiting for your approval in Arch"}}"#) == [first], "\(version)")
            // Each notification reports more progress than the one before.
            #expect(transcript.arch(#"{"jsonrpc":"2.0","method":"progress","params":{"call":1,"message":"Still waiting"}}"#).first?.contains(#""progress":2"#) == true)
            // The call without a token, and calls that ended, get none.
            #expect(transcript.arch(#"{"jsonrpc":"2.0","method":"progress","params":{"call":2,"message":"Waiting for you in Arch"}}"#) == [])
            _ = transcript.arch(#"{"jsonrpc":"2.0","id":1,"result":{"status":"denied","content":[{"type":"text","text":"The user said no."}]}}"#)
            #expect(transcript.arch(#"{"jsonrpc":"2.0","method":"progress","params":{"call":1,"message":"Late"}}"#) == [])
        }
    }

    @Test func cancellationStopsTheCallInArch() {
        var transcript = Transcript()
        transcript.initialize()
        // The core drops a call cancelled before the connection's outcome. `MCPServerLoop` connects before it reads the next line, so there the cancellation follows the call to Arch, as below.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"wait_for","arguments":{"tab":"t1","load":true}}}"#)
        #expect(transcript.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":41,"reason":"The user stopped it."}}"#) == [])
        _ = transcript.client(#"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"ask_user","arguments":{"question":"Go on?"}}}"#)
        #expect(transcript.connected() == [#"arch <- {"id":1,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"question":"Go on?"},"name":"ask_user"}}"#])
        // A running call is cancelled in Arch, which withdraws its approval, and its late answer is dropped.
        #expect(transcript.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42}}"#) == [#"arch <- {"jsonrpc":"2.0","method":"tools/cancel","params":{"call":1}}"#])
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":1,"result":{"status":"timeout","content":[]}}"#) == [])
        // A request ID that runs nothing is ignored.
        #expect(transcript.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"none"}}"#) == [])
    }

    @Test func listChangesReachTheClient() throws {
        var transcript = Transcript()
        // Before initialize, a change has no one to tell.
        #expect(transcript.arch(#"{"jsonrpc":"2.0","method":"tools/changed"}"#) == [])
        transcript.initialize()
        // The first list comes from the catalog while Arch is not running.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(try toolNames(transcript.failed(.notRunning)[1]) == catalogNames)
        // A later connection may carry another list, so the client is told to list again.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_info"}}"#)
        #expect(transcript.connected() == [
            #"client <- {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#,
            #"arch <- {"id":1,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{},"name":"session_info"}}"#,
        ])
        // After a grant, Arch says the list changed, and the next list is Arch's.
        #expect(transcript.arch(#"{"jsonrpc":"2.0","method":"tools/changed"}"#) == [#"client <- {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#])
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#) == [#"arch <- {"id":2,"jsonrpc":"2.0","method":"tools/list"}"#])
        #expect(try toolNames(transcript.arch(#"{"jsonrpc":"2.0","id":2,"result":{"tools":["session_info","snapshot","read_text"]}}"#)[0]) == ["session_info", "snapshot", "read_text"])
        // An unreadable list or an error from Arch is a protocol error, not a guess.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":3,"result":{"names":[]}}"#) == [#"client <- {"error":{"code":-32603,"message":"Arch's tool list could not be read."},"id":4,"jsonrpc":"2.0"}"#])
        _ = transcript.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#)
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"busy"}}"#) == [#"client <- {"error":{"code":-32603,"message":"busy"},"id":5,"jsonrpc":"2.0"}"#])
    }

    @Test func archNotRunningAndAClosedConnection() throws {
        var transcript = Transcript()
        transcript.initialize()
        _ = transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tabs"}}"#)
        #expect(transcript.failed(.notRunning) == [
            "log " + notRunning,
            #"client <- {"id":1,"jsonrpc":"2.0","result":{"content":[{"text":"\#(notRunning)","type":"text"}],"isError":true}}"#,
        ])
        // The next call tries again.
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_tabs"}}"#) == [outsideHello])
        _ = transcript.connected()
        _ = transcript.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        // Arch quits or revokes the grant: running calls end with the reason and lists come from the catalog.
        #expect(transcript.arch(#"{"jsonrpc":"2.0","method":"revoked","params":{"message":"The grant was revoked."}}"#) == ["log Arch ended this client's grant."])
        let ended = transcript.failed(.closed)
        #expect(ended.count == 3)
        #expect(ended[0] == "log Arch closed the connection.")
        #expect(ended[1] == #"client <- {"id":2,"jsonrpc":"2.0","result":{"content":[{"text":"Arch closed the connection.","type":"text"}],"isError":true}}"#)
        #expect(try toolNames(ended[2]) == catalogNames)
        // A listener that is not Arch is refused before anything is sent, with its own sentence.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_tabs"}}"#)
        let refused = transcript.failed(.notArch(.otherCode))
        #expect(refused.last?.contains("The socket is not Arch's") == true)
        // A request from Arch is not something arch-mcp serves.
        _ = transcript.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_tabs"}}"#)
        _ = transcript.connected()
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":9,"method":"sessions/list"}"#) == [#"arch <- {"error":{"code":-32601,"message":"Method not found: sessions/list"},"id":9,"jsonrpc":"2.0"}"#])
        #expect(transcript.arch(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"The message is not valid JSON."}}"#) == ["log Arch could not read a message: The message is not valid JSON."])
    }

    @Test(arguments: [true, false])
    func tabRequestSchemaReflectsTheConnection(isSession: Bool) throws {
        var transcript = Transcript(isSession ? .session(ticket: "dGlja2V0") : .outside)
        _ = transcript.start()
        transcript.initialize("2025-06-18")
        _ = transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        _ = transcript.connected(isSession ? .bound : .noGrant)
        let answer = transcript.arch(#"{"jsonrpc":"2.0","id":1,"result":{"tools":["request_tab"]}}"#)
        let rendered = try #require(answer.first)
        let definition = try #require(try tools(rendered).first)
        let input = try #require(definition["inputSchema"])
        let values = input["properties"]?["access"]?["enum"]
        #expect(values == (isSession ? ["read"] : ["read", "act"]))
        #expect(input["additionalProperties"] == false)
    }

    @Test func anInAppSessionsServer() throws {
        var transcript = Transcript(.session(ticket: "dGlja2V0"))
        // It connects at once with the ticket, and its requests wait for the session's connection.
        #expect(transcript.start() == [#"connect {"client":"arch-mcp","protocol":1,"ticket":"dGlja2V0","version":"0.1.0"}"#])
        transcript.initialize("2025-06-18")
        #expect(transcript.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#) == [])
        #expect(transcript.connected(.bound) == [#"arch <- {"id":1,"jsonrpc":"2.0","method":"tools/list"}"#])
        #expect(try toolNames(transcript.arch(#"{"jsonrpc":"2.0","id":1,"result":{"tools":["session_info","snapshot"]}}"#)[0]) == ["session_info", "snapshot"])
        // It ends with its connection, as at Stop, and never falls back to the catalog.
        #expect(transcript.failed(.closed) == ["log Arch closed the connection.", "exit 69"])

        var refused = Transcript(.session(ticket: "dGlja2V0"))
        _ = refused.start()
        #expect(refused.failed(.refused(AgentRefusal(reason: .ticket, message: "The ticket matches no session."))) == ["log The ticket matches no session.", "exit 6"])
        var notRunningSession = Transcript(.session(ticket: "dGlja2V0"))
        _ = notRunningSession.start()
        #expect(notRunningSession.failed(.notRunning) == ["log " + notRunning, "exit 69"])
        // A connection Arch did not bind to the session is not the session's.
        var unbound = Transcript(.session(ticket: "dGlja2V0"))
        _ = unbound.start()
        #expect(unbound.connected(.noGrant) == ["log Arch did not bind this connection to its agent session.", "exit 6"])
    }

    @Test func linesSplitAsTheStdioTransportDelimitsThem() throws {
        var reader = AgentLineReader()
        reader.append(Data("{\"a\":1}\n\n{\"b\"".utf8))
        #expect(try reader.nextLine() == Data("{\"a\":1}".utf8))
        #expect(try reader.nextLine() == nil)
        reader.append(Data(":2}\r\n{\"c\":3}".utf8))
        #expect(try reader.nextLine() == Data("{\"b\":2}".utf8))
        #expect(try reader.nextLine() == nil)
        #expect(reader.finish() == Data("{\"c\":3}".utf8))
        #expect(reader.finish() == nil)
        var long = AgentLineReader()
        long.append(Data(count: AgentFrame.maximumLength + 1))
        #expect(throws: AgentFrameError.tooLong(AgentFrame.maximumLength + 1)) { try long.nextLine() }
        var ended = AgentLineReader()
        ended.append(Data(repeating: 0x20, count: AgentFrame.maximumLength + 1) + Data([0x0A]))
        #expect(throws: AgentFrameError.tooLong(AgentFrame.maximumLength + 1)) { try ended.nextLine() }
    }

    @Test func archMCPsModeComesFromItsArgumentsAndTheTicket() throws {
        #expect(try AgentCommandLine.mcpMode([], ticket: nil) == .outside)
        // An outside client ignores a ticket in its environment.
        #expect(try AgentCommandLine.mcpMode([], ticket: "dGlja2V0") == .outside)
        #expect(try AgentCommandLine.mcpMode(["--session"], ticket: "dGlja2V0") == .session(ticket: "dGlja2V0"))
        #expect(throws: AgentUsageError(message: "arch-mcp --session needs ARCH_AGENT_TICKET, which Arch sets for the agent sessions it starts.")) { try AgentCommandLine.mcpMode(["--session"], ticket: nil) }
        #expect(throws: AgentUsageError(message: "arch-mcp --session needs ARCH_AGENT_TICKET, which Arch sets for the agent sessions it starts.")) { try AgentCommandLine.mcpMode(["--session"], ticket: "") }
        #expect(throws: AgentUsageError(message: "arch-mcp takes no arguments other than --session.")) { try AgentCommandLine.mcpMode(["--stdio"], ticket: nil) }
    }

    @Test func theMCPInstructions() {
        let instructions = AgentHarness.mcpInstructions
        #expect(instructions.count <= 2_000)
        #expect(instructions.contains("Call guide first"))
        #expect(instructions.contains("<untrusted source=\"page\""))
        #expect(instructions.contains("approval_wait"))
        for tool in ["guide", "session_info", "snapshot", "approval_wait", "hand_to_user"] {
            #expect(AgentToolCatalog.tool(named: tool) != nil, "\(tool)")
        }
    }
}
