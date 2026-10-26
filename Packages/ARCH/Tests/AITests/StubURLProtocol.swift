// Test doubles that keep every test off the network and out of the Keychain: a URL protocol that replays hand-written responses, an in-memory key store, a scripted provider, the run's folder for the tests' files, and helpers to build services and read streams.
import Foundation
@testable import AI

/// Answers every request to a host with one scripted response, delivered in the given chunks. Each test makes its own host, so tests can run in parallel.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        /// Fails the load after the chunks, as a dropped connection does.
        var failure: URLError.Code?
    }

    struct CapturedRequest {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private static let lock = NSLock()
    private static var replies: [String: Reply] = [:]
    private static var captured: [String: [CapturedRequest]] = [:]

    /// A new host that answers with `reply`.
    static func host(replying reply: Reply) -> String {
        let host = "\(UUID().uuidString.lowercased()).example.test"
        lock.lock()
        replies[host] = reply
        lock.unlock()
        return host
    }

    static func requests(to host: String) -> [CapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured[host] ?? []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AIRedirectGuard.makeSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.lock.lock()
        let reply = Self.replies[host] ?? Reply(status: 599)
        Self.captured[host, default: []].append(CapturedRequest(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request)))
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands the body to the protocol as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Server-sent events as response chunks: each event ends with a blank line.
func sse(_ events: [String]) -> [Data] {
    events.map { Data("\($0)\n\n".utf8) }
}

final class InMemoryKeys: AIKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [AIProviderID: String] = [:]

    func key(for provider: AIProviderID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[provider]
    }

    func setKey(_ key: String, for provider: AIProviderID, label: String) throws {
        lock.lock()
        keys[provider] = key
        lock.unlock()
    }

    func removeKey(for provider: AIProviderID) throws {
        lock.lock()
        keys[provider] = nil
        lock.unlock()
    }
}

// MARK: - Scripted provider

/// One step of a scripted reply.
enum Step: Sendable {
    case event(AIEvent)
    case fail(AIError)
    case sleep(Duration)
}

/// What scripted providers received, shared by every provider of one service.
final class ProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AIProviderRequest] = []
    private var terminatedCount = 0

    func record(_ request: AIProviderRequest) {
        lock.lock()
        entries.append(request)
        lock.unlock()
    }

    func terminated() {
        lock.lock()
        terminatedCount += 1
        lock.unlock()
    }

    var requests: [AIProviderRequest] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var terminations: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminatedCount
    }
}

/// Replays the steps scripted for the requested model name.
struct ScriptedProvider: AIProvider {
    let configuration: AIProviderConfiguration
    let script: [String: [Step]]
    let log: ProviderLog

    func listModels() async throws -> [String] {
        configuration.models.map(\.name)
    }

    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        log.record(request)
        let steps = script[request.model] ?? [.event(.finished(.completed))]
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        switch step {
                        case .event(let event): continuation.yield(event)
                        case .fail(let error): throw error
                        case .sleep(let duration): try await Task.sleep(for: duration)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [log] _ in
                task.cancel()
                log.terminated()
            }
        }
    }
}

/// The folder that holds every test's files in this run, which the run removes as it exits. The tests' folders stay until then, since the stores that write them and the tools a test starts can write after the test ends.
let testRunFolder: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchAITests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    atexit { try? FileManager.default.removeItem(at: testRunFolder) }
    return url
}()

/// The path of a new folder in the run's folder. The caller, or the store it hands the path to, creates the folder.
func temporaryDirectory() -> URL {
    testRunFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

func provider(_ name: String, models: [AIModelConfiguration], format: AIWireFormat = .chatCompletions, baseURL: String = "https://models.example.test/v1") -> AIProviderConfiguration {
    AIProviderConfiguration(name: name, kind: .http(AIHTTPConfiguration(format: format, baseURL: URL(string: baseURL)!)), models: models)
}

/// A service in a new folder whose providers replay `script`.
@MainActor
func scriptedService(providers: [AIProviderConfiguration], script: [String: [Step]], log: ProviderLog = ProviderLog()) -> AIService {
    stubService(providers: providers) { configuration in
        ScriptedProvider(configuration: configuration, script: script, log: log)
    }
}

/// A service in a new folder that serves each request with the provider `makeProvider` makes for it.
@MainActor
func stubService(providers: [AIProviderConfiguration], makeProvider: @escaping @MainActor (AIProviderConfiguration) -> any AIProvider) -> AIService {
    let directory = temporaryDirectory()
    let keys = InMemoryKeys()
    let settings = AISettingsStore(fileURL: directory.appendingPathComponent("ai.json"), keys: keys)
    settings.providers = providers
    return AIService(settings: settings, usage: AIUsageStore(fileURL: directory.appendingPathComponent("ai-usage.json")), keys: keys) { configuration, _ in
        makeProvider(configuration)
    }
}

let userFeature = AIFeature(id: AIFeatureID(rawValue: "test.user"), name: "User Test", summary: "", trigger: .user, data: AIDataScope(kinds: [.page, .selection]))
let automaticFeature = AIFeature(id: AIFeatureID(rawValue: "hook.test"), name: "Automatic Test", summary: "", trigger: .automatic, data: .textOnly)

func textRequest(_ feature: AIFeature, _ text: String = "Hello") -> AIRequest {
    AIRequest(feature: feature.id, messages: [AIMessage(role: .user, parts: [.text(text)])])
}

/// The stream's events as short strings, and the error it ended with.
func collect(_ stream: AsyncThrowingStream<AIEvent, any Error>) async -> (events: [String], error: AIError?) {
    var events: [String] = []
    do {
        for try await event in stream { events.append(describe(event)) }
        return (events, nil)
    } catch {
        return (events, error as? AIError)
    }
}

func describe(_ event: AIEvent) -> String {
    switch event {
    case .waiting(.queued): return "waiting:queued"
    case .waiting(.rateLimited): return "waiting:rateLimited"
    case .started(let ref): return "started:\(ref.model)"
    case .text(let text): return "text:\(text)"
    case .toolCall(let call): return "toolCall:\(call.id):\(call.name):\(String(decoding: call.arguments, as: UTF8.self))"
    case .usage(let usage): return "usage:\(usage.inputTokens)/\(usage.outputTokens)/\(usage.cachedInputTokens)"
    case .finished(let reason): return "finished:\(reason)"
    }
}
