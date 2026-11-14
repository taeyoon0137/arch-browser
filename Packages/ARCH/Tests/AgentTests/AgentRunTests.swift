// The agent run's plain values (docs/hooks.md, The call): the JSON of `AgentRunOptions`, `AgentRunLimits`, `AgentRunGrant`, `AgentRunRecord`, `AgentRunTabAccess`, and `AgentRunResult` against fixed text, with `closedTab`, the grant's `minimumRecord` and `returnsReply`, the defaults an omitted member takes, and the order of tab access and record levels.
import AI
import Foundation
import Testing
@testable import Agent

@Suite struct AgentRunTests {
    private let tab = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let provider = AIProviderID(rawValue: "6F1C")

    private func text(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func tabAccessAndRecordLevelsHaveTheirNamesAndOrder() throws {
        #expect(try text(AgentRunTabAccess.title) == #""title""#)
        #expect(try text(AgentRunTabAccess.page) == #""page""#)
        #expect(AgentRunTabAccess.title < .page)
        #expect(try text(AgentRunRecord.none) == #""none""#)
        #expect(try text(AgentRunRecord.activity) == #""activity""#)
        #expect(try text(AgentRunRecord.session) == #""session""#)
        #expect(AgentRunRecord.none < .activity && AgentRunRecord.activity < .session)
        #expect(try decode(AgentRunRecord.self, #""session""#) == .session)
    }

    @Test func limitsAreInSecondsWithDefaultsForOmittedMembers() throws {
        #expect(try text(AgentRunLimits(timeout: .seconds(20), rounds: 1, toolCalls: 2)) == #"{"rounds":1,"timeout":20,"toolCalls":2}"#)
        #expect(try text(AgentRunLimits(timeout: .milliseconds(1_500))) == #"{"rounds":2,"timeout":1.5,"toolCalls":5}"#)
        #expect(try decode(AgentRunLimits.self, "{}") == AgentRunLimits())
        #expect(AgentRunLimits() == AgentRunLimits(timeout: .seconds(30), rounds: 2, toolCalls: 5))
        #expect(try decode(AgentRunLimits.self, #"{"timeout":2.5,"rounds":3}"#) == AgentRunLimits(timeout: .milliseconds(2_500), rounds: 3, toolCalls: 5))
    }

    @Test func optionsHaveFixedJSONWithTheClosedTab() throws {
        let options = AgentRunOptions(prompt: "Name the tab.", model: .tier(.fast), tools: ["rename_tab"], limits: AgentRunLimits(timeout: .seconds(20), rounds: 1, toolCalls: 2),
                                      closedTab: tab)
        let json = #"{"closedTab":"00000000-0000-0000-0000-0000000000C1","dryRun":false,"limits":{"rounds":1,"timeout":20,"toolCalls":2},"model":{"tier":"fast"},"#
            + #""prompt":"Name the tab.","record":"none","tabAccess":"title","tools":["rename_tab"]}"#
        #expect(try text(options) == json)
        #expect(try decode(AgentRunOptions.self, json) == options)

        let models = AgentRunOptions(prompt: "Read it.", tabAccess: .page, model: .models([AIModelRef(provider: provider, model: "model-a")]), record: .session,
                                     tools: ["read_text", "snapshot"], dryRun: true)
        #expect(try text(models) == #"{"dryRun":true,"limits":{"rounds":2,"timeout":30,"toolCalls":5},"model":{"models":[{"model":"model-a","provider":"6F1C"}]},"#
            + #""prompt":"Read it.","record":"session","tabAccess":"page","tools":["read_text","snapshot"]}"#)
    }

    @Test func optionsNeedTheirPromptModelTabAccessAndToolsAndDefaultTheRest() throws {
        let decoded = try decode(AgentRunOptions.self, #"{"prompt":"Name it.","model":{"tier":"standard"},"tabAccess":"title","tools":[]}"#)
        #expect(decoded == AgentRunOptions(prompt: "Name it.", model: .tier(.standard), tools: []))
        #expect(decoded.record == .none && decoded.closedTab == nil && !decoded.dryRun && decoded.limits == AgentRunLimits())
        for missing in [#"{"model":{"tier":"fast"},"tabAccess":"title","tools":[]}"#, #"{"prompt":"p","tabAccess":"title","tools":[]}"#,
                        #"{"prompt":"p","model":{"tier":"fast"},"tools":[]}"#, #"{"prompt":"p","model":{"tier":"fast"},"tabAccess":"title"}"#] {
            #expect(throws: DecodingError.self) { try decode(AgentRunOptions.self, missing) }
        }
    }

    @Test func aGrantHasFixedJSONWithItsRecordFloorAndReply() throws {
        let program = AgentRunGrant(tools: ["rename_tab", "read_text"], tabAccess: .page, minimumRecord: .activity, maximumRecord: .session, runsPerDay: 50,
                                    limits: AgentRunLimits(timeout: .seconds(60), rounds: 4, toolCalls: 10), returnsReply: false)
        let json = #"{"limits":{"rounds":4,"timeout":60,"toolCalls":10},"maximumRecord":"session","minimumRecord":"activity","returnsReply":false,"runsPerDay":50,"#
            + #""tabAccess":"page","tools":["read_text","rename_tab"]}"#
        #expect(try text(program) == json)
        #expect(try decode(AgentRunGrant.self, json) == program)
        let user = AgentRunGrant(tools: ["rename_tab"])
        #expect(user.minimumRecord == .none && user.maximumRecord == .session && user.runsPerDay == 200 && user.returnsReply && user.tabAccess == .title)
    }

    @Test func grantChecksToolsRecordBoundsAndLimitsAtThePointOfUse() throws {
        let grant = AgentRunGrant(tools: ["rename_tab", "read_text", "snapshot"], tabAccess: .page, minimumRecord: .activity, maximumRecord: .activity)
        let allowed = AgentRunOptions(prompt: "Name the tab.", model: .tier(.fast), record: .activity, tools: ["rename_tab"])
        #expect(grant.refusal(for: allowed) == nil)
        let changes: [(inout AgentRunOptions) -> Void] = [
            { $0.tools = ["read_text"] }, { $0.tools = ["snapshot"] }, { $0.tools = ["open_tab"] },
            { $0.record = .none }, { $0.record = .session }, { $0.limits.rounds += 1 },
            { $0.limits.toolCalls += 1 }, { $0.limits.timeout += .seconds(1) },
            { $0.limits.timeout = .zero }, { $0.limits.rounds = 0 }, { $0.limits.toolCalls = 0 },
            { $0.prompt = "  " }, { $0.prompt = String(repeating: "x", count: 4_001) }
        ]
        for change in changes {
            var options = allowed
            change(&options)
            #expect(grant.refusal(for: options) != nil)
        }
        var page = allowed
        page.tabAccess = .page
        page.tools = ["read_text"]
        #expect(grant.refusal(for: page) == nil)
        #expect(AgentRunGrant(tools: ["read_text"]).refusal(for: page) != nil)
        #expect(throws: DecodingError.self) { try decode(AgentRunLimits.self, #"{"timeout":1e300}"#) }
    }

    @Test func aResultHasFixedJSON() throws {
        let completed = AgentRunResult(status: .completed, actions: [.renamedTab(tab: tab, name: "Docs")], reply: "Done", model: AIModelRef(provider: provider, model: "model-a"),
                                       usage: AIUsage(inputTokens: 310, outputTokens: 12))
        #expect(try text(completed) == #"{"actions":[{"renamedTab":{"name":"Docs","tab":"00000000-0000-0000-0000-0000000000C1"}}],"model":{"model":"model-a","provider":"6F1C"},"#
            + #""reply":"Done","status":"completed","usage":{"cachedInputTokens":0,"inputTokens":310,"outputTokens":12}}"#)
        let refused = AgentRunResult(status: .refused, code: "notGranted", message: "This hook may not keep sessions.")
        let json = #"{"actions":[],"code":"notGranted","message":"This hook may not keep sessions.","status":"refused","usage":{"cachedInputTokens":0,"inputTokens":0,"outputTokens":0}}"#
        #expect(try text(refused) == json)
        let decoded = try decode(AgentRunResult.self, json)
        #expect(decoded.status == .refused && decoded.code == "notGranted" && decoded.actions.isEmpty && decoded.reply == nil && decoded.keptRun == nil)
        #expect(AgentRunAction.renamedTab(tab: tab, name: "Docs").kind == "renameTab")
        #expect(AIFeatureID.agentHook(tab).rawValue == "agentHook.00000000-0000-0000-0000-0000000000C1")
    }
}
