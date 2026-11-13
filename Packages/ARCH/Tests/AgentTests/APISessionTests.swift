// API-key sessions (VII.19, docs/agents.md, Sessions on the user's CLI ▸ API-key sessions) over a scripted AI client: the host's results as text, page, and image parts with their notes and the pages images show, refused results whose marking does not parse, the session's tools, harness, and output limit in each request, the model pinned from the first round, queued messages, Stop and the calls it cancels, a cut reply's notice, the round limit, failures that leave the session open, and a run over the tool host itself. The service's checks of those parts are `AITests`' `APIKeyLoopTests`.
import AgentControl
import AI
import ARCHEngine
import Foundation
import Testing
@testable import Agent

enum ClientStep: Sendable {
    case event(AIEvent)
    case fail(AIError)
    /// Waits until the request is cancelled.
    case hold
}

/// Answers each request with `reply(request number)`, from 0, and keeps the requests and how many streams ended early.
final class ScriptedClient: AIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [AIRequest] = []
    private var ended = 0
    private let reply: @Sendable (Int) -> [ClientStep]

    init(reply: @escaping @Sendable (Int) -> [ClientStep]) {
        self.reply = reply
    }

    var requests: [AIRequest] { lock.withLock { received } }
    var terminations: Int { lock.withLock { ended } }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        let number = lock.withLock {
            received.append(request)
            return received.count - 1
        }
        let steps = reply(number)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        switch step {
                        case .event(let event): continuation.yield(event)
                        case .fail(let error): throw error
                        case .hold: try await Task.sleep(for: .seconds(60))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] termination in
                task.cancel()
                if case .cancelled = termination { self?.lock.withLock { self?.ended += 1 } }
            }
        }
    }
}

@MainActor final class FakeSessionTools: AgentSessionTools {
    var tools = ["session_info", "list_tabs", "read_text"].compactMap(AgentToolCatalog.tool(named:))
    var answer: (AgentToolCall) -> AgentToolResult = { _ in AgentToolResult(status: .ok, text: "Done.") }
    /// Each call waits, as on an approval card, until its task is cancelled or 30 seconds pass.
    var waits = false
    private(set) var calls: [AgentToolCall] = []
    private(set) var cancelledCalls = 0

    func run(_ call: AgentToolCall) async -> AgentToolResult {
        calls.append(call)
        if waits {
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { cancelledCalls += 1 }
        }
        return answer(call)
    }
}

/// The tool host behind an outside client's grant, standing in for the session binding that plan task VII.17.1 adopts.
@MainActor final class GrantSessionTools: AgentSessionTools {
    let toolHost: AgentToolHost
    let grant: AgentGrant
    var handles = AgentGrantHandles()

    init(toolHost: AgentToolHost, grant: AgentGrant) {
        self.toolHost = toolHost
        self.grant = grant
    }

    var tools: [AgentTool] { AgentToolHost.tools(for: grant.level, scopes: grant.scopes) }

    func run(_ call: AgentToolCall) async -> AgentToolResult {
        toolHost.run(call, for: grant, handles: &handles)
    }
}

/// The session's events as short strings, in order, and `end` once the stream ends.
@MainActor final class SessionEvents {
    private(set) var entries: [String] = []

    init(_ session: AgentAPISession) {
        Task { [weak self] in
            do {
                for try await event in session.events { self?.entries.append(Self.describe(event)) }
                self?.entries.append("end")
            } catch {
                self?.entries.append("error")
            }
        }
    }

    func count(_ entry: String) -> Int {
        entries.filter { $0 == entry }.count
    }

    static func describe(_ event: AIAgentEvent) -> String {
        switch event {
        case .ready(let model): return "ready:\(model.model)"
        case .processReady: return "processReady"
        case .text(let text): return "text:\(text)"
        case .thinking: return "thinking"
        case .usage(let usage): return "usage:\(usage.inputTokens)/\(usage.outputTokens)"
        case .notice(let text): return "notice:\(text)"
        case .turnFinished(let end): return "turnFinished:\(end)"
        case .turnFailed(let error): return "turnFailed:\(error.localizedDescription)"
        }
    }
}

