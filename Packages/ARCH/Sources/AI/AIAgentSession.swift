// Agent sessions on the user's CLI (`docs/agents.md`, Sessions on the user's CLI ▸ The runner): `AIAgentSession` runs Claude Code as one long-lived process or Codex as one process per turn, with Arch's MCP server as the only source of tools, and turns their streams into `AIAgentEvent`s. The `Agent` module (VII.11 and VII.17) gives it the server to start, the tool lists the server offers, and the host's tool calls; the AI module depends on nothing of it.
import Darwin
import Foundation

extension AIFeatureID {
    /// Agent sessions, which `AgentService` registers.
    public static let agent = AIFeatureID(rawValue: "agent")
}

/// The MCP server a session's CLI starts: `arch-mcp --session` with the session's ticket, which the `Agent` module makes.
public struct AIAgentToolServer: Sendable, Equatable {
    /// `Contents/Helpers/arch-mcp`.
    public var executable: URL
    /// `["--session"]`.
    public var arguments: [String]
    /// `ARCH_AGENT_TICKET`. Claude Code gets it through `mcp.json` in the session folder, Codex through its environment and `env_vars`, never through an argument.
    public var environment: [String: String]
    /// The tools of the server's first `tools/list` answer on the session's connection, by MCP name, such as `session_info`. Claude Code's first `init` must list each as `mcp__arch__<name>`.
    public var tools: [String]

    public init(executable: URL, arguments: [String], environment: [String: String], tools: [String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.tools = tools
    }
}

/// Arch's skills for one session, in a folder that only that session reads (agent decision 16). The folder is a Claude Code plugin: `.claude-plugin/plugin.json` names `plugin`, and `skills/<name>/SKILL.md` holds each of `names`. Claude Code loads it with `--plugin-dir` and its skill tool, and a message that starts with `/` is refused, since Claude Code would run it as one of its commands. Codex cannot read a skill file in a session, whose shell and file tools are off, so it ignores this and keeps the `guide` topics.
public struct AIAgentSkills: Sendable, Equatable {
    public var folder: URL
    public var plugin: String
    public var names: [String]

    public init(folder: URL, plugin: String, names: [String]) {
        self.folder = folder
        self.plugin = plugin
        self.names = names
    }
}

public struct AIAgentSessionRequest: Sendable {
    public var feature: AIFeatureID
    /// The session's model, a route of that one model under the rules for `route`; nil uses `route`, or the feature's route without one, whose later models serve only when the earlier fail before `ready`, the first model output.
    public var model: AIModelRef?
    /// The route the session names for itself when `model` is nil: a tier or models of its own, under the rules for `AIRequest.route`. A session makes no Activity entry, so it has no `recordsContent`.
    public var route: AIRouteChoice?
    /// The static harness, which holds no session facts (agent decision 12).
    public var instructions: String
    public var toolServer: AIAgentToolServer
    public var id: UUID
    /// The CLI's working folder, which the session makes with mode 0700 and removes at its end.
    public var folder: URL
    /// An effort level the model takes: Claude Code's `--effort`, or one that Codex's catalog lists for the model (`AIService.agentEffortLevels(for:)`). Others are left out.
    public var effort: String?
    public var skills: AIAgentSkills?
    /// Claude Code's model requests per message. Codex relies on the tool host's call and time limits.
    public var maxTurns: Int?
    /// A single message with no persistent CLI thread. The session closes after the turn.
    public var ephemeral: Bool
    /// The hook's approved executable paths and invocation digests.
    public var knownProviders: [AIProviderID: String]? = nil

