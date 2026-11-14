// Command-line tools as providers. Each request runs the configured tool without a window. The prompt goes to standard input, never into the arguments, which other processes can read, and the reply comes back on standard output as plain text or JSON lines. The user installs the tool and signs in to it in the built-in terminal. The Claude Code and Codex presets run with the arguments Arch builds and the output decoders of their sessions, with every tool off (`docs/agents.md`, Ordinary requests).
import Darwin
import Foundation

struct CommandLineProvider: AIProvider {
    let configuration: AIProviderConfiguration
    let tool: AICommandLineConfiguration
    var firstOutputTimeout: Duration = .seconds(120)
    var outputTimeout: Duration = .seconds(60)

    /// A tool has no model list of its own; the user names its models in Settings.
    func listModels() async throws -> [String] {
        configuration.models.map(\.name)
    }

    func stream(_ request: AIProviderRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, to: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? AIError.cancelled : AIError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Running

    /// Runs the tool in a new empty folder under TMPDIR, removed once the tool has ended. Cancellation ends the tool's process group.
    private func run(_ request: AIProviderRequest, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        let input = Data(try Self.prompt(for: request).utf8)
        let invocation = try await invocation(for: request)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Arch-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // A folder that cannot be made, as on a full disk, keeps the tool from starting; it is not a request the tool refused.
            throw AIError.providerUnavailable(configuration.id, detail: "\(tool.executable.lastPathComponent) could not start. \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let process: CommandLineProcess
        do {
            process = try CommandLineProcess(executable: tool.executable, arguments: invocation.arguments,
                                             environment: invocation.environment, directory: directory, input: input)
        } catch let error as POSIXError {
            throw AIError.providerUnavailable(configuration.id, detail: "\(tool.executable.lastPathComponent) could not start (\(String(cString: strerror(error.code.rawValue)))).")
        }
        do {
            try await withTaskCancellationHandler {
                try await read(process, decoder: invocation.decoder, to: continuation)
            } onCancel: {
                process.terminate()
            }
        } catch {
            process.terminate()
            _ = await process.termination()
            throw error
        }
    }

    /// The arguments, environment, and output decoder of one request: the configured ones, or those Arch builds for a preset after its probes.
    private struct Invocation {
        var arguments: [String]
        var environment: [String: String]
        var decoder: any CommandLineReplyDecoder
    }

    private func invocation(for request: AIProviderRequest) async throws -> Invocation {
        let environment = await tool.runEnvironment()
        guard let kind = tool.agent else {
            return Invocation(arguments: tool.arguments(forModel: request.model), environment: environment,
                              decoder: CommandLineOutputDecoder(output: tool.output, provider: configuration.id))
        }
        let probe: AIAgentProbeResult
        do {
            probe = try await AIAgentProbeStore.shared.result(kind: kind, executable: tool.executable, environment: environment)
        } catch let error as AIAgentToolError {
            throw error.aiError(provider: configuration.id)
        }
        switch kind {
        case .claudeCode:
            let decoder = ClaudeCodeStreamDecoder(check: ClaudeCodeStartCheck(session: nil), provider: configuration.id)
            return Invocation(arguments: ClaudeCodeAgent.ordinaryArguments(model: request.model), environment: ClaudeCodeAgent.ordinaryEnvironment(environment),
                              decoder: AgentReplyDecoder(stream: .claudeCode(decoder)))
        case .codex:
            return Invocation(arguments: CodexAgent.ordinaryArguments(disabled: probe.disabledFeatures, model: request.model), environment: environment,
                              decoder: AgentReplyDecoder(stream: .codex(CodexStreamDecoder(isSession: false, provider: configuration.id))))
        }
    }

    /// Passes on the reply as standard output arrives, within the output timeouts, then checks how the tool ended.
    private func read(_ process: CommandLineProcess, decoder: any CommandLineReplyDecoder, to continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        let timer = StallTimer(timeout: firstOutputTimeout)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [outputTimeout] in
                var decoder = decoder
                for await chunk in process.output {
                    timer.extend(by: outputTimeout)
                    for event in try decoder.decode(chunk) { continuation.yield(event) }
                }
                // Output also ends when this task is cancelled.
                try Task.checkCancellation()
                try await checkTermination(of: process)
                for event in try decoder.finish() { continuation.yield(event) }
                guard decoder.hasReply else { throw AIError.malformedReply("The tool printed no reply.") }
                continuation.yield(.finished(.completed))
            }
            group.addTask { [provider = configuration.id] in
                try await timer.watch(provider: provider)
            }
            do {
                try await group.next()
            } catch {
                // A reader waiting for the tool to exit finishes once the tool is ended.
                process.terminate()
                throw error
            }
            group.cancelAll()
        }
    }