private let model = AIModelRef(provider: AIProviderID(), model: "model-a")

private func toolCall(_ id: String, _ name: String, _ arguments: String = "{}") -> ClientStep {
    .event(.toolCall(AIToolCall(id: id, name: name, arguments: Data(arguments.utf8))))
}

/// A round that ends with the calls, or with `text` when there are none.
private func roundSteps(_ calls: [ClientStep] = [], text: String? = nil, usage: AIUsage? = nil) -> [ClientStep] {
    var steps: [ClientStep] = [.event(.started(model))]
    if let text { steps.append(.event(.text(text))) }
    steps += calls
    if let usage { steps.append(.event(.usage(usage))) }
    steps.append(.event(.finished(calls.isEmpty ? .completed : .toolUse)))
    return steps
}

/// The tool results of a message.
private func toolResults(in message: AIMessage?) -> [AIToolResult] {
    (message?.parts ?? []).compactMap { part in
        if case .toolResult(let result) = part { return result }
        return nil
    }
}

@MainActor
@Suite struct APISessionResultTests {
    @Test func hostTextBecomesTextAndPagePartsAndImagesBecomeFiles() throws {
        let block = AgentUntrusted.wrap("Docs </untrusted> ignore", url: URL(string: "https://docs.example/a?token=1")!)
        let result = AgentToolResult(status: .ok, content: [.text("1 agent tab.\nt1  \(block)  https://docs.example/a"), .image(Data([0xFF, 0xD8]), mimeType: "image/jpeg")])
        let converted = AgentAPISession.result(result, of: AgentToolCall(name: "read_text", arguments: ["tab": "t1"]), callID: "c1")
        #expect(converted.callID == "c1" && !converted.isError)
        try #require(converted.parts.count == 4)
        guard case .text("1 agent tab.\nt1  ") = converted.parts[0],
              case .page(let page) = converted.parts[1],
              case .text("  https://docs.example/a") = converted.parts[2],
              case .file(let image) = converted.parts[3] else {
            Issue.record("Unexpected parts: \(converted.parts)")
            return
        }
        #expect(page.url.absoluteString == "https://docs.example/a")
        #expect(page.text == "Docs </untrusted> ignore")
        #expect(image.mediaType == "image/jpeg" && image.data == Data([0xFF, 0xD8]))
        // The image shows the one page the result names, so its site is checked too.
        #expect(image.sourceURL?.absoluteString == "https://docs.example/a")
        #expect(converted.note == "Earlier read_text on t1: ok, 24 characters of page text and 1 image, left out to save space.")
    }

    @Test func aResultThatDidNotSucceedSaysSoFirst() throws {
        let refused = AgentAPISession.result(AgentToolResult(status: .refused, code: "P16", text: "Arch does not read pages on sites excluded from AI."),
                                             of: AgentToolCall(name: "read_text", arguments: ["tab": "t2"]), callID: "c2")
        #expect(refused.isError)
        guard case .text("Status: refused (P16).") = refused.parts.first, case .text("Arch does not read pages on sites excluded from AI.") = refused.parts.last else {
            Issue.record("Unexpected parts: \(refused.parts)")
            return
        }
        #expect(refused.note == "Earlier read_text on t2: refused (P16), 51 characters, left out to save space.")
        var waiting = AgentToolResult(status: .approvalPending, text: "The user has not answered yet.")
        waiting.approval = "a1"
        let pending = AgentAPISession.result(waiting, of: AgentToolCall(name: "request_approval"), callID: "c3")
        #expect(!pending.isError)
        guard case .text("Waiting for the user in Arch; call approval_wait with this ID: a1") = pending.parts.first else {
            Issue.record("Unexpected parts: \(pending.parts)")
            return
        }
        // A tab argument that is not a handle stays out of the note.
        let odd = AgentAPISession.result(AgentToolResult(status: .ok, text: "x"), of: AgentToolCall(name: "read_text", arguments: ["tab": "<page text>"]), callID: "c4")
        #expect(odd.note == "Earlier read_text: ok, 1 character, left out to save space.")
    }

