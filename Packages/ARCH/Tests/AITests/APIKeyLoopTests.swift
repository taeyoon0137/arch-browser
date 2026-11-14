// The API-key loop (docs/agents.md, Sessions on the user's CLI ▸ API-key sessions) through the scripted provider: the pinned model, tool requests only on HTTP models that take tools, results more than eight rounds old as notes, older results as notes while a request passes its model's input limit, images until a reply follows a request that carried them and only on the `messages` format, results the part checks refuse, and the round limit with a conversation that can go on.
import Foundation
import Testing
@testable import AI

private let loopFeature = AIFeature(id: AIFeatureID(rawValue: "test.loop"), name: "Loop Test", summary: "", trigger: .user, data: AIDataScope(kinds: [.page, .file]), requirements: [.agent])

/// A service whose models answer each request with `steps(model, request)`, `request` counting every request the service sent, from 1.
@MainActor
private func loopService(_ providers: [AIProviderConfiguration], log: ProviderLog, steps: @escaping @MainActor (_ model: String, _ request: Int) -> [Step]) -> AIService {
    let service = stubService(providers: providers) { configuration in
        let request = log.requests.count + 1
        let script = Dictionary(uniqueKeysWithValues: configuration.models.map { ($0.name, steps($0.name, request)) })
        return ScriptedProvider(configuration: configuration, script: script, log: log)
    }
    service.register(loopFeature)
    return service
}

private func call(_ number: Int, _ name: String = "read") -> AIToolCall {
    AIToolCall(id: "call_\(number)", name: name, arguments: Data("{}".utf8))
}

private func callSteps(_ calls: AIToolCall...) -> [Step] {
    calls.map { .event(.toolCall($0)) } + [.event(.finished(.toolUse))]
}

private let replySteps: [Step] = [.event(.text("done")), .event(.finished(.completed))]

