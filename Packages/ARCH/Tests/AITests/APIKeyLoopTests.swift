// The API-key loop (docs/agents.md, Sessions on the user's CLI ▸ API-key sessions) through the scripted provider: the pinned model, tool requests only on models that take tools, results more than eight rounds old as notes, images only in the round after their call, results the part checks refuse, and the round limit with a conversation that can go on.
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
}

@MainActor
@Suite struct ToolHistoryTests {
    private let only = provider("Only", models: [AIModelConfiguration(name: "model-a")])

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

    @Test func imagesGoOnlyInTheRoundAfterTheirCall() async {
        let log = ProviderLog()
        let service = loopService([only], log: log) { _, request in
            switch request {
            case 1: return callSteps(call(1, "shot"))
            case 2: return callSteps(call(2))
            default: return replySteps
            }
        }
        let shot = handler("shot") { AIToolResult(callID: $0.id, parts: [.text("Took a screenshot."), .file(AIFile(name: "screenshot", mediaType: "image/jpeg", data: Data([0xFF, 0xD8])))]) }
        let read = handler { AIToolResult(callID: $0.id, parts: [.text("ok")]) }
        #expect(await collect(service.run(textRequest(loopFeature), tools: [shot, read])).error == nil)
        #expect(results(in: log.requests[1].messages.last) == ["call_1:ok:text:Took a screenshot.|file:image/jpeg"])
        let third = log.requests[2].messages.flatMap { results(in: $0) }
        #expect(third == ["call_1:ok:text:Took a screenshot.|text:\(AIToolHistory.imageNote)", "call_2:ok:text:ok"])
    }

    @Test func aModelWithoutImagesGetsANoteInstead() async {
        let textOnly = provider("Text", models: [AIModelConfiguration(name: "model-t", capabilities: [.tools])])
        let log = ProviderLog()
        let service = loopService([textOnly], log: log) { _, request in request == 1 ? callSteps(call(1, "shot")) : replySteps }
        let shot = handler("shot") { AIToolResult(callID: $0.id, parts: [.text("Took a screenshot."), .file(AIFile(name: "screenshot", mediaType: "image/png", data: Data([0x89])))]) }
        #expect(await collect(service.run(textRequest(loopFeature), tools: [shot])).error == nil)
        #expect(results(in: log.requests[1].messages.last) == ["call_1:ok:text:Took a screenshot.|text:\(AIService.imageNotTakenNote)"])
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
        service.settings.excludedSites.append(AISitePattern("example.org"))
        let read = handler { [service] call in
            if call.id == "call_1" {
                return AIToolResult(callID: call.id, parts: [.text("Read t1."), .page(AIPageContent(url: URL(string: "https://news.example.org/a?q=1")!, title: "", text: "secret page text"))])
            }
            // Between the second round and the third, the user excludes the second result's site.
            await MainActor.run { service.settings.excludedSites.append(AISitePattern("other.example.com")) }
            return AIToolResult(callID: call.id, parts: [.page(AIPageContent(url: URL(string: "https://other.example.com/b#top")!, title: "", text: "other text"))])
        }
        let result = await collect(service.run(textRequest(loopFeature), tools: [read]))
        #expect(result.error == nil)
        #expect(result.events.last == "finished:completed")
        let refused = "text:\(AIService.refusal(.siteExcluded("")))"
        #expect(results(in: log.requests[1].messages.last) == ["call_1:error:\(refused)"])
        #expect(log.requests[2].messages.flatMap { results(in: $0) } == ["call_1:error:\(refused)", "call_2:error:\(refused)"])
        let content = try #require(service.activity.last?.content)
        #expect(!content.contains("secret page text"))
        #expect(!content.contains("other text"))
        #expect(!content.contains("news.example.org"))
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