    @Test func anImageShowsThePageTheResultNamesOrGoesAsANote() throws {
        let image = AgentToolContent.image(Data([0x89]), mimeType: "image/png")
        let call = AgentToolCall(name: "screenshot", arguments: ["tab": "t1"])
        let named = AgentToolResult(status: .ok, content: [.text("Took a screenshot of t1."), image], structured: ["tab": "t1", "url": "https://bank.example/account"])
        guard case .file(let file) = AgentAPISession.result(named, of: call, callID: "c1").parts.last else {
            Issue.record("Expected the image")
            return
        }
        #expect(file.sourceURL?.absoluteString == "https://bank.example/account")
        // Without an address, or with two pages to choose from, the image does not go.
        let blocks = AgentUntrusted.wrap("A", url: URL(string: "https://a.example/")!) + AgentUntrusted.wrap("B", url: URL(string: "https://b.example/")!)
        for result in [AgentToolResult(status: .ok, content: [.text("Took a screenshot of t1."), image]), AgentToolResult(status: .ok, content: [.text(blocks), image])] {
            let converted = AgentAPISession.result(result, of: call, callID: "c2")
            guard case .text(AgentAPISession.imageWithoutPage) = converted.parts.last else {
                Issue.record("Unexpected parts: \(converted.parts)")
                return
            }
            #expect(converted.note == "Earlier screenshot on t1: ok, " + (converted.parts.count == 2 ? "1 image" : "2 characters of page text and 1 image") + ", left out to save space.")
        }
    }

    @Test func aMarkingThatDoesNotParseRefusesTheResultButArchsOwnTextGoesAsItIs() throws {
        let foreign = AgentToolResult(status: .ok, text: "t1  <untrusted source=\"page\" lang=\"en\" url=\"https://a.example/\">Title</untrusted>")
        let refused = AgentAPISession.result(foreign, of: AgentToolCall(name: "list_tabs"), callID: "c1")
        #expect(refused.isError)
        guard case .text(AgentAPISession.unreadableResult) = refused.parts.first, refused.parts.count == 1 else {
            Issue.record("Unexpected parts: \(refused.parts)")
            return
        }
        // The guide quotes the marking with an ellipsis for the address, which is no page.
        let guide = AgentAPISession.result(AgentHarness.guideResult(arguments: [:]), of: AgentToolCall(name: "guide"), callID: "c2")
        #expect(!guide.isError)
        guard case .text(AgentHarness.instructions) = guide.parts.first, guide.parts.count == 1 else {
            Issue.record("Unexpected parts: \(guide.parts)")
            return
        }
        #expect(AgentAPISession.arguments(Data()) == [:])
        #expect(AgentAPISession.arguments(Data("[1]".utf8)) == nil)
    }
}