private func handler(_ name: String = "read", _ perform: @escaping @Sendable (AIToolCall) async -> AIToolResult) -> AIToolHandler {
    AIToolHandler(tool: AITool(name: name, description: "", inputSchema: Data(#"{"type":"object"}"#.utf8))) { await perform($0) }
}

/// Each tool result of a message as `callID:ok|error:` and its parts: `text:…`, `page:<address>`, or `file:<type>`.
private func results(in message: AIMessage?) -> [String] {
    (message?.parts ?? []).compactMap { part in
        guard case .toolResult(let result) = part else { return nil }
        let parts = result.parts.map { part -> String in
            switch part {
            case .text(let text): return "text:\(text)"
            case .page(let page): return "page:\(page.url.absoluteString)"
            case .file(let file): return "file:\(file.mediaType)"
            default: return "other"
            }
        }
        return "\(result.callID):\(result.isError ? "error" : "ok"):" + parts.joined(separator: "|")
    }
}

/// The conversations `run` reported, kept for the test to read after the stream ends.
private final class ConversationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[AIMessage]] = []

    func record(_ messages: [AIMessage]) {
        lock.withLock { entries.append(messages) }
    }

    var last: [AIMessage]? { lock.withLock { entries.last } }
    var count: Int { lock.withLock { entries.count } }
}

@MainActor
@Suite struct PinnedModelTests {
    private let first = provider("First", models: [AIModelConfiguration(name: "primary"), AIModelConfiguration(name: "fallback")])

    private func routed(log: ProviderLog, steps: @escaping @MainActor (String, Int) -> [Step]) -> AIService {
        let service = loopService([first], log: log, steps: steps)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "primary"), AIModelRef(provider: first.id, model: "fallback")]), for: loopFeature.id)
        return service
    }

    @Test func everyRoundStaysOnTheModelThatServedTheFirst() async {
        let log = ProviderLog()
        // The primary is down for the first request only; the later rounds still go to the fallback that served the first round.
        let service = routed(log: log) { model, request in
            switch (model, request) {
            case ("primary", 1): return [.fail(.providerUnavailable(AIProviderID(), detail: "down"))]
            case ("primary", _): return [.event(.text("from the primary")), .event(.finished(.completed))]
            case (_, 2): return callSteps(call(1))
            default: return replySteps
            }
        }
        let result = await collect(service.run(textRequest(loopFeature), tools: [handler { AIToolResult(callID: $0.id, parts: [.text("ok")]) }]))
        #expect(result.error == nil)
        #expect(log.requests.map(\.model) == ["primary", "fallback", "fallback"])
        #expect(result.events.contains("text:done"))
        #expect(!result.events.contains("text:from the primary"))
    }

    @Test func aPinnedModelHasNoFallback() async {
        let log = ProviderLog()
        let service = routed(log: log) { model, _ in
            model == "primary" ? [.fail(.providerUnavailable(AIProviderID(), detail: "down"))] : replySteps
        }
        var request = textRequest(loopFeature)
        request.pinnedModel = AIModelRef(provider: first.id, model: "primary")
        guard case .providerUnavailable = await collect(service.stream(request)).error else {
            Issue.record("Expected providerUnavailable")
            return
        }
        #expect(log.requests.map(\.model) == ["primary"])
    }

    @Test func aPinnedModelMustStillServeTheFeature() async {
        let log = ProviderLog()
        let service = routed(log: log) { _, _ in replySteps }
        var request = textRequest(loopFeature)
        request.pinnedModel = AIModelRef(provider: first.id, model: "removed")
        guard case .notConfigured(.noUsableModel) = await collect(service.stream(request)).error else {
            Issue.record("Expected noUsableModel")
            return
        }
        // A model the route does not list may serve when pinned, as one the user picks for a session.
        request.pinnedModel = AIModelRef(provider: first.id, model: "fallback")
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: first.id, model: "primary")]), for: loopFeature.id)
        #expect(await collect(service.stream(request)).error == nil)
        #expect(log.requests.map(\.model) == ["fallback"])
        service.settings.setRoute(AIRoute(isEnabled: false), for: loopFeature.id)
        guard case .notConfigured(.switchedOff) = await collect(service.stream(request)).error else {
            Issue.record("Expected switchedOff")
            return
        }
    }

    @Test func aRequestWithToolsUsesOnlyModelsThatTakeTools() async {
        let mixed = provider("Mixed", models: [AIModelConfiguration(name: "plain", capabilities: [.jsonOutput]), AIModelConfiguration(name: "capable")])
        let log = ProviderLog()
        let service = loopService([mixed], log: log) { _, _ in replySteps }
        service.register(userFeature)
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: mixed.id, model: "plain"), AIModelRef(provider: mixed.id, model: "capable")]), for: userFeature.id)
        _ = await collect(service.stream(textRequest(userFeature)))
        _ = await collect(service.run(textRequest(userFeature), tools: [handler { AIToolResult(callID: $0.id, parts: [.text("ok")]) }]))
        #expect(log.requests.map(\.model) == ["plain", "capable"])
        var pinned = textRequest(userFeature)
        pinned.pinnedModel = AIModelRef(provider: mixed.id, model: "plain")
        pinned.tools = [AITool(name: "read", description: "", inputSchema: Data("{}".utf8))]
        guard case .notConfigured(.noUsableModel) = await collect(service.stream(pinned)).error else {
            Issue.record("Expected noUsableModel")
            return
        }
    }

    @Test func aCommandLineModelWithAToolCallsOverrideNeverServesARequestWithTools() async {
        // Settings lets the user turn on Tool calls for a command-line model too.
        let cli = AIProviderConfiguration(name: "Claude Code", kind: .commandLine(AICommandLineConfiguration(executable: URL(fileURLWithPath: "/bin/cat"), agent: .claudeCode)),
                                          models: [AIModelConfiguration(name: "sonnet", capabilities: [.jsonOutput, .tools])])
        let http = provider("HTTP", models: [AIModelConfiguration(name: "capable")])
        let log = ProviderLog()
        let service = loopService([cli, http], log: log) { _, _ in replySteps }
        service.settings.setRoute(AIRoute(isEnabled: true, models: [AIModelRef(provider: cli.id, model: "sonnet"), AIModelRef(provider: http.id, model: "capable")]), for: loopFeature.id)
        #expect(await collect(service.run(textRequest(loopFeature), tools: [handler { AIToolResult(callID: $0.id, parts: [.text("ok")]) }])).error == nil)
        #expect(log.requests.map(\.model) == ["capable"])
        var pinned = textRequest(loopFeature)
        pinned.pinnedModel = AIModelRef(provider: cli.id, model: "sonnet")
        pinned.tools = [AITool(name: "read", description: "", inputSchema: Data("{}".utf8))]
        guard case .notConfigured(.noUsableModel) = await collect(service.stream(pinned)).error else {
            Issue.record("Expected noUsableModel")
            return
        }
        #expect(log.requests.count == 1)
    }
}