    public init(feature: AIFeatureID = .agent, model: AIModelRef? = nil, route: AIRouteChoice? = nil, instructions: String, toolServer: AIAgentToolServer,
                id: UUID = UUID(), folder: URL? = nil, effort: String? = nil, skills: AIAgentSkills? = nil, maxTurns: Int? = nil, ephemeral: Bool = false) {
        self.feature = feature
        self.model = model
        self.route = route
        self.instructions = instructions
        self.toolServer = toolServer
        self.id = id
        self.folder = folder ?? AIAgentSession.folder(for: id)
        self.effort = effort
        self.skills = skills
        self.maxTurns = maxTurns
        self.ephemeral = ephemeral
    }
}

public enum AIAgentTurnEnd: Sendable, Equatable {
    case completed
    /// Stop ended the turn.
    case stopped
    /// The tool's own limit of model requests per message.
    case turnLimit
}

public enum AIAgentEvent: Sendable {
    /// The model's first output in the session (Claude Code's first `message_start` after an `init` that passed the start check, or Codex's first item other than an error), with the model that now holds the conversation. A model that fails before it gives way to the route's next.
    case ready(AIModelRef)
    /// The first output of a later CLI process, after its own start check passed, as `ready` is the first process's: a new Claude Code process after one that stopped, or each Codex turn after the first. The `Agent` module holds a session's calls again from each process start until it.
    case processReady
    /// The model the CLI subsequently reports for a reply on the same provider.
    case modelChanged(AIModelRef)
    case text(String)
    case thinking(String)
    /// A turn's tokens, also recorded under the session's feature and model. For Codex, what the turn added to the thread's running total.
    case usage(AIUsage)
    case notice(String)
    case turnFinished(AIAgentTurnEnd)
    /// The turn failed after `ready`; the session goes on with the next message.
    case turnFailed(AIError)
}

/// What a CLI's decoder reads from one line.
enum AIAgentStreamEvent {
    /// Claude Code's `init` that passed the start check, or Codex's `thread.started`.
    case started(threadID: String?)
    /// The model's output: Claude Code's `message_start`, or a Codex item other than an error.
    case output
    case reportedModel(String)
    case text(String)
    case thinking(String)
    case notice(String)
    case usage(AIUsage)
    case turnEnded(AIAgentTurnEnd)
    case turnFailed(AIError)
}

@MainActor
public final class AIAgentSession {
    /// Ends when the session ends: without an error after `end(keepingThread:)`, and with one when no model produced output in the first turn or a start check or the stream watcher refused the tool.
    public nonisolated let events: AsyncThrowingStream<AIAgentEvent, any Error>
    public let id: UUID
    public let folder: URL
    /// The model that holds the conversation, from `ready` on.
    public private(set) var model: AIModelRef?
    /// The running CLI process, which the `Agent` module checks as an ancestor of the session's `arch-mcp`.
    public private(set) var processID: pid_t?
    /// Codex's thread, which follow-up turns resume.
    public private(set) var threadID: String?
    public private(set) var isTurnRunning = false
    /// Messages sent while a turn runs, which start in order after it.
    public private(set) var queuedMessages: [String] = []
    public private(set) var hasEnded = false
    /// Called right after each CLI process starts, with its process ID, so that the `Agent` module reads its start time for the ticket check as close to the start as it can.
    public var processDidStart: ((pid_t) -> Void)?

    /// Output must start within this and continue within `outputTimeout`; the latter pauses while a host tool call runs.
    var firstOutputTimeout: Duration = .seconds(120)
    var outputTimeout: Duration = .seconds(180)
    /// How long Stop waits for Claude Code to end the turn after the interrupt before it ends the process group.
    var stopGrace: Duration = .seconds(3)
    /// How long a Codex process may take to exit after `turn.completed`.
    var exitGrace: Duration = .seconds(5)

    private let continuation: AsyncThrowingStream<AIAgentEvent, any Error>.Continuation
    private let request: AIAgentSessionRequest
    private let feature: AIFeature
    private let service: AIService
    /// The models that may still start the session; from `ready` on, only the one that holds it.
    private var candidates: [AIRouteModel]
    private var signedInChecked: Set<AIModelRef> = []
    /// The user's messages and the agent's replies, for a new Claude Code process after the previous one stopped.
    private var transcript: [(role: AIMessage.Role, text: String)] = []
    /// The server's latest `tools/list` answer, and the answers on the running process's connection.
    private var currentTools: [String]
    private var offeredTools: [[String]] = []

    private var process: CommandLineProcess?
    private var processKind: AIAgentKind?
    /// Whether the running process has produced output, which `ready` or `processReady` reports once per process.
    private var processHasOutput = false
    /// Held while the session lives, so that another Arch's sweep of leftover folders leaves its folder alone.
    private var folderLock: AIAgentFolderLock?
    /// Counts process starts and ends, so the end of a process Arch already let go reports nothing.
    private var processRun = 0
    private var lines = AIAgentLineBuffer()
    private var claude: ClaudeCodeStreamDecoder?
    private var codex: CodexStreamDecoder?
    private var turn: Turn?
    /// The task that runs the current message, which Stop and `end` cancel while it waits for a slot or the probes.
    private var turnTask: Task<Void, Never>?
    /// Codex's running total for the thread from its last `turn.completed`.
    private var threadUsage: AIUsage?
    private var activeToolCalls = 0
    private var idleTimer: Task<Void, Never>?
    private var stopTimer: Task<Void, Never>?
    private var stopCount = 0
    private var isClosed = false