    /// A tool that fails usually says why on standard error, so its last line becomes the error's detail. A tool ended by a timeout or cancellation passes nothing more on.
    private func checkTermination(of process: CommandLineProcess) async throws {
        let termination = await process.termination()
        try Task.checkCancellation()
        let name = tool.executable.lastPathComponent
        let reason: String
        switch termination {
        case .exited(0): return
        case .exited(let code): reason = "\(name) exited with status \(code)."
        case .signaled(let signal): reason = "\(name) stopped on signal \(signal)."
        }
        throw AIError.providerUnavailable(configuration.id, detail: await process.lastErrorLine() ?? reason)
    }

    // MARK: Input

    /// The request as text: the instructions, then each message labeled `User:` or `Assistant:` with its parts as delimited blocks. A JSON reply is asked for in the instructions. Tools read only text files.
    private static func prompt(for request: AIProviderRequest) throws -> String {
        if let file = unreadableFile(in: request.messages.flatMap(\.parts)) {
            throw AIError.invalidRequest("This tool cannot read \(file.name).")
        }
        var request = request
        if case .json(let schema) = request.output {
            let note = "Reply with only one JSON value that matches this JSON Schema, and no other text:\n\(String(decoding: schema, as: UTF8.self))"
            request.instructions = [request.instructions, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return AIPartText.transcript(of: request)
    }

    private static func unreadableFile(in parts: [AIPart]) -> AIFile? {
        for part in parts {
            switch part {
            case .file(let file) where AIPartText.text(of: file) == nil:
                return file
            case .toolResult(let result):
                if let file = unreadableFile(in: result.parts) { return file }
            default:
                continue
            }
        }
        return nil
    }

}

extension AICommandLineConfiguration {
    /// The arguments for one request: `{model}` becomes the model's name, and an argument containing it is left out for the tool's default model.
    func arguments(forModel model: String) -> [String] {
        arguments.compactMap { argument in
            guard argument.contains(Self.modelPlaceholder) else { return argument }
            return model.isEmpty ? nil : argument.replacingOccurrences(of: Self.modelPlaceholder, with: model)
        }
    }
}

// MARK: - Output

/// Turns a tool's standard output into reply events.
protocol CommandLineReplyDecoder: Sendable {
    /// Whether any reply text has been passed on.
    var hasReply: Bool { get }
    mutating func decode(_ chunk: Data) throws -> [AIEvent]
    /// Called once the tool has exited.
    mutating func finish() throws -> [AIEvent]
}

/// A preset's ordinary request read with its session decoder: the reply's text and usage pass on, and an `init` that fails the start check, a forbidden item, or a failed turn ends the request.
struct AgentReplyDecoder: CommandLineReplyDecoder {
    enum Stream {
        case claudeCode(ClaudeCodeStreamDecoder)
        case codex(CodexStreamDecoder)
    }

    private var stream: Stream
    private var lines = AIAgentLineBuffer()
    private(set) var hasReply = false

    init(stream: Stream) {
        self.stream = stream
    }

    mutating func decode(_ chunk: Data) throws -> [AIEvent] {
        try lines.lines(in: chunk).flatMap { try decode(line: $0) }
    }

    mutating func finish() throws -> [AIEvent] {
        try lines.finish().map { try decode(line: $0) } ?? []
    }

    private mutating func decode(line: Data) throws -> [AIEvent] {
        guard let object = agentJSONObject(line) else { return [] }
        let events: [AIAgentStreamEvent]
        switch stream {
        case .claudeCode(var decoder):
            events = try decoder.decode(object)
            stream = .claudeCode(decoder)
        case .codex(var decoder):
            events = try decoder.decode(object)
            stream = .codex(decoder)
        }
        return try events.compactMap { event in
            switch event {
            case .text(let text):
                hasReply = true
                return .text(text)
            case .usage(let usage):
                return .usage(usage)
            case .turnFailed(let error):
                throw error
            case .started, .output, .reportedModel, .thinking, .notice, .turnEnded:
                return nil
            }
        }
    }
}

/// Turns standard output into reply events: plain text a line at a time, or the fields JSON lines name. Output is split into lines before it is decoded as UTF-8, so a character split between reads stays whole, and a reply printed all at once at the end reads like a streamed one.
struct CommandLineOutputDecoder: CommandLineReplyDecoder {
    let output: AICommandLineOutput
    let provider: AIProviderID
    /// Whether any reply text has been passed on.
    private(set) var hasReply = false
    /// Bytes after the last newline.
    private var partialLine = Data()
    /// Blank lines since the last line of text; they are passed on only when more text follows, so the reply has no blank lines at either end.
    private var blankLines = 0
    private var hasDelta = false
    private var finalText: String?
    private var inputTokens: Int?
    private var outputTokens: Int?

    init(output: AICommandLineOutput, provider: AIProviderID) {
        self.output = output
        self.provider = provider
    }

    mutating func decode(_ chunk: Data) throws -> [AIEvent] {
        partialLine.append(chunk)
        var events: [AIEvent] = []
        var start = partialLine.startIndex
        while let newline = partialLine[start...].firstIndex(of: 0x0A) {
            events += try decode(line: partialLine[start..<newline])
            start = partialLine.index(after: newline)
        }
        partialLine = Data(partialLine[start...])
        return events
    }

    /// The last line, if it had no newline, then the final text when no delta arrived, and the usage the tool reported.
    mutating func finish() throws -> [AIEvent] {
        var events = partialLine.isEmpty ? [] : try decode(line: partialLine)
        partialLine = Data()
        if !hasDelta, let finalText, !finalText.isEmpty {
            hasReply = true
            events.append(.text(finalText))
        }
        if inputTokens != nil || outputTokens != nil {
            events.append(.usage(AIUsage(inputTokens: inputTokens ?? 0, outputTokens: outputTokens ?? 0)))
        }
        return events
    }

    private mutating func decode(line bytes: Data) throws -> [AIEvent] {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        switch output {
        case .text: return text(line).map { [.text($0)] } ?? []
        case .jsonLines(let paths): return try fields(of: line, at: paths)
        }
    }

    private mutating func text(_ line: String) -> String? {
        guard !line.isEmpty else {
            if hasReply { blankLines += 1 }
            return nil
        }
        defer {
            hasReply = true
            blankLines = 0
        }
        return hasReply ? String(repeating: "\n", count: blankLines + 1) + line : line
    }

    /// Lines that are not JSON objects, such as progress messages, are skipped.
    private mutating func fields(of line: String, at paths: AIJSONLinePaths) throws -> [AIEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return [] }
        if let message = paths.error.flatMap({ Self.value(at: $0, in: object) }).flatMap(Self.errorMessage) {
            throw AIError.providerUnavailable(provider, detail: message)
        }
        if let tokens = paths.inputTokens.flatMap({ Self.value(at: $0, in: object) }) as? NSNumber { inputTokens = tokens.intValue }
        if let tokens = paths.outputTokens.flatMap({ Self.value(at: $0, in: object) }) as? NSNumber { outputTokens = tokens.intValue }
        if let text = paths.finalText.flatMap({ Self.value(at: $0, in: object) }) as? String { finalText = text }
        guard let delta = paths.textDelta.flatMap({ Self.value(at: $0, in: object) }) as? String, !delta.isEmpty else { return [] }
        hasDelta = true
        hasReply = true
        return [.text(delta)]
    }

    /// The value at a dotted path, where a number picks an array element.
    private static func value(at path: String, in object: Any) -> Any? {
        path.split(separator: ".").reduce(Optional(object)) { current, key in
            if let dictionary = current as? [String: Any] { return dictionary[String(key)] }
            if let array = current as? [Any], let index = Int(key), array.indices.contains(index) { return array[index] }
            return nil
        }
    }

    /// The text of an error field, or nil when the field says there is no error: null, false, or empty.
    private static func errorMessage(_ value: Any) -> String? {
        switch value {
        case is NSNull:
            return nil
        case let text as String:
            return text.isEmpty ? nil : text
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return number.boolValue ? "The tool reported an error." : nil
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "The tool reported an error." }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