@MainActor
@Suite struct ToolHistoryTests {
    private let only = provider("Only", models: [AIModelConfiguration(name: "model-a")])
    /// The format that carries images in tool results.
    private let imaging = provider("Images", models: [AIModelConfiguration(name: "model-i")], format: .messages)
    private let shot = handler("shot") { AIToolResult(callID: $0.id, parts: [.text("Took a screenshot."), .file(AIFile(name: "screenshot", mediaType: "image/jpeg", data: Data([0xFF, 0xD8])))]) }
    private let read = handler { AIToolResult(callID: $0.id, parts: [.text("ok")]) }

    @Test func resultsMoreThanEightRoundsOldGoAsTheirNotes() async throws {
        let log = ProviderLog()
        let service = loopService([only], log: log) { _, request in
            request <= 10 ? callSteps(call(request)) : replySteps
        }
        // Odd calls give their own note; even ones leave the default, which names the tool.
        let read = handler { call in
            let number = Int(call.id.dropFirst("call_".count)) ?? 0
            return AIToolResult(callID: call.id, parts: [.text("result \(number)")], note: number.isMultiple(of: 2) ? nil : "note \(number)")
        }
        let conversations = ConversationLog()
        let result = await collect(service.run(textRequest(loopFeature), tools: [read], maxRounds: 20) { conversations.record($0) })
        #expect(result.error == nil)
        #expect(log.requests.count == 11)
        // The tenth request carries nine rounds of results: the oldest is a note.
        let tenth = log.requests[9].messages.flatMap { results(in: $0) }
        #expect(tenth.first == "call_1:ok:text:note 1")
        #expect(tenth.dropFirst().allSatisfy { $0.hasPrefix("call_") && $0.contains(":text:result ") })
        let last = log.requests[10].messages.flatMap { results(in: $0) }
        #expect(last.count == 10)
        #expect(last[0] == "call_1:ok:text:note 1")
        #expect(last[1] == "call_2:ok:text:Earlier result of read, left out to save space.")
        #expect(Array(last[2...]) == (3...10).map { "call_\($0):ok:text:result \($0)" })
        // The kept conversation is what the last request sent, then the reply.
        let kept = try #require(conversations.last)
        #expect(kept.count == log.requests[10].messages.count + 1)
        #expect(kept.flatMap { results(in: $0) } == last)
        guard case .text("done") = kept.last?.parts.first, kept.last?.role == .assistant else {
            Issue.record("Expected the reply last")
            return
        }
        #expect(conversations.count == 11)
    }

    @Test func olderResultsGoAsNotesUntilTheRequestFitsTheModelsLimit() async throws {
        let small = provider("Small", models: [AIModelConfiguration(name: "model-s", inputCharacterLimit: 1_000)])
        let log = ProviderLog()
        let service = loopService([small], log: log) { _, request in request <= 6 ? callSteps(call(request)) : replySteps }
        let page = String(repeating: "p", count: 300)
        let read = handler { call in
            AIToolResult(callID: call.id, parts: [.page(AIPageContent(url: URL(string: "https://docs.example/\(call.id)")!, title: "", text: page))], note: "note \(call.id)")
        }
        #expect(await collect(service.run(textRequest(loopFeature), tools: [read])).error == nil)
        try #require(log.requests.count == 7)
        // Six results of 300 characters, all within eight rounds, pass the limit of 1,000: the oldest go as their notes until the request fits, and the newest go whole, none of their text cut.
        let seventh = log.requests[6].messages
        #expect(seventh.flatMap { results(in: $0) } == (1...3).map { "call_\($0):ok:text:note call_\($0)" } + (4...6).map { "call_\($0):ok:page:https://docs.example/call_\($0)" })
        let pages = seventh.flatMap(\.parts).flatMap { part -> [AIPageContent] in
            guard case .toolResult(let result) = part else { return [] }
            return result.parts.compactMap { if case .page(let page) = $0 { return page } else { return nil } }
        }
        #expect(pages.count == 3 && pages.allSatisfy { $0.text == page && !$0.isTruncated })
        #expect(AIPartPolicy.characterCount(of: seventh) <= 1_000)
    }

