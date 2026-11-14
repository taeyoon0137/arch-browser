// JSON-RPC 2.0 messages and `hello`: each kind of message written and read back, the errors for text that is not a JSON-RPC message, and `hello`'s answer in each status, flat on the wire.
import AgentControl
import Foundation
import Testing

@Suite struct RPCTests {
    private func object(_ message: AgentRPCMessage) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: message.encoded()) as! [String: Any]
    }

    @Test func eachKindOfMessageRoundTrips() throws {
        let messages: [AgentRPCMessage] = [
            .request(id: .number(7), method: "tools/call", params: ["name": "snapshot", "arguments": ["tab": "t1"]]),
            .request(id: .string("a-1"), method: "tools/list", params: nil),
            .notification(method: "progress", params: ["call": 7, "message": "Waiting for your approval in Arch"]),
            .result(id: .number(7), result: ["status": "ok"]),
            .error(id: .number(8), error: .methodNotFound("task/start")),
            .error(id: nil, error: AgentRPCError(code: -32000, message: "busy", data: ["limit": 4])),
        ]
        for message in messages {
            #expect(try AgentRPCMessage.decode(message.encoded()) == message)
            #expect(try object(message)["jsonrpc"] as? String == "2.0")
        }
        #expect(try object(.notification(method: "revoked", params: nil))["id"] == nil)
        #expect(try object(.error(id: nil, error: .parseError()))["id"] is NSNull)
        #expect(try object(.request(id: .number(1), method: "hello", params: nil))["id"] as? Int == 1)
    }

    @Test func textThatIsNotJSONIsAParseError() {
        #expect(throws: AgentRPCError.parseError()) { try AgentRPCMessage.decode(Data("{\"jsonrpc\":".utf8)) }
        #expect(throws: AgentRPCError.parseError()) { try AgentRPCMessage.decode(Data()) }
    }

    @Test(arguments: [
        #"[{"jsonrpc":"2.0","id":1,"method":"hello"}]"#,
        #"{"id":1,"method":"hello"}"#,
        #"{"jsonrpc":"1.0","id":1,"method":"hello"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":7}"#,
        #"{"jsonrpc":"2.0","id":1.5,"method":"hello"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"hello","params":"x"}"#,
        #"{"jsonrpc":"2.0","id":1}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"x"}}"#,
        #"{"jsonrpc":"2.0","result":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"message":"x"}}"#,
    ])
    func jsonThatIsNotAMessageIsAnInvalidRequest(text: String) {
        #expect {
            try AgentRPCMessage.decode(Data(text.utf8))
        } throws: { ($0 as? AgentRPCError)?.code == AgentRPCError.invalidRequestCode }
    }

    @Test func theStandardErrorCodes() {
        #expect(AgentRPCError.parseErrorCode == -32700)
        #expect(AgentRPCError.invalidRequestCode == -32600)
        #expect(AgentRPCError.methodNotFoundCode == -32601)
        #expect(AgentRPCError.invalidParamsCode == -32602)
        #expect(AgentRPCError.internalErrorCode == -32603)
    }

    @Test func helloCarriesTheProtocolVersionAndTheTicketOnlyWhenThereIsOne() throws {
        #expect(AgentControlProtocol.version == 1)
        let outside = try AgentJSON(encoding: AgentHello(client: .cli, version: "0.1.0"))
        #expect(outside == ["protocol": 1, "client": "arch-cli", "version": "0.1.0"])
        let session = try AgentJSON(encoding: AgentHello(client: .mcp, version: "0.1.0", ticket: "abc"))
        #expect(session["client"] == "arch-mcp")
        #expect(session["ticket"] == "abc")
    }

    @Test func helloAnswersAreFlatOnTheWire() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let answers: [(AgentHelloAnswer, AgentJSON)] = [
            (AgentHelloAnswer(version: "0.1.0", status: .bound), ["protocol": 1, "version": "0.1.0", "status": "bound"]),
            (AgentHelloAnswer(version: "0.1.0", status: .noGrant), ["protocol": 1, "version": "0.1.0", "status": "none"]),
            (AgentHelloAnswer(version: "0.1.0", status: .granted(AgentGrantSummary(level: .readOnly, persona: "Agents", expiry: .whenArchQuits))),
             ["protocol": 1, "version": "0.1.0", "status": "granted", "grant": ["level": "readOnly", "persona": "Agents", "expiry": "quit"]]),
            (AgentHelloAnswer(version: "0.1.0", status: .granted(AgentGrantSummary(level: .actInAgentTabs, persona: "Work", expiry: .at(date))))
             , ["protocol": 1, "version": "0.1.0", "status": "granted", "grant": ["level": "actInAgentTabs", "persona": "Work", "expiry": "2027-01-15T08:00:00Z"]]),
            (AgentHelloAnswer(version: "0.1.0", status: .granted(AgentGrantSummary(level: .askBeforeActing, persona: "Work", expiry: .whenRevoked)))
             , ["protocol": 1, "version": "0.1.0", "status": "granted", "grant": ["level": "askBeforeActing", "persona": "Work", "expiry": "revoke"]]),
            (AgentHelloAnswer(version: "0.1.0", status: .granted(AgentGrantSummary(level: .readOnly, persona: "Agents", space: "Home", expiry: .whenArchQuits)))
             , ["protocol": 1, "version": "0.1.0", "status": "granted", "grant": ["level": "readOnly", "persona": "Agents", "space": "Home", "expiry": "quit"]]),
            (AgentHelloAnswer(protocol: 2, version: "0.2.0", status: .refused(AgentRefusal(reason: .protocolMismatch, message: "Arch speaks version 2."))),
             ["protocol": 2, "version": "0.2.0", "status": "refused", "refusal": ["reason": "protocol", "message": "Arch speaks version 2."]]),
        ]
        for (answer, json) in answers {
            #expect(try AgentJSON(encoding: answer) == json)
            #expect(try json.decode(as: AgentHelloAnswer.self) == answer)
        }
        let unknown: AgentJSON = ["protocol": 1, "version": "0.1.0", "status": "refused", "refusal": ["reason": "later", "message": "No."]]
        #expect(try unknown.decode(as: AgentHelloAnswer.self).status == .refused(AgentRefusal(reason: AgentRefusal.Reason(rawValue: "later"), message: "No.")))
        #expect(throws: (any Error).self) { try (["protocol": 1, "version": "0.1.0", "status": "maybe"] as AgentJSON).decode(as: AgentHelloAnswer.self) }
    }
}
