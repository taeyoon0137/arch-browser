// Providers reached over HTTP in one of the two message formats. The transport is shared: an ephemeral `URLSession` that refuses redirects to another host, a server-sent event reader with its timeouts, and the mapping from HTTP failures to `AIError`.
import Foundation

/// Encodes requests for one HTTP message format and decodes its server-sent event stream. Each format is in its own file.
protocol AIWireCodec: Sendable {
    /// Appended to the base URL.
    static var path: String { get }
    static func body(for request: AIProviderRequest) throws -> Data
    init(provider: AIProviderID, output: AIOutputFormat)
    /// The events one server-sent event produces.
    mutating func decode(_ event: ServerSentEvent) throws -> [AIEvent]
    /// Called when the response ends: the closing events, or an error for a stream cut short.
    mutating func finish() throws -> [AIEvent]
}

struct HTTPProvider: AIProvider {
    let configuration: AIProviderConfiguration
    let http: AIHTTPConfiguration
    /// nil when the provider has no key, as for a model server on this Mac.
    let key: String?
    let session: URLSession
    var firstByteTimeout: Duration = .seconds(60)
    var chunkTimeout: Duration = .seconds(30)
    var maxTokensRefusals = MaxTokensRefusals.shared

    init(configuration: AIProviderConfiguration, http: AIHTTPConfiguration, key: String?, session: URLSession) {
        self.configuration = configuration
        self.http = http
        self.key = key
        self.session = session
    }