    @Test func resultsOfTextThatPassTheLimitStillLeaveARequest() async {
        let small = provider("Small", models: [AIModelConfiguration(name: "model-s", inputCharacterLimit: 1_000)])
        let log = ProviderLog()
        let service = loopService([small], log: log) { _, request in request <= 6 ? callSteps(call(request)) : replySteps }
        let text = String(repeating: "t", count: 300)
        // Text the host wrote cannot be cut, so without the notes every request from the fourth on would be too long.
        let read = handler { AIToolResult(callID: $0.id, parts: [.text(text)]) }
        let result = await collect(service.run(textRequest(loopFeature), tools: [read]))
        #expect(result.error == nil)
        #expect(result.events.last == "finished:completed")
        #expect(log.requests.last.map { $0.messages.flatMap { results(in: $0) } } == (1...4).map { "call_\($0):ok:text:Earlier result of read, left out to save space." } + (5...6).map { "call_\($0):ok:text:\(text)" })
    }

    @Test func imagesGoUntilAReplyFollowsTheRequestThatCarriedThem() async {
        let log = ProviderLog()
        let service = loopService([imaging], log: log) { _, request in
            switch request {
            case 1: return callSteps(call(1, "shot"))
            case 2: return callSteps(call(2))
            default: return replySteps
            }
        }
        #expect(await collect(service.run(textRequest(loopFeature), tools: [shot, read])).error == nil)
        #expect(results(in: log.requests[1].messages.last) == ["call_1:ok:text:Took a screenshot.|file:image/jpeg"])
        let third = log.requests[2].messages.flatMap { results(in: $0) }
        #expect(third == ["call_1:ok:text:Took a screenshot.|text:\(AIToolHistory.imageNote)", "call_2:ok:text:ok"])
    }

    @Test func anImageStaysWhenTheRequestThatCarriedItFails() async throws {
        let log = ProviderLog()
        let service = loopService([imaging], log: log) { _, request in
            switch request {
            case 1: return callSteps(call(1, "shot"))
            case 2: return [.fail(.providerUnavailable(AIProviderID(), detail: "down"))]
            case 3: return callSteps(call(2))
            default: return replySteps
            }
        }
        let conversations = ConversationLog()
        guard case .providerUnavailable = await collect(service.run(textRequest(loopFeature), tools: [shot, read]) { conversations.record($0) }).error else {
            Issue.record("Expected providerUnavailable")
            return
        }
        // No reply followed the request that carried the image, so the next message's request carries it again.
        var next = textRequest(loopFeature, "Go on.")
        next.messages = try #require(conversations.last) + next.messages
        #expect(await collect(service.run(next, tools: [shot, read])).error == nil)
        #expect(log.requests[2].messages.flatMap { results(in: $0) } == ["call_1:ok:text:Took a screenshot.|file:image/jpeg"])
        #expect(log.requests[3].messages.flatMap { results(in: $0) } == ["call_1:ok:text:Took a screenshot.|text:\(AIToolHistory.imageNote)", "call_2:ok:text:ok"])
    }

    @Test func aModelThatCannotTakeAnImageInAResultGetsANoteInstead() async {
        let textOnly = provider("Text", models: [AIModelConfiguration(name: "model-t", capabilities: [.tools])])
        // A chat-completions model with images still gets a tool result as text.
        let chat = provider("Chat", models: [AIModelConfiguration(name: "model-c")])
        for (configuration, note) in [(textOnly, AIService.imageNotTakenNote), (chat, AIService.imageNotInToolResultsNote)] {
            let log = ProviderLog()
            let service = loopService([configuration], log: log) { _, request in request == 1 ? callSteps(call(1, "shot")) : replySteps }
            #expect(await collect(service.run(textRequest(loopFeature), tools: [shot])).error == nil)
            #expect(results(in: log.requests[1].messages.last) == ["call_1:ok:text:Took a screenshot.|text:\(note)"])
        }
    }