    init(request: AIAgentSessionRequest, feature: AIFeature, candidates: [AIRouteModel], service: AIService) throws {
        (events, continuation) = AsyncThrowingStream.makeStream()
        self.request = request
        self.feature = feature
        self.candidates = candidates
        self.service = service
        id = request.id
        folder = request.folder
        currentTools = request.toolServer.tools
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            folderLock = try AIAgentFolderLock(folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// `$TMPDIR/Arch-Agent-<session UUID>/`.
    public nonisolated static func folder(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(folderPrefix)\(id.uuidString)", isDirectory: true)
    }

    nonisolated static let folderPrefix = "Arch-Agent-"

    /// Removes the session folders an earlier run left, as after a crash. The app calls it at launch, before any session starts. A folder whose lock a live session holds, as another Arch's, stays, and so does a folder without a lock made in the last minute, which a session may be starting in.
    public nonisolated static func removeLeftoverFolders(in directory: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            guard AIAgentFolderLock.isLeftover(folder, now: now) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Messages

    /// Sends the user's message. The first carries the user's words and the preamble with tab handles (agent decision 12). A message sent while a turn runs waits for it. Throws `blockedByPolicy(.agentMessageIsCommand)` for a message that starts with `/`, after any white space, while Claude Code can hold a session with skills, since Claude Code runs it as one of its own commands without the model.
    public func send(_ message: String) throws {
        if hasEnded && !request.ephemeral { return }
        try checkMessage(message)
        queuedMessages.append(message)
        startNextTurn()
    }

    /// Retry a failed user turn without adding another copy of its message to Arch's replay transcript.
    public func retry(_ message: String) throws {
        guard !hasEnded, !isTurnRunning else { return }
        guard let last = transcript.last, last.role == .user else { return try send(message) }
        // A new Claude Code process needs Arch's original preamble. An existing CLI conversation already has it.
        let input = processKind == .claudeCode && process == nil ? last.text : message
        try checkMessage(input)
        startTurn(input, isRetry: true)
    }

    /// Throws what `send(_:)` would throw for the message, without sending it, so that a caller that queues messages itself can keep a refused one in its composer.
    public func checkMessage(_ message: String) throws {
        if request.ephemeral && (isTurnRunning || hasEnded) {
            throw AIError.invalidRequest("A one-time agent run takes one message.")
        }
        if request.skills != nil, message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
           candidates.contains(where: { candidate in
               guard case .commandLine(let tool) = candidate.provider.kind else { return false }
               return tool.agent == .claudeCode
           }) {
            throw AIError.blockedByPolicy(.agentMessageIsCommand)
        }
    }

    /// Stops the running turn and drops queued messages. Claude Code gets the interrupt and keeps its process unless the turn has not ended 3 seconds later; Codex's process group ends.
    public func stop() {
        queuedMessages.removeAll()
        guard let turn else {
            turnTask?.cancel()
            return
        }
        guard turn.outcome == nil, turn.pendingEnd == nil, !turn.isStopping else { return }
        turn.isStopping = true
        // Before the message reached the tool, the turn ends as stopped and starts no process: at once while it waits for a slot of the provider's limiter, and otherwise once the running status command or the probes in progress have finished, whose result is kept.
        guard let process, turn.didStartProcess else {
            turnTask?.cancel()
            return
        }
        switch processKind {
        case .claudeCode:
            stopCount += 1
            process.write(ClaudeCodeAgent.interrupt(requestID: "arch-stop-\(stopCount)"))
            stopTimer = Task { [weak self, stopGrace] in
                guard (try? await Task.sleep(for: stopGrace)) != nil else { return }
                self?.endProcess()
                self?.complete(.finished(.stopped))
            }
        case .codex, nil:
            endProcess()
            complete(.finished(.stopped))
        }
    }

    /// Ends the session: its processes, its folder, and, unless `keepingThread`, Codex's copy of the thread with `codex --no-daemon delete --force`.
    public func end(keepingThread: Bool = false) async {
        queuedMessages.removeAll()
        if let turn, !turn.didStartProcess { turnTask?.cancel() }
        endProcess()
        if turn?.outcome == nil { complete(.finished(.stopped)) }
        if !hasEnded {
            hasEnded = true
            continuation.finish()
        }
        guard !isClosed else { return }
        isClosed = true
        if !request.ephemeral, !keepingThread, let holder = candidates.first { await deleteThread(of: holder) }
        try? FileManager.default.removeItem(at: folder)
        folderLock = nil
    }

    /// Ends the running process group at once, as at quit, without the work of `end(keepingThread:)`, which still removes the folder and Codex's thread.
    public func endProcesses() {
        queuedMessages.removeAll()
        if let turn, !turn.didStartProcess { turnTask?.cancel() }
        endProcess()
        if turn?.outcome == nil { complete(.finished(.stopped)) }
    }

    /// Runs `codex --no-daemon delete --force` on the session's thread when `candidate` is the Codex model that holds it.
    private func deleteThread(of candidate: AIRouteModel) async {
        guard let threadID, case .commandLine(let tool) = candidate.provider.kind, tool.agent == .codex else { return }
        self.threadID = nil
        threadUsage = nil
        let environment = await tool.runEnvironment()
        _ = try? await AIAgentCommand.run(tool.executable, CodexAgent.deleteArguments(thread: threadID), environment: environment)
    }

    // MARK: The tool host

    /// The host started one of the session's tool calls; the CLI prints nothing while Arch waits for the user, so the idle timer pauses.
    public func toolCallDidStart() {
        activeToolCalls += 1
        idleTimer?.cancel()
    }

    public func toolCallDidEnd() {
        activeToolCalls = max(activeToolCalls - 1, 0)
        if activeToolCalls == 0 { armIdleTimer(outputTimeout) }
    }

    /// The server answered `tools/list` again on the session's connection, as after a mode change. A later `init` may list this list or an earlier one.
    public func toolListDidChange(_ tools: [String]) {
        currentTools = tools
        offeredTools.append(tools)
        claude?.check.session?.offeredTools = offeredTools
    }

    // MARK: Turns

    private final class Turn {
        let candidate: AIRouteModel
        var continuation: CheckedContinuation<TurnOutcome, Never>?
        var outcome: TurnOutcome?
        /// Codex's turn ends when its process exits after `turn.completed`.
        var pendingEnd: AIAgentTurnEnd?
        var reply = ""
        var usage: AIUsage?
        var isStopping = false
        var didStartProcess = false
        var hasOutput = false
        var reportedModel: String?

        init(candidate: AIRouteModel) {
            self.candidate = candidate
        }
    }

    private enum TurnOutcome {
        case finished(AIAgentTurnEnd)
        case failed(AIError)
        /// A start check or the watcher refused the tool; after `ready` this ends the session.
        case refused(AIError)
    }

    private func startNextTurn() {
        guard !isTurnRunning, !hasEnded, !queuedMessages.isEmpty else { return }
        startTurn(queuedMessages.removeFirst())
    }

    private func startTurn(_ message: String, isRetry: Bool = false) {
        isTurnRunning = true
        turnTask = Task { await run(message, isRetry: isRetry) }
    }

    /// Runs one message on the session's model, or, before `ready`, on each model in turn until one produces output (start-only fallbacks). A model that fails before its first output, such as at a usage limit, gives way to the next, and a Codex thread it began is deleted; with none left, the session ends with the last error. A turn of an automatic feature is one of its automatic requests: it fails with `budgetReached` at the daily limit for automatic requests or the monthly spending limit before any model, and otherwise counts once toward the daily limit, whichever models it tries.
    private func run(_ message: String, isRetry: Bool) async {
        if Task.isCancelled || hasEnded {
            continuation.yield(.turnFinished(.stopped))
            if request.ephemeral { await end() }
            isTurnRunning = false
            startNextTurn()
            return
        }
        if !isRetry { transcript.append((.user, message)) }
        var outcome: TurnOutcome = .failed(.notConfigured(.noUsableModel))
        var reply = ""
        let budget = feature.trigger == .automatic ? service.reachedBudget(for: feature) : nil
        if let budget {
            outcome = .failed(.budgetReached(budget))
        } else if feature.trigger == .automatic {
            service.usage.countAutomaticRequest(for: feature.id)
        }
        while budget == nil, let candidate = candidates.first, !hasEnded {
            (outcome, reply) = await attempt(message, on: candidate)
            guard model == nil, !hasEnded, candidates.count > 1 else { break }
            if case .finished = outcome { break }
            if case .refused(.blockedByPolicy(.unknownProvider)) = outcome { break }
            endProcess()
            await deleteThread(of: candidate)
            candidates.removeFirst()
            if Task.isCancelled {
                outcome = .finished(.stopped)
                break
            }
        }
        switch outcome {
        case .finished(let end):
            if !reply.isEmpty { transcript.append((.assistant, reply)) }
            continuation.yield(.turnFinished(request.ephemeral && end == .turnLimit ? .completed : end))
        case .failed(let error) where model != nil:
            continuation.yield(.turnFailed(error))
        case .failed(let error), .refused(let error):
            fail(error)
        }
        if request.ephemeral { await end() }
        isTurnRunning = false
        startNextTurn()
    }

    /// One message on one model: the provider's slot, the sign-in and probes, the process start or the write, and the wait for the turn's end. Returns the outcome and the reply's text.
    private func attempt(_ message: String, on candidate: AIRouteModel) async -> (TurnOutcome, String) {
        guard case .commandLine(let tool) = candidate.provider.kind, let kind = tool.agent else { return (.failed(.notConfigured(.noUsableModel)), "") }
        let turn = Turn(candidate: candidate)
        self.turn = turn
        let limiter = service.limiter(for: candidate.provider.id)
        await limiter.update(candidate.provider.limits)
        // Before `ready`, a provider in a cool-down longer than 10 seconds gives way to the next model at once, as for other requests.
        if model == nil, candidates.count > 1, let until = await limiter.coolDownUntil, until.timeIntervalSinceNow > 10 {
            self.turn = nil
            return (.failed(.rateLimited(candidate.provider.id, until: await limiter.providerReset)), "")
        }
        // An automatic feature's turn waits behind the user's requests and gives up after the limiter's wait limit, as its other requests do.
        do {
            // A wait for a slot or for a usage limit's reset, which may be hours away, is said in the panel.
            try await limiter.acquire(isUser: feature.trigger == .user) { [continuation, name = candidate.provider.name] reason in
                switch reason {
                case .rateLimited(let until):
                    continuation.yield(.notice("\(name) is at its usage limit until \(until.formatted(date: .abbreviated, time: .shortened)). The message starts then; Stop cancels it."))
                case .queued:
                    continuation.yield(.notice("Waiting for another request to \(name) to finish."))
                }
            }
        } catch {
            self.turn = nil
            // Stop and `end` cancel the wait for a slot.
            if turn.isStopping || hasEnded { return (.finished(.stopped), "") }
            if case AIError.rateLimited(let provider, _) = error {
                return (.failed(.rateLimited(provider, until: await limiter.providerReset)), "")
            }
            return (.failed(AIError(error)), "")
        }
        var outcome = await perform(message, on: candidate, tool: tool, kind: kind, turn: turn)
        if case .failed = outcome, !turn.didStartProcess, turn.isStopping || hasEnded { outcome = .finished(.stopped) }
        idleTimer?.cancel()
        stopTimer?.cancel()
        self.turn = nil
        let release: AIRateLimiter.Outcome
        switch outcome {
        case .finished: release = .answered
        case .failed(.rateLimited(_, let until)): release = .rateLimited(retryAfter: until)
        case .failed, .refused: release = .other
        }
        // Only a turn that reached the tool counts, as for other requests.
        if turn.didStartProcess {
            let isError = if case .finished = outcome { false } else { true }
            var usageModel = candidate.model
            if let reported = turn.reportedModel { usageModel.name = reported }
            service.usage.record(feature: feature, provider: candidate.provider, model: usageModel, usage: turn.usage, isError: isError)
        }
        await limiter.release(after: release)
        return (outcome, turn.reply)
    }

    private func perform(_ message: String, on candidate: AIRouteModel, tool: AICommandLineConfiguration, kind: AIAgentKind, turn: Turn) async -> TurnOutcome {
        if turn.isStopping || hasEnded { return .finished(.stopped) }
        let provider = candidate.provider.id
        let environment = await tool.runEnvironment()
        let probe: AIAgentProbeResult
        do {
            try service.checkDestination(of: candidate.provider, known: request.knownProviders)
            if !signedInChecked.contains(candidate.ref) {
                let status = try await AIAgentToolStatus.read(kind: kind, executable: tool.executable, environment: tool.environment)
                // A Stop during the read leaves the sign-in unread, and the probes unstarted.
                if turn.isStopping || hasEnded { return .finished(.stopped) }
                if status.isSignedIn == false { return .failed(.authentication(provider)) }
                signedInChecked.insert(candidate.ref)
            }
            // The probe store compares the executable's resolved path, size, and modification time before every process start.
            probe = try await AIAgentProbeStore.shared.result(kind: kind, executable: tool.executable, environment: environment)
        } catch AIError.blockedByPolicy(.unknownProvider) {
            return .refused(.blockedByPolicy(.unknownProvider))
        } catch let error as AIAgentToolError {
            return .failed(error.aiError(provider: provider))
        } catch {
            return .failed(AIError(error))
        }
        if turn.isStopping { return .finished(.stopped) }
        if hasEnded { return .finished(.stopped) }
        do {
            try service.checkDestination(of: candidate.provider, known: request.knownProviders)
            switch kind {
            case .claudeCode:
                if request.maxTurns != nil && !probe.supportsRunOption {
                    return .failed(.providerUnavailable(provider, detail: "Claude Code could not confirm its turn limit. Update Claude Code in the terminal."))
                }
                if process == nil || processKind != .claudeCode { try startClaudeCode(on: candidate, tool: tool, environment: environment) }
                process?.write(ClaudeCodeAgent.userMessage(messageWithEarlierConversation(message)))
            case .codex:
                if request.ephemeral && !probe.supportsRunOption {
                    return .failed(.providerUnavailable(provider, detail: "Codex could not confirm support for one-time runs. Update Codex in the terminal."))
                }
                try startCodexTurn(message, on: candidate, tool: tool, environment: environment, probe: probe)
            }
        } catch AIError.blockedByPolicy(.unknownProvider) {
            return .refused(.blockedByPolicy(.unknownProvider))
        } catch let error as AIError {
            return .failed(error)
        } catch {
            return .failed(.providerUnavailable(provider, detail: "\(tool.executable.lastPathComponent) could not start: \(error.localizedDescription)"))
        }
        turn.didStartProcess = true
        armIdleTimer(firstOutputTimeout)
        if let outcome = turn.outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome = turn.outcome {
                continuation.resume(returning: outcome)
            } else {
                turn.continuation = continuation
            }
        }
    }

    /// Ends the running turn once.
    private func complete(_ outcome: TurnOutcome) {
        guard let turn, turn.outcome == nil else { return }
        turn.outcome = outcome
        idleTimer?.cancel()
        stopTimer?.cancel()
        turn.continuation?.resume(returning: outcome)
        turn.continuation = nil
    }

    /// Ends the session with an error, leaving its folder and Codex's thread for `end(keepingThread:)`.
    private func fail(_ error: AIError) {
        guard !hasEnded else { return }
        hasEnded = true
        queuedMessages.removeAll()
        endProcess()
        complete(.refused(error))
        continuation.finish(throwing: error)
    }

    /// The earlier conversation as text from Arch's transcript, for the first message of a new Claude Code process after the previous one stopped.
    private func messageWithEarlierConversation(_ message: String) -> String {
        guard needsEarlierConversation else { return message }
        needsEarlierConversation = false
        let earlier = transcript.dropLast().map { entry in
            "\(entry.role == .user ? "User" : "Agent"): \(entry.text)"
        }
        guard !earlier.isEmpty else { return message }
        return "<earlier-conversation>\nThe conversation so far in this session, without tool results. It was cut off; continue from it.\n\n"
            + earlier.joined(separator: "\n\n") + "\n</earlier-conversation>\n\n" + message
    }

    private var needsEarlierConversation = false

    // MARK: Processes

    private func startClaudeCode(on candidate: AIRouteModel, tool: AICommandLineConfiguration, environment: [String: String]) throws {
        let configuration = folder.appendingPathComponent("mcp.json")
        let data = try ClaudeCodeAgent.mcpConfiguration(request.toolServer)
        guard FileManager.default.createFile(atPath: configuration.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AIError.providerUnavailable(candidate.provider.id, detail: "The session folder could not be written.")
        }
        offeredTools = [currentTools]
        let check = ClaudeCodeStartCheck(session: ClaudeCodeStartCheck.Session(offeredTools: offeredTools, skills: request.skills))
        claude = ClaudeCodeStreamDecoder(check: check, provider: candidate.provider.id)
        codex = nil
        // The tool's conversation ended with the previous process, so the new one starts from Arch's transcript.
        needsEarlierConversation = transcript.count > 1
        let arguments = ClaudeCodeAgent.sessionArguments(sessionID: UUID(), configuration: configuration, instructions: request.instructions,
                                                         model: candidate.model.name, effort: request.effort, skills: request.skills, maxTurns: request.maxTurns)
        try startProcess(kind: .claudeCode, executable: tool.executable, arguments: arguments,
                         environment: ClaudeCodeAgent.sessionEnvironment(environment, skills: request.skills), input: Data(), keepsInputOpen: true)
    }

    private func startCodexTurn(_ message: String, on candidate: AIRouteModel, tool: AICommandLineConfiguration, environment: [String: String], probe: AIAgentProbeResult) throws {
        let server = request.toolServer
        let arguments: [String]
        if let threadID {
            arguments = CodexAgent.resumeArguments(thread: threadID, server: server, instructions: request.instructions, disabled: probe.disabledFeatures,
                                                   model: candidate.model.name, effort: request.effort, levels: probe.effortLevels)
        } else {
            arguments = CodexAgent.firstTurnArguments(server: server, instructions: request.instructions, disabled: probe.disabledFeatures,
                                                      model: candidate.model.name, effort: request.effort, levels: probe.effortLevels, folder: folder, ephemeral: request.ephemeral)
        }
        claude = nil
        codex = CodexStreamDecoder(isSession: true, provider: candidate.provider.id)
        try startProcess(kind: .codex, executable: tool.executable, arguments: arguments,
                         environment: environment.merging(server.environment) { _, ticket in ticket }, input: Data(message.utf8), keepsInputOpen: false)
    }

    private func startProcess(kind: AIAgentKind, executable: URL, arguments: [String], environment: [String: String], input: Data, keepsInputOpen: Bool) throws {
        endProcess()
        let process: CommandLineProcess
        do {
            process = try CommandLineProcess(executable: executable, arguments: arguments, environment: environment, directory: folder, input: input, keepsInputOpen: keepsInputOpen)
        } catch let error as POSIXError {
            throw AIError.providerUnavailable(turn?.candidate.provider.id ?? AIProviderID(rawValue: ""),
                                              detail: "\(executable.lastPathComponent) could not start: \(String(cString: strerror(error.code.rawValue))).")
        }
        processRun += 1
        let run = processRun
        self.process = process
        processKind = kind
        processID = process.id
        processHasOutput = false
        processDidStart?(process.id)
        lines = AIAgentLineBuffer()
        Task { [weak self] in
            for await chunk in process.output {
                self?.receive(chunk, run: run)
            }
            self?.receiveLastLine(run: run)
            let termination = await process.termination()
            let errorLine = await process.lastErrorLine()
            self?.processEnded(termination, errorLine: errorLine, executable: executable, run: run)
        }
    }

    /// Ends the running process group, whose end then reports nothing.
    private func endProcess() {
        process?.terminate()
        process = nil
        processID = nil
        processRun += 1
    }

    private func receive(_ chunk: Data, run: Int) {
        guard run == processRun else { return }
        if turn?.pendingEnd == nil { armIdleTimer(outputTimeout) }
        for line in lines.lines(in: chunk) where run == processRun {
            receive(line: line)
        }
    }

    /// A last line without a newline, once standard output has ended.
    private func receiveLastLine(run: Int) {
        guard run == processRun, let line = lines.finish() else { return }
        receive(line: line)
    }

    private func receive(line: Data) {
        guard let object = agentJSONObject(line) else { return }
        do {
            let events: [AIAgentStreamEvent]
            if var decoder = claude {
                events = try decoder.decode(object)
                claude = decoder
            } else if var decoder = codex {
                events = try decoder.decode(object)
                codex = decoder
            } else {
                events = []
            }
            events.forEach(handle)
        } catch {
            // A start check or the watcher refused the tool: its process group ends at once.
            endProcess()
            let error = AIError(error)
            if let turn, turn.outcome == nil { complete(.refused(error)) } else { fail(error) }
        }
    }

    private func handle(_ event: AIAgentStreamEvent) {
        guard let turn else { return }
        switch event {
        case .started(let thread):
            guard let thread, !request.ephemeral else { return }
            if thread != threadID { threadUsage = nil }
            threadID = thread
        case .output:
            turn.hasOutput = true
            let serving = AIModelRef(provider: turn.candidate.ref.provider, model: turn.reportedModel ?? turn.candidate.ref.model)
            if model == nil {
                // Keep the configured route for later CLI invocations, including a model alias or the tool's default.
                candidates = [turn.candidate]
                model = serving
                continuation.yield(.ready(serving))
            } else {
                updateReportedModel(serving)
                if !processHasOutput { continuation.yield(.processReady) }
            }
            processHasOutput = true
        case .reportedModel(let name):
            turn.reportedModel = name
            if turn.hasOutput { updateReportedModel(AIModelRef(provider: turn.candidate.ref.provider, model: name)) }
        case .text(let text):
            turn.reply += text
            continuation.yield(.text(text))
        case .thinking(let text):
            continuation.yield(.thinking(text))
        case .notice(let text):
            continuation.yield(.notice(text))
        case .usage(var usage):
            if processKind == .codex {
                // `turn.completed.usage` is the thread's running total, also on a resumed turn, so each turn counts what it added.
                let total = usage
                if let earlier = threadUsage { usage = Self.usage(total, since: earlier) }
                threadUsage = total
            }
            turn.usage = usage
            continuation.yield(.usage(usage))
        case .turnEnded(let end):
            if processKind == .codex {
                // The thread is complete on disk once the process exits, so the next turn's resume waits for it.
                turn.pendingEnd = end
                idleTimer?.cancel()
                stopTimer = Task { [weak self, exitGrace] in
                    guard (try? await Task.sleep(for: exitGrace)) != nil else { return }
                    self?.endProcess()
                    self?.complete(.finished(end))
                }
            } else {
                complete(.finished(turn.isStopping && end == .completed ? .stopped : end))
            }
        case .turnFailed(let error):
            complete(.failed(error))
        }
    }

    private func updateReportedModel(_ ref: AIModelRef) {
        guard model != ref else { return }
        model = ref
        continuation.yield(.modelChanged(ref))
    }

    private func processEnded(_ termination: CommandLineTermination, errorLine: String?, executable: URL, run: Int) {
        guard run == processRun else { return }
        process = nil
        processID = nil
        guard let turn, turn.outcome == nil else { return }
        if let end = turn.pendingEnd { return complete(.finished(end)) }
        if turn.isStopping { return complete(.finished(.stopped)) }
        let name = executable.lastPathComponent
        let detail: String
        switch termination {
        case .exited(let code): detail = codex?.lastError ?? errorLine ?? "\(name) exited with status \(code)."
        case .signaled(let signal): detail = errorLine ?? "\(name) stopped on signal \(signal)."
        }
        complete(.failed(.providerUnavailable(turn.candidate.provider.id, detail: detail)))
    }

    /// What a running total added since an earlier one, by field and never below zero.
    private static func usage(_ total: AIUsage, since earlier: AIUsage) -> AIUsage {
        AIUsage(inputTokens: max(total.inputTokens - earlier.inputTokens, 0), outputTokens: max(total.outputTokens - earlier.outputTokens, 0),
                cachedInputTokens: max(total.cachedInputTokens - earlier.cachedInputTokens, 0))
    }

    private func armIdleTimer(_ timeout: Duration) {
        idleTimer?.cancel()
        guard activeToolCalls == 0, let turn, turn.outcome == nil, turn.pendingEnd == nil, turn.didStartProcess else { return }
        idleTimer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.idleTimedOut()
        }
    }

    private func idleTimedOut() {
        guard let turn, turn.outcome == nil else { return }
        endProcess()
        complete(.failed(.providerUnavailable(turn.candidate.provider.id, detail: "The provider stopped responding.")))
    }
}

// MARK: - Starting sessions

/// Agent sessions use the CLI runner or the provider-neutral tool loop for HTTP models.
public enum AIAgentSessionRoute: Equatable, Sendable {
    case commandLine
    case http(pinnedModel: AIModelRef?)
}

extension AIService {
    /// The runner to use for an in-app session. An HTTP route chooses its first serving model before pinning the conversation.
    public func agentSessionRoute(for chosen: AIModelRef?) throws -> AIAgentSessionRoute {
        guard let feature = features.first(where: { $0.id == .agent }) else { throw AIError.notConfigured(.unknownFeature) }
        let first = try agentSessionCandidates(named: chosen, for: feature)[0]
        guard case .http = first.provider.kind else { return .commandLine }
        // With no configured route, the composer still offers the first usable model. Name it explicitly or AIClient would find no route.
        let hasRoute = (try? settings.routeModels(for: feature))?.first?.ref == first.ref
        return .http(pinnedModel: chosen ?? (hasRoute ? nil : first.ref))
    }