    func listModels() async throws -> [String] {
        do {
            let (data, response) = try await session.data(for: try makeRequest(path: "models", body: nil))
            try check(response, body: data)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let entries = object?["data"] as? [[String: Any]] else { throw AIError.malformedReply(localized("The model list has no data.")) }
            return entries.compactMap { $0["id"] as? String }
        } catch {
            throw mapped(error)
        }
    }

    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch http.format {
                    case .chatCompletions: try await sendChatCompletions(request, to: continuation)
                    case .messages: try await send(request, body: try MessagesCodec.body(for: request), codec: MessagesCodec.self, to: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Sending

    /// Sends `max_tokens` unless the model refused it earlier in the launch. A 400 that refuses `max_tokens` sends the request once more with `max_completion_tokens`, which the model's later requests then send at once. The 400 comes before any event, so the caller sees one reply.
    private func sendChatCompletions(_ request: AIProviderRequest, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        let model = MaxTokensRefusals.Model(provider: configuration.id, baseURL: http.baseURL, name: request.model)
        if !maxTokensRefusals.contains(model) {
            do {
                return try await send(request, body: try ChatCompletionsCodec.body(for: request, outputLimit: .maxTokens), codec: ChatCompletionsCodec.self, to: continuation)
            } catch is MaxTokensRefused {
                maxTokensRefusals.insert(model)
            }
        }
        try await send(request, body: try ChatCompletionsCodec.body(for: request, outputLimit: .maxCompletionTokens), codec: ChatCompletionsCodec.self, to: continuation)
    }

    private func send<Codec: AIWireCodec>(_ request: AIProviderRequest, body: Data, codec: Codec.Type, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        let urlRequest = try makeRequest(path: Codec.path, body: body)
        let timer = StallTimer(timeout: firstByteTimeout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    try check(response, body: try await Self.collect(bytes, limit: 65_536))
                }
                var decoder = Codec(provider: configuration.id, output: request.output)
                var parser = ServerSentEventParser()
                for try await line in ServerSentLines(base: bytes) {
                    timer.extend(by: chunkTimeout)
                    guard let event = parser.feed(line) else { continue }
                    for decoded in try decoder.decode(event) { continuation.yield(decoded) }
                }
                if let event = parser.flush() {
                    for decoded in try decoder.decode(event) { continuation.yield(decoded) }
                }
                // A stream that ends because the request was cancelled is not a cut stream.
                try Task.checkCancellation()
                for decoded in try decoder.finish() { continuation.yield(decoded) }
            }
            group.addTask { [provider = configuration.id] in
                try await timer.watch(provider: provider)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func makeRequest(path: String, body: Data?) throws -> URLRequest {
        guard AIHTTPConfiguration.isAllowedBaseURL(http.baseURL) else {
            throw AIError.invalidRequest(localized("The base URL must use https, or http for a server on this Mac."))
        }
        var request = URLRequest(url: http.baseURL.appendingPathComponent(path))
        for (name, value) in http.headers { request.setValue(value, forHTTPHeaderField: name) }
        if let key, !key.isEmpty {
            for (name, value) in http.format.authorizationHeaders(key: key) { request.setValue(value, forHTTPHeaderField: name) }
        }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return request
    }

    // MARK: Failures

    /// A `chatCompletions` 400 that refuses `max_tokens`. `sendChatCompletions` answers it with `max_completion_tokens`; a refusal of that request too becomes `invalidRequest`.
    private struct MaxTokensRefused: Error {
        var message: String
    }

    /// Throws the `AIError` for a response that is not a success, or `MaxTokensRefused`.
    private func check(_ response: URLResponse, body: Data) throws {
        guard let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) else { return }
        let info = ProviderErrorInfo(json: try? JSONSerialization.jsonObject(with: body))
        let message = info.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        let provider = configuration.id
        switch response.statusCode {
        case 300..<400:
            throw AIError.invalidRequest(localized("The server redirected the request to another address."))
        case 400:
            if info.saysInputTooLong { throw AIError.contextTooLong(provider) }
            // The `messages` format has no other field for the limit.
            if http.format == .chatCompletions, info.refusesMaxTokens { throw MaxTokensRefused(message: message) }
            throw AIError.invalidRequest(message)
        case 401, 403:
            throw AIError.authentication(provider)
        case 404:
            throw AIError.invalidRequest(message)
        case 408, 409, 500...:
            throw AIError.providerUnavailable(provider, detail: message)
        case 413:
            throw AIError.contextTooLong(provider)
        case 429:
            throw AIError.rateLimited(provider, until: Self.retryDate(response.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw AIError.invalidRequest(message)
        }
    }

    /// Network failures and timeouts make the provider unavailable; cancellation stays cancellation.
    private func mapped(_ error: any Error) -> AIError {
        switch error {
        case let error as AIError:
            return redacted(error)
        case let refusal as MaxTokensRefused:
            return .invalidRequest(redacted(refusal.message))
        case is CancellationError:
            return .cancelled
        case let error as URLError where error.code == .cancelled:
            return .cancelled
        case let error as URLError:
            return .providerUnavailable(configuration.id, detail: error.localizedDescription)
        default:
            return .providerUnavailable(configuration.id, detail: redacted(error.localizedDescription))
        }
    }

    /// The error with the key taken out of the provider's messages it carries, from an error response or a stream's error event, so that a provider that echoes the key never carries it into the interface.
    private func redacted(_ error: AIError) -> AIError {
        switch error {
        case .providerUnavailable(let provider, let detail): return .providerUnavailable(provider, detail: redacted(detail))
        case .invalidRequest(let message): return .invalidRequest(redacted(message))
        case .refused(let message): return .refused(redacted(message))
        case .malformedReply(let message): return .malformedReply(redacted(message))
        default: return error
        }
    }

    private func redacted(_ text: String) -> String {
        guard let key, !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "\u{2026}")
    }

    /// The longest cool-down a `Retry-After` header sets.
    static let maximumRetryAfter: TimeInterval = 24 * 60 * 60

    /// `Retry-After` in seconds or as an HTTP date, at most `maximumRetryAfter` ahead. Seconds that are not a finite number, such as `inf`, which `TimeInterval` reads, give no date.
    static func retryDate(_ value: String?, now: Date = Date()) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) {
            guard seconds.isFinite else { return nil }
            return now + min(max(seconds, 0), maximumRetryAfter)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { min($0, now + maximumRetryAfter) }
    }

    // MARK: Reading

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }
}

/// Lines without their `\n` or `\r\n`, including the blank lines that end server-sent events, which `AsyncLineSequence` drops. UTF-8 is decoded per line, so a character split across chunks stays whole.
struct ServerSentLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    let base: Base

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var line: [UInt8] = []
        var isDone = false