    @Test func aToolResultFromAnExcludedSiteIsRefused() async throws {
        let log = ProviderLog()
        let service = loopService([only], log: log) { _, request in
            switch request {
            case 1: return callSteps(call(1))
            case 2: return callSteps(call(2))
            default: return replySteps
            }
        }
        service.settings.excludedSites.append(AISitePattern("other.example.com"))
        let read = handler { [service] call in
            if call.id == "call_1" {
                return AIToolResult(callID: call.id, parts: [.text("Read t1."), .page(AIPageContent(url: URL(string: "https://news.example.org/a?q=1")!, title: "", text: "secret page text"))])
            }
            // After the first result went whole, the user excludes its site.
            await MainActor.run { service.settings.excludedSites.append(AISitePattern("example.org")) }
            return AIToolResult(callID: call.id, parts: [.page(AIPageContent(url: URL(string: "https://other.example.com/b#top")!, title: "", text: "other text"))])
        }
        let result = await collect(service.run(textRequest(loopFeature), tools: [read]))
        #expect(result.error == nil)
        #expect(result.events.last == "finished:completed")
        #expect(results(in: log.requests[1].messages.last) == ["call_1:ok:text:Read t1.|page:https://news.example.org/a"])
        try #require(service.activity.count == 3)
        #expect(service.activity[1].content.contains("secret page text"))
        // The first result's site was excluded after it was sent, and the second's before it arrived: the next request refuses both.
        let refused = "text:\(AIService.refusal(.siteExcluded("")))"
        #expect(log.requests[2].messages.flatMap { results(in: $0) } == ["call_1:error:\(refused)", "call_2:error:\(refused)"])
        let content = service.activity[2].content
        #expect(!content.contains("secret page text"))
        #expect(!content.contains("other text"))
        #expect(!content.contains("news.example.org"))
    }

    @Test func anImageFromASiteExcludedWhileItsCallRanIsRefused() async {
        let log = ProviderLog()
        let service = loopService([imaging], log: log) { _, request in request == 1 ? callSteps(call(1, "shot")) : replySteps }
        let shot = handler("shot") { [service] call in
            // The call waits, as on an approval card, and meanwhile the user excludes the page's site.
            await MainActor.run { service.settings.excludedSites.append(AISitePattern("bank.example")) }
            return AIToolResult(callID: call.id, parts: [.text("Took a screenshot of t1."),
                                                         .file(AIFile(name: "screenshot", mediaType: "image/png", data: Data([0x89]), sourceURL: URL(string: "https://bank.example/account")!))])
        }
        #expect(await collect(service.run(textRequest(loopFeature), tools: [shot])).error == nil)
        #expect(results(in: log.requests[1].messages.last) == ["call_1:error:text:\(AIService.refusal(.siteExcluded("")))"])
    }

    @Test func aResultOfAKindTheFeatureDoesNotSendIsRefused() async {
        let log = ProviderLog()
        let service = loopService([only], log: log) { _, request in request == 1 ? callSteps(call(1)) : replySteps }
        service.register(userFeature)
        let read = handler { AIToolResult(callID: $0.id, parts: [.download(AIDownloadInfo(filename: "a.zip"))]) }
        #expect(await collect(service.run(textRequest(userFeature), tools: [read])).error == nil)
        #expect(results(in: log.requests[1].messages.last) == ["call_1:error:text:\(AIService.refusal(.dataNotDeclared(.download)))"])
    }

    @Test func theRoundLimitLeavesAConversationThatCanGoOn() async throws {
        let log = ProviderLog()
        let service = loopService([only], log: log) { _, request in [.event(.text("step \(request)"))] + callSteps(call(request)) }
        let calls = ConversationLog()
        let read = handler { call in
            calls.record([])
            return AIToolResult(callID: call.id, parts: [.text("ok")])
        }
        let conversations = ConversationLog()
        guard case .toolRoundLimit = await collect(service.run(textRequest(loopFeature), tools: [read], maxRounds: 50) { conversations.record($0) }).error else {
            Issue.record("Expected toolRoundLimit")
            return
        }
        #expect(log.requests.count == 50)
        #expect(calls.count == 49)
        let kept = try #require(conversations.last)
        // Every tool call has its result, and the last round's text stays without its call.
        for (index, message) in kept.enumerated() where message.parts.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
            #expect(!results(in: kept[index + 1]).isEmpty)
        }
        guard case .text("step 50") = kept.last?.parts.first, kept.last?.parts.count == 1, kept.last?.role == .assistant else {
            Issue.record("Expected the last round's text alone")
            return
        }
    }
}