@MainActor
@Suite struct APISessionTurnTests {
    @Test func aMessageRunsItsCallsThroughTheSessionsToolsOnThePinnedModel() async throws {
        let client = ScriptedClient { number in
            switch number {
            case 0: return roundSteps([toolCall("c1", "list_tabs", #"{"scope":"agent"}"#)], usage: AIUsage(inputTokens: 1, outputTokens: 2))
            case 1: return roundSteps(text: "Done.", usage: AIUsage(inputTokens: 3, outputTokens: 4))
            default: return roundSteps(text: "Again.")
            }
        }
        let tools = FakeSessionTools()
        let session = AgentAPISession(client: client, tools: tools)
        let events = SessionEvents(session)
        session.send("Summarize t1.")
        try await waitUntil { events.entries.contains("turnFinished:completed") }
        #expect(events.entries == ["ready:model-a", "text:Done.", "usage:4/6", "turnFinished:completed"])
        #expect(tools.calls == [AgentToolCall(name: "list_tabs", arguments: ["scope": "agent"])])
        let first = try #require(client.requests.first)
        #expect(first.feature == .agent && first.instructions == AgentHarness.instructions && first.pinnedModel == nil)
        #expect(first.maxOutputTokens == AgentAPISession.outputTokensPerRound)
        #expect(first.tools.map(\.name) == ["session_info", "list_tabs", "read_text"])
        let schema = try AgentJSON.decode(try #require(first.tools.last?.inputSchema))
        #expect(schema == AgentToolCatalog.tool(named: "read_text")?.inputSchema)
        // The second round is pinned by the loop; the session keeps the model for the next message.
        #expect(client.requests[1].pinnedModel == model)
        #expect(session.model == model)
        #expect(session.conversation.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(toolResults(in: session.conversation[2]).first?.callID == "c1")

        session.send("And again.")
        try await waitUntil { events.count("turnFinished:completed") == 2 }
        let third = client.requests[2]
        #expect(third.pinnedModel == model)
        #expect(third.messages.count == 5)
        guard case .text("And again.") = third.messages.last?.parts.first else {
            Issue.record("Expected the new message last")
            return
        }
        #expect(events.count("ready:model-a") == 1)
    }

    @Test func messagesSentDuringATurnWaitAndStopDropsThem() async throws {
        let client = ScriptedClient { number in
            number == 0 ? [.event(.started(model)), .event(.text("Working")), .hold] : roundSteps(text: "Later.")
        }
        let session = AgentAPISession(client: client, tools: FakeSessionTools())
        let events = SessionEvents(session)
        session.send("First.")
        try await waitUntil { events.entries.contains("text:Working") }
        session.send("Queued.")
        #expect(session.queuedMessages == ["Queued."])
        session.stop()
        #expect(!session.isTurnRunning && session.queuedMessages.isEmpty)
        try await waitUntil { events.entries.last == "turnFinished:stopped" }
        try await waitUntil { client.terminations == 1 }
        session.send("Next.")
        try await waitUntil { events.entries.contains("turnFinished:completed") }
        #expect(client.requests.count == 2)
        #expect(events.entries == ["ready:model-a", "text:Working", "turnFinished:stopped", "text:Later.", "turnFinished:completed"])
        // The stopped turn keeps only the user's message.
        #expect(session.conversation.map(\.role) == [.user, .user, .assistant])
    }

    @Test func stopCancelsACallThatWaitsAndDropsItsResult() async throws {
        let client = ScriptedClient { number in number == 0 ? roundSteps([toolCall("c1", "session_info")]) : roundSteps(text: "Later.") }
        let tools = FakeSessionTools()
        tools.waits = true
        let session = AgentAPISession(client: client, tools: tools)
        let events = SessionEvents(session)
        session.send("Wait.")
        try await waitUntil { tools.calls.count == 1 }
        session.stop()
        try await waitUntil { tools.cancelledCalls == 1 }
        try await waitUntil { events.entries.last == "turnFinished:stopped" }
        #expect(client.requests.count == 1)
        #expect(session.conversation.map(\.role) == [.user])
    }

    @Test func aReplyCutAtTheOutputLimitSaysSo() async throws {
        let client = ScriptedClient { _ in [.event(.started(model)), .event(.text("Cut")), .event(.finished(.lengthLimit))] }
        let session = AgentAPISession(client: client, tools: FakeSessionTools())
        let events = SessionEvents(session)
        session.send("Write a lot.")
        try await waitUntil { events.entries.contains("turnFinished:completed") }
        #expect(events.entries == ["ready:model-a", "text:Cut", "notice:\(AgentAPISession.outputLimitNotice)", "turnFinished:completed"])
    }

    @Test func theRoundLimitEndsTheTurnAndTheSessionGoesOn() async throws {
        let client = ScriptedClient { number in
            number < AgentAPISession.roundsPerMessage ? roundSteps([toolCall("c\(number)", "session_info")]) : roundSteps(text: "Fine.")
        }
        let tools = FakeSessionTools()
        let session = AgentAPISession(client: client, tools: tools)
        let events = SessionEvents(session)
        session.send("Loop.")
        try await waitUntil { events.entries.contains("turnFinished:turnLimit") }
        #expect(client.requests.count == 50)
        #expect(tools.calls.count == 49)
        session.send("Stop looping.")
        try await waitUntil { events.entries.contains("turnFinished:completed") }
        #expect(events.entries.suffix(2) == ["text:Fine.", "turnFinished:completed"])
    }

    @Test func aFailedMessageLeavesTheSessionOpen() async throws {
        let client = ScriptedClient { number in
            number == 0 ? [.fail(.providerUnavailable(AIProviderID(), detail: "down"))] : roundSteps(text: "Back.")
        }
        let session = AgentAPISession(client: client, tools: FakeSessionTools())
        let events = SessionEvents(session)
        session.send("Hello.")
        try await waitUntil { events.entries.contains { $0.hasPrefix("turnFailed:") } }
        #expect(session.model == nil)
        session.send("Hello again.")
        try await waitUntil { events.entries.contains("turnFinished:completed") }
        #expect(events.entries.dropFirst() == ["ready:model-a", "text:Back.", "turnFinished:completed"])
        session.end()
        try await waitUntil { events.entries.last == "end" }
        session.send("After the end.")
        #expect(client.requests.count == 2)
    }

    @Test func argumentsThatAreNotAnObjectNeverReachTheHost() async throws {
        let client = ScriptedClient { number in
            number == 0 ? roundSteps([toolCall("c1", "list_tabs", "[1]"), toolCall("c2", "session_info", "")]) : roundSteps(text: "Ok.")
        }
        let tools = FakeSessionTools()
        let session = AgentAPISession(client: client, tools: tools)
        let events = SessionEvents(session)
        session.send("Go.")
        try await waitUntil { events.entries.contains("turnFinished:completed") }
        #expect(tools.calls == [AgentToolCall(name: "session_info")])
        let results = toolResults(in: client.requests[1].messages.last)
        #expect(results.map(\.isError) == [true, false])
        guard case .text("The arguments of list_tabs are not a JSON object.") = results.first?.parts.first else {
            Issue.record("Expected the arguments error")
            return
        }
    }

    @Test func aRunOverTheToolHostSendsTitlesAsPagesAndExcludedTabsByHandle() async throws {
        let host = FakeHost()
        let docs = AgentTabInfo(id: UUID(), spaceID: nil, title: "Docs", url: URL(string: "https://docs.example/a?token=1")!, isLoading: false, engine: .webKit)
        let excluded = AgentTabInfo(id: UUID(), spaceID: nil, title: "Secret plans", url: URL(string: "https://excluded.example/plans")!, isLoading: false, engine: .chromium)
        host.tabs = [docs, excluded]
        let grant = AgentGrant(client: AgentClientIdentity(key: .unsigned(path: "/opt/agent", codeHash: "00"), name: "agent", executablePath: "/opt/agent", host: nil, isInterpreter: false),
                               personaID: FakeHost.defaultPersona.id, spaceID: UUID(), level: .readOnly, scopes: AgentGrantScopes(), expiry: .whenArchQuits, grantedAt: Date())
        let tools = GrantSessionTools(toolHost: AgentToolHost(host: host, allowsAI: { $0.host != "excluded.example" }), grant: grant)
        tools.handles.agentTabIDs = [docs.id, excluded.id]
        let client = ScriptedClient { number in number == 0 ? roundSteps([toolCall("c1", "list_tabs")]) : roundSteps(text: "Two tabs.") }
        let session = AgentAPISession(client: client, tools: tools)
        let events = SessionEvents(session)
        session.send("Which tabs?")
        try await waitUntil { events.entries.contains("turnFinished:completed") }
        #expect(client.requests[0].tools.map(\.name) == AgentToolHost.servedTools)
        let parts = try #require(toolResults(in: client.requests[1].messages.last).first?.parts)
        let pages = parts.compactMap { part -> AIPageContent? in
            if case .page(let page) = part { return page }
            return nil
        }
        #expect(pages.map(\.url.absoluteString) == ["https://docs.example/a"])
        #expect(pages.map(\.text) == ["Docs"])
        let text = parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined()
        #expect(text.contains("t2  (a site excluded from AI)"))
        #expect(!text.contains("Secret plans") && !text.contains("token") && !text.contains("excluded.example"))
    }
}