    /// Starts a CLI runner. A task authorized to use the user's subscription falls back only to another CLI preset.
    public func startAgentSession(_ request: AIAgentSessionRequest) throws -> AIAgentSession {
        if let limit = request.maxTurns, !(1...ClaudeCodeAgent.maxTurns).contains(limit) {
            throw AIError.invalidRequest("The agent turn limit must be between 1 and \(ClaudeCodeAgent.maxTurns).")
        }
        guard let feature = features.first(where: { $0.id == request.feature }) else { throw AIError.notConfigured(.unknownFeature) }
        let candidates = try agentSessionCandidates(named: request.model, route: request.route, for: feature, commandLineOnly: true)
        do {
            return try AIAgentSession(request: request, feature: feature, candidates: candidates, service: self)
        } catch {
            throw AIError.providerUnavailable(candidates[0].provider.id, detail: "The session folder could not be made: \(error.localizedDescription)")
        }
    }

    /// Resolves the feature's route or tier under the same switch and permission rules as ordinary AI requests.
    /// Only a session started by the user without a named route may fall back to another connected model.
    func agentSessionCandidates(named ref: AIModelRef?, route choice: AIRouteChoice? = nil, for feature: AIFeature, commandLineOnly: Bool = false) throws -> [AIRouteModel] {
        let candidates: [AIRouteModel]
        func canServe(_ candidate: AIRouteModel) -> Bool {
            candidate.provider.capabilities(of: candidate.model).contains(.agent) && (!commandLineOnly || candidate.provider.commandLineAgent != nil)
        }
        if let choice = ref.map({ AIRouteChoice.models([$0]) }) ?? choice {
            candidates = try settings.routeModels(for: feature, route: choice).filter(canServe)
        } else if feature.routing == .stored, feature.trigger == .user {
            guard settings.route(for: feature.id).isEnabled else { throw AIError.notConfigured(.switchedOff) }
            let route = ((try? settings.routeModels(for: feature)) ?? []).filter(canServe)
            if !route.isEmpty { return route }
            let all = availableAgentModels(for: feature).filter(canServe)
            candidates = (all.first(where: { $0.provider.commandLineAgent != nil }) ?? all.first).map { [$0] } ?? []
        } else {
            candidates = try settings.routeModels(for: feature).filter(canServe)
        }
        guard !candidates.isEmpty else { throw AIError.notConfigured(.noUsableModel) }
        return candidates
    }