        mutating func next() async throws -> String? {
            guard !isDone else { return nil }
            while let byte = try await base.next() {
                guard byte == 0x0A else {
                    line.append(byte)
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                return text
            }
            isDone = true
            return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

/// Throws once no output has arrived for the current timeout: the first timeout until the first output, then the timeout each `extend(by:)` sets. HTTP providers extend it for each line, command-line tools for each read.
final class StallTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: ContinuousClock.Instant

    init(timeout: Duration) {
        deadline = .now + timeout
    }

    func extend(by timeout: Duration) {
        lock.lock()
        defer { lock.unlock() }
        deadline = .now + timeout
    }

    private var currentDeadline: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return deadline
    }

    func watch(provider: AIProviderID) async throws {
        while true {
            let deadline = currentDeadline
            if ContinuousClock.now >= deadline {
                throw AIError.providerUnavailable(provider, detail: localized("The provider stopped responding."))
            }
            try await Task.sleep(until: deadline, clock: .continuous)
        }
    }
}

/// Refuses redirects that change the scheme, host, or port, so a key never reaches a host other than the base URL's.
final class AIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let target = request.url
        let isSameOrigin = original?.scheme == target?.scheme && original?.host == target?.host && original?.port == target?.port
        completionHandler(isSameOrigin ? request : nil)
    }

    /// No cookies, cache, or stored credentials.
    static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: AIRedirectGuard(), delegateQueue: nil)
    }
}

// MARK: - Server-sent events

struct ServerSentEvent: Equatable {
    var event: String?
    /// The event's `data:` lines joined with newlines.
    var data: String
}

/// Collects `event:` and `data:` lines; a blank line ends an event. Comment lines and other fields are skipped.
struct ServerSentEventParser {
    private var event: String?
    private var data: [String] = []

    mutating func feed(_ line: String) -> ServerSentEvent? {
        if line.isEmpty { return flush() }
        guard !line.hasPrefix(":") else { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// Ends the event in progress, as when the stream ends without a final blank line.
    mutating func flush() -> ServerSentEvent? {
        defer {
            event = nil
            data = []
        }
        guard !data.isEmpty else { return nil }
        return ServerSentEvent(event: event, data: data.joined(separator: "\n"))
    }
}

// MARK: - Provider error bodies

/// The `type`, `code`, `param`, and `message` of an error object, from an error response or a stream `error` event, in either format.
struct ProviderErrorInfo {
    var type: String?
    var code: String?
    /// The request field the error is about, which `chatCompletions` servers name.
    var param: String?
    var message: String?

    init(json: Any?) {
        let object = json as? [String: Any]
        let error = object?["error"] as? [String: Any] ?? object
        type = error?["type"] as? String
        code = (error?["code"] as? String) ?? (error?["code"] as? Int).map(String.init)
        param = error?["param"] as? String
        message = error?["message"] as? String
    }

    /// Whether the error type or code says the input is too long.
    var saysInputTooLong: Bool {
        [type, code].compactMap { $0?.lowercased() }.contains { $0.contains("context_length") || $0.contains("too_long") || $0.contains("too_large") }
    }

    /// Whether the error refuses `max_tokens`: it names the field as its `param`, or its message asks for `max_completion_tokens`.
    var refusesMaxTokens: Bool {
        param == ChatCompletionsCodec.OutputLimitField.maxTokens.rawValue || message?.contains(ChatCompletionsCodec.OutputLimitField.maxCompletionTokens.rawValue) == true
    }

    /// A stream `error` event mapped by its type, otherwise `providerUnavailable`.
    func streamError(provider: AIProviderID) -> AIError {
        let kind = (type ?? code ?? "").lowercased()
        if kind.contains("authentication") || kind.contains("permission") { return .authentication(provider) }
        if kind.contains("rate_limit") { return .rateLimited(provider, until: nil) }
        if saysInputTooLong { return .contextTooLong(provider) }
        if kind.contains("invalid_request") || kind.contains("not_found") { return .invalidRequest(message ?? kind) }
        return .providerUnavailable(provider, detail: message ?? (kind.isEmpty ? localized("The stream reported an error.") : kind))
    }
}

extension JSONSerialization {
    /// A JSON Schema or arguments value as an object for a request body.
    static func requestValue(_ data: Data) throws -> Any {
        do {
            return try jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw AIError.invalidRequest(localized("A schema or tool argument is not valid JSON."))
        }
    }

    /// A tool call's arguments, joined from their pieces, as a JSON object.
    static func toolArguments(_ text: String) throws -> Data {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : text
        let data = Data(text.utf8)
        guard (try? jsonObject(with: data)) is [String: Any] else { throw AIError.malformedReply(localized("A tool call\u{2019}s arguments are not a JSON object.")) }
        return data
    }
}