    private func availableAgentModels(for feature: AIFeature) -> [AIRouteModel] {
        settings.providers.flatMap { provider in
            provider.models.compactMap { model -> AIRouteModel? in
                let capabilities = provider.capabilities(of: model)
                guard capabilities.contains(.agent), feature.requirements.isSubset(of: capabilities) else { return nil }
                return AIRouteModel(ref: AIModelRef(provider: provider.id, model: model.name), provider: provider, model: model)
            }
        }
    }

    /// Usable models for the composer, with the session's default choices first.
    public func agentSessionModels() -> [AIModelRef] {
        guard let feature = features.first(where: { $0.id == .agent }),
              let candidates = try? agentSessionCandidates(named: nil, for: feature) else { return [] }
        let first = candidates.map(\.ref)
        return first + availableAgentModels(for: feature).map(\.ref).filter { !first.contains($0) }
    }

    /// The effort levels the model takes, for the composer's menu: Claude Code's `--effort` levels, or the levels Codex's bundled catalog lists for the model. Empty when there are none, as for Codex's default model or a model the catalog does not list.
    public func agentEffortLevels(for ref: AIModelRef) async -> [String] {
        guard let provider = settings.providers.first(where: { $0.id == ref.provider }), case .commandLine(let tool) = provider.kind, let kind = tool.agent else { return [] }
        switch kind {
        case .claudeCode:
            return ClaudeCodeAgent.effortLevels
        case .codex:
            guard !ref.model.isEmpty else { return [] }
            let probe = try? await AIAgentProbeStore.shared.result(kind: kind, executable: tool.executable, environment: await tool.runEnvironment())
            return probe?.effortLevels[ref.model] ?? []
        }
    }

    /// Check for a Claude Code or Codex preset: the status command and the probes, never a model, so it uses none of the subscription. Returns a line such as "Claude Code 2.1.323 is signed in." Throws a sentence that names what is missing.
    func checkAgentTool(_ tool: AICommandLineConfiguration, kind: AIAgentKind) async throws -> String {
        let status = try await AIAgentToolStatus.read(kind: kind, executable: tool.executable, environment: tool.environment)
        let name = "\(kind.title)\(status.version.map { " \($0)" } ?? "")"
        AIAgentProbeStore.shared.removeAll()
        _ = try await AIAgentProbeStore.shared.result(kind: kind, executable: tool.executable, environment: await tool.runEnvironment())
        switch status.isSignedIn {
        case true?: return "\(name) is signed in and accepts every setting Arch uses."
        case false?: throw AIAgentToolError(detail: "\(name) is not signed in. Sign in to it in the terminal.")
        case nil: throw AIAgentToolError(detail: "\(name) did not say whether it is signed in.")
        }
    }
}

/// A lock a live session holds on its folder (`flock` on `.arch-lock` in it), so that the sweep of leftover folders at another Arch's launch leaves it alone. The lock goes with the process, so a crashed Arch's folder is leftover again.
final class AIAgentFolderLock {
    static let fileName = ".arch-lock"
    /// How long a folder without a lock file may be young, since a session makes the folder before it takes the lock.
    static let graceInterval: TimeInterval = 60

    private var descriptor: Int32

    init(folder: URL) throws {
        let descriptor = open(folder.appendingPathComponent(Self.fileName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EWOULDBLOCK)
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Whether the sweep may remove `folder`: no live session holds its lock, and a folder without a lock file is older than the grace interval.
    static func isLeftover(_ folder: URL, now: Date) -> Bool {
        let descriptor = open(folder.appendingPathComponent(fileName).path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let modified = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
            return modified.map { now.timeIntervalSince($0) > graceInterval } ?? true
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }
}
