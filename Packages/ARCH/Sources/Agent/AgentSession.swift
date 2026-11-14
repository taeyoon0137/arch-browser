// An in-app agent session (docs/agents.md, In the browser; Sessions on the user's CLI): one conversation bound to a space and its Persona, through `AIAgentSession` on the user’s CLI or `AgentAPISession` on a connected HTTP model, with Arch's tools as its only tools. It keeps the transcript, the messages the user queued during a turn, the mode, the site scope, the tab handles, and its ticket, and it holds the tool host's calls until the model's first output and while the user has taken the session over. `AgentService` starts it, binds its `arch-mcp` connections, and runs its calls; the panel shows it.
import AgentControl
import AI
import Darwin
import Foundation

/// The conversation, its streamed events, and its lifetime are common to every in-app session.
@MainActor public protocol AgentSessionRunning: AnyObject {
    var events: AsyncThrowingStream<AIAgentEvent, any Error> { get }
    func checkMessage(_ message: String) throws
    func send(_ message: String) throws
    func retry(_ message: String) throws
    func stop()
    func end(keepingThread: Bool) async
}

extension AgentSessionRunning {
    public func retry(_ message: String) throws { try send(message) }
}

/// Only a command-line runner binds an MCP ticket and manages child processes.
@MainActor protocol AgentCommandLineRunning: AgentSessionRunning {
    var processID: pid_t? { get }
    var processDidStart: ((pid_t) -> Void)? { get set }
    func toolCallDidStart()
    func toolCallDidEnd()
    func toolListDidChange(_ tools: [String])
    func endProcesses()
}

extension AIAgentSession: AgentCommandLineRunning {}

extension AgentAPISession: AgentSessionRunning {
    public func checkMessage(_ message: String) throws {}
    public func end(keepingThread: Bool) async { end() }
}

@MainActor public final class AgentSession: ObservableObject, Identifiable {
    public enum Origin: Equatable, Sendable {
        /// The user started it in Arch.
        case app
        /// An outside client started it with `arch-cli task` under this grant: the client's text adds nothing to the site scope, Allow on its sensitive cards asks for Touch ID, and `deniesApprovals` denies each approval at once (plan task VII.13 asks them).
        case outsideClient(grantID: UUID, clientName: String, deniesApprovals: Bool)
    }

    public enum State: Equatable, Sendable {
        /// The first turn runs, before the model's first output.
        case starting
        case running
        /// An approval or a question waits for the user.
        case waitingForUser
        /// The last turn ended; the next message continues the session.
        case done
        case stopped
        /// The session cannot go on, with the sentence and the panel's action.
        case failed(String, AgentErrorAction?)

        /// The word `sessions/list` and `task/start` report.
        public var name: String {
            switch self {
            case .starting, .running: return "running"
            case .waitingForUser: return "waitingForUser"
            case .done: return "done"
            case .stopped: return "stopped"
            case .failed: return "failed"
            }
        }
    }

    /// How long a call waits for the model's first output after the start check, and at most while the user has taken the session over (the in-app approval wait).
    static let readyWait: Duration = .seconds(10)
    static let takeOverWait: Duration = .seconds(AgentLimits.inAppApprovalMinutes * 60)

    public let id: UUID
    public let personaID: UUID
    public let spaceID: UUID
    public let origin: Origin
    /// The model the user chose; nil uses the `agent` route.
    public let requestedModel: AIModelRef?
    public let effort: String?
    /// The agent folder's name, from the task's first words; the user can rename it.
    @Published public var title: String
    @Published public private(set) var mode: AgentAccessLevel
    /// The model that holds the conversation, from its first output on.
    @Published public private(set) var model: AIModelRef?
    @Published public private(set) var state = State.starting
    @Published private(set) var transcript = AgentTranscript()
    /// Messages typed during a turn, which go in order when it ends.
    @Published public private(set) var queuedMessages: [String] = []
    @Published public private(set) var isTurnRunning = false
    /// Take Over: the session's calls wait until Hand Back.
    @Published public private(set) var isTakenOver = false
    @Published public private(set) var hasEnded = false
    /// Set once the runner's end finished, with its processes, folder, and Codex's thread; a quit that ran out of time ends the processes of a session without it.
    private(set) var isCleanedUp = false
    /// The scope's sites, for the panel's header and `session_info`.
    @Published public private(set) var siteScope: [String] = []

    var ticket: AgentSessionTicket?
    var scope: AgentSiteScope {
        didSet { siteScope = scope.sites }
    }
    var handles = AgentGrantHandles()
    var researchPages: [UUID: AgentResearchPage] = [:]
    var snapshots = AgentSnapshotStore()
    let ready = AgentGate(isOpen: false)
    let handedBack = AgentGate(isOpen: true)
    private(set) var runner: (any AgentSessionRunning)?
    /// The CLI process Arch started last, as it was right after it started.
    private(set) var spawnedProcess: AgentProcessRecord?
    /// Counts what ends the calls of the turn before: a new turn, Stop, a new runner, and the end. A call that waited at a gate runs only when the count is still the one it arrived with.
    private(set) var callEpoch = 0
    /// A page result started before the user took over stays invalid after Hand Back.
    private(set) var takeoverGeneration = 0
    /// The tab currently being read, keyed by each host call so overlapping reads retain their own lifetime.
    private var readingTabs: [(call: UUID, tab: UUID)] = []
    var latestActiveTab: UUID? { readingTabs.last?.tab }

    func beganReading(_ tabID: UUID) -> UUID {
        let call = UUID()
        readingTabs.append((call, tabID))
        return call
    }

    func finishedReading(_ call: UUID) { readingTabs.removeAll { $0.call == call } }

    private(set) var callsThisTurn = 0
    private(set) var callsThisSession = 0
    /// The last tool list reported to the runner, so that a later `tools/list` answer that differs reaches it once.
    var reportedTools: [String]
    /// The service's: tells the session's connections that their tools changed, after a mode change.
    var modeDidChange: (() -> Void)?
    /// Closes the browser tabs the session still owns before waiting for its model to end.
    var closeOwnedTabs: (() -> Void)?
    /// The service's: what the session did, for the `task/event` notifications of the client that started it.
    var taskEvent: ((AgentTaskEvent.Kind, String) -> Void)?
    /// The service's: one sentence and an action for an error, with the tool's name.
    var describe: (AIError) -> (String, AgentErrorAction?) = { ($0.localizedDescription, .retry) }
    /// Available through session_info after the model starts, while the user still shares the source page.
    var readerExcerpt: AgentReaderExcerpt?
    private var hasSentFirstMessage = false
    private var hasNotedForeignTicket = false

    /// The status shown beside the conversation and its sidebar folder.
    public var statusText: String {
        if isTakenOver && !hasEnded { return "You have control" }
        switch state {
        case .starting: return "Starting"
        case .running: return "Working"
        case .waitingForUser: return "Waiting for you"
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    public var items: [AgentTranscriptItem] { transcript.items }

    init(id: UUID = UUID(), title: String, personaID: UUID, spaceID: UUID, origin: Origin, mode: AgentAccessLevel, model: AIModelRef?, effort: String?,
         scope: AgentSiteScope, attachedTabIDs: [UUID], tools: [String]) {
        self.id = id
        self.title = title
        self.personaID = personaID
        self.spaceID = spaceID
        self.origin = origin
        self.mode = mode
        requestedModel = model
        self.effort = effort
        self.scope = scope
        siteScope = scope.sites
        reportedTools = tools
        handles.sharedTabIDs = attachedTabIDs
        for tabID in attachedTabIDs { _ = handles.tabs.handle(for: tabID) }
    }

    /// The folder name from the task's first words: at most six words and 40 characters.
    static func title(forTask task: String) -> String {
        let words = task.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        guard !words.isEmpty else { return "Agent Task" }
        return words.count > 40 ? String(words.prefix(39)) + "\u{2026}" : words
    }

    /// The AI interface's error, as its streams end with one.
    static func aiError(_ error: Error) -> AIError {
        error as? AIError ?? .invalidRequest(error.localizedDescription)
    }

    var isFromOutsideClient: Bool {
        if case .outsideClient = origin { return true }
        return false
    }

    /// The grant of the outside client that started the session.
    var grantID: UUID? {
        if case .outsideClient(let grantID, _, _) = origin { return grantID }
        return nil
    }

    /// Who started the session, as the activity log names it.
    var clientName: String {
        if case .outsideClient(_, let name, _) = origin { return name }
        return "Arch"
    }

    // MARK: Runner

    var commandLineRunner: (any AgentCommandLineRunning)? { runner as? any AgentCommandLineRunning }

    /// Starts driving `runner`, whose events the session reads until it ends. `processRecord` reads each CLI process's start time right after it starts.
    func attach(_ runner: any AgentSessionRunning, processRecord: @escaping (pid_t) -> AgentProcessRecord?) {
        self.runner = runner
        // Calls wait again from each CLI process's start until its start check passed and it gave its first output (`ready` or `processReady`), as after a Retry or a Stop's new process.
        commandLineRunner?.processDidStart = { [weak self] processID in
            self?.spawnedProcess = processRecord(processID)
            self?.ready.close()
        }
        let events = runner.events
        Task { [weak self] in
            do {
                for try await event in events {
                    guard let self else { return }
                    self.handle(event, from: runner)
                }
                self?.runnerEnded(runner, error: nil)
            } catch {
                self?.runnerEnded(runner, error: Self.aiError(error))
            }
        }
    }

    /// The CLI process that a ticket's peer must descend from: the one running now, as it was when it started.
    var liveProcess: AgentProcessRecord? {
        guard let spawnedProcess, commandLineRunner?.processID == spawnedProcess.processID else { return nil }
        return spawnedProcess
    }

    private func handle(_ event: AIAgentEvent, from runner: any AgentSessionRunning) {
        guard runner === self.runner else { return }
        switch event {
        case .ready(let ref):
            model = ref
            ready.open()
            if state == .starting { state = .running }
        case .processReady:
            ready.open()
        case .text(let text):
            transcript.replyText(text)
            taskEvent?(.text, text)
        case .thinking(let text):
            transcript.thinkingText(text)
        case .usage(let usage):
            transcript.usage(usage)
        case .notice(let text):
            transcript.append(.notice(text))
            taskEvent?(.notice, text)
        case .turnFinished(let end):
            transcript.endTurn(model: model)
            switch end {
            case .completed: taskEvent?(.turnFinished, "The turn ended.")
            case .stopped: taskEvent?(.turnFinished, "The turn was stopped.")
            case .turnLimit:
                transcript.append(.notice("The tool's limit of model requests for one message ended the turn."))
                taskEvent?(.turnFinished, "The tool's limit of model requests for one message ended the turn.")
            }
            turnEnded(end == .stopped ? .stopped : .done)
        case .turnFailed(let error):
            let (sentence, action) = describe(error)
            transcript.append(.error(sentence, action))
            taskEvent?(.failed, sentence)
            turnEnded(.done)
        }
    }

    /// The runner's events ended: after `end(keepingThread:)` without an error, or with the error that ended the session, as when no model started it or a start check refused the tool.
    private func runnerEnded(_ runner: any AgentSessionRunning, error: AIError?) {
        guard runner === self.runner else { return }
        isTurnRunning = false
        queuedMessages = []
        guard let error, !hasEnded else { return }
        var (sentence, action) = describe(error)
        // A conversation never moves to another model, and a new runner would not carry it, so Retry stays for a session no model held.
        if model != nil, action == .retry { action = nil }
        transcript.append(.error(sentence, action))
        state = .failed(sentence, action)
        taskEvent?(.failed, sentence)
    }

    // MARK: Messages

    /// Sends the user's message, or queues it while a turn runs. Throws the runner's refusal, such as for a message that starts with `/` while Claude Code may hold a session with Arch's skills; the message then stays in the composer.
    public func send(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !hasEnded, let runner else { return }
        if case .failed(let sentence, _) = state { throw AgentService.SessionError(message: sentence) }
        try runner.checkMessage(text)
        if isTurnRunning {
            queuedMessages.append(text)
        } else {
            startTurn(text)
        }
    }

    public func removeQueuedMessage(at index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
    }

    /// Sends one message to the runner; a retry sends the last one again without showing it twice.
    private func startTurn(_ text: String, isRetry: Bool = false) {
        guard let runner else { return }
        transcript.beginTurn(text, isRetry: isRetry)
        // The user's own addresses join the scope; an outside client's never do.
        if !isFromOutsideClient { scope.addAddresses(inUserText: text) }
        callsThisTurn = 0
        callEpoch += 1
        let message = hasSentFirstMessage ? text : AgentSessionPreamble.firstMessage(text, attachedTabHandles: handles.sharedTabIDs.map { handles.tabs.handle(for: $0) })
        do {
            if isRetry { try runner.retry(message) } else { try runner.send(message) }
            hasSentFirstMessage = true
            isTurnRunning = true
            state = model == nil ? .starting : .running
        } catch {
            let (sentence, action) = describe(Self.aiError(error))
            transcript.append(.error(sentence, action))
        }
    }

    private func turnEnded(_ next: State) {
        isTurnRunning = false
        state = next
        guard !queuedMessages.isEmpty, !hasEnded else { return }
        startTurn(queuedMessages.removeFirst())
    }

    /// Stop: the running turn ends and the queued messages go; the next message continues the session.
    public func stop() {
        queuedMessages = []
        snapshots = AgentSnapshotStore()
        endCallsOfTheTurn()
        runner?.stop()
    }

    /// The calls waiting at a gate from the turn that ended go on with a refusal, and none of them runs later, as at a Hand Back after Stop.
    private func endCallsOfTheTurn() {
        callEpoch += 1
        ready.release()
        handedBack.release()
    }

    /// The refusal of a call that arrived at `epoch` after its turn ended or its session was stopped.
    func staleCallResult(arrivedAt epoch: Int) -> AgentToolResult? {
        guard epoch != callEpoch || hasEnded else { return nil }
        return AgentToolResult(status: .refused, code: "stopped", text: "The turn this call belonged to ended, so Arch did not run it.")
    }

    /// Retry after a failed turn: the last message again.
    public func retryLastMessage() {
        guard !isTurnRunning, !hasEnded, let text = transcript.lastUserMessage else { return }
        startTurn(text, isRetry: true)
    }

    /// An error that is not the runner's, such as a skill folder that could not be written for a retry.
    func noteError(_ error: Error) {
        transcript.append(.error(error.localizedDescription, .retry))
    }

    // MARK: Mode and take-over

    /// The panel's mode menu, which raises the mode only after the user confirms it. The session's connections learn that their tools changed.
    public func setMode(_ newMode: AgentAccessLevel) {
        guard newMode != mode, !hasEnded else { return }
        mode = newMode
        modeDidChange?()
    }

    /// Take Over: the session pauses, and its calls wait until Hand Back.
    public func takeOver() {
        guard !hasEnded, !isTakenOver else { return }
        takeoverGeneration += 1
        isTakenOver = true
        snapshots = AgentSnapshotStore()
        handedBack.close()
    }

    public func handBack() {
        guard !hasEnded, isTakenOver else { return }
        isTakenOver = false
        handedBack.open()
    }

    // MARK: The tool host

    /// Counts a call against the limits per user turn and per session, or returns the result that refuses it.
    func countCall() -> AgentToolResult? {
        if callsThisSession >= AgentLimits.toolCallsPerSession {
            return AgentToolResult(status: .error, code: "limitReached", text: "This session made \(AgentLimits.toolCallsPerSession) tool calls, the most for a session. Tell the user what is done and what is left.",
                                   structured: ["limits": ["toolCallsPerSession": .number(Double(AgentLimits.toolCallsPerSession))]])
        }
        if callsThisTurn >= AgentLimits.toolCallsPerTurn {
            return AgentToolResult(status: .error, code: "limitReached", text: "This turn made \(AgentLimits.toolCallsPerTurn) tool calls, the most for one message. Tell the user what is done and what is left.",
                                   structured: ["limits": ["toolCallsPerTurn": .number(Double(AgentLimits.toolCallsPerTurn))]])
        }
        callsThisTurn += 1
        callsThisSession += 1
        return nil
    }

    var callsLeftThisTurn: Int { max(AgentLimits.toolCallsPerTurn - callsThisTurn, 0) }
    var callsLeftThisSession: Int { max(AgentLimits.toolCallsPerSession - callsThisSession, 0) }

    /// A tool step from the host.
    func record(_ step: AgentStep) {
        transcript.append(.step(step))
        taskEvent?(.step, step.sentence)
    }

    /// A ticket from a process outside the session's tree, once per session.
    func noteForeignTicketUse() {
        guard !hasNotedForeignTicket else { return }
        hasNotedForeignTicket = true
        transcript.append(.notice("Another program tried to use this session\u{2019}s access."))
    }

    /// Ending research ownership retires its original handle even if the user subsequently shares this tab again.
    func forgetResearchTab(_ id: UUID) {
        guard researchPages.removeValue(forKey: id) != nil else { return }
        handles.tabs.remove(id)
        snapshots.remove(id)
    }

    /// A tab the user shares later, with its handle; its site joins the scope.
    func share(tabID: UUID, url: URL?) -> String {
        forgetResearchTab(tabID)
        if !handles.sharedTabIDs.contains(tabID) {
            objectWillChange.send()
            handles.sharedTabIDs.append(tabID)
        }
        if let url { scope.add(url) }
        return handles.tabs.handle(for: tabID)
    }

    func unshare(tabID: UUID) {
        guard handles.sharedTabIDs.contains(tabID) else { return }
        objectWillChange.send()
        snapshots.remove(tabID)
        handles.sharedTabIDs.removeAll { $0 == tabID }
        handles.actingSharedTabIDs.remove(tabID)
        handles.tabs.remove(tabID)
        if readerExcerpt?.tabID == tabID { readerExcerpt = nil }
    }

    // MARK: Ending

    /// Ends the session: its calls stop waiting, and its CLI processes and folder go, with Codex's copy of the thread unless `keepingThread`.
    func end(keepingThread: Bool, because reason: String = "The session was deleted.") async {
        guard !hasEnded else { return }
        hasEnded = true
        for id in researchPages.keys { forgetResearchTab(id) }
        snapshots = AgentSnapshotStore()
        readerExcerpt = nil
        queuedMessages = []
        callEpoch += 1
        taskEvent?(.failed, reason)
        ready.shut()
        handedBack.shut()
        if isTurnRunning || state == .starting || state == .running { state = .stopped }
        isTurnRunning = false
        closeOwnedTabs?()
        await runner?.end(keepingThread: keepingThread)
        isCleanedUp = true
    }

    /// At quit, after the time to end the session ran out: the CLI's process group ends at once.
    func endProcessesAtQuit() {
        commandLineRunner?.endProcesses()
    }

    /// Gives the session a new runner after one that failed, as Retry does when no model started it; the first message goes again with the preamble.
    func replaceRunner(_ newRunner: any AgentSessionRunning, processRecord: @escaping (pid_t) -> AgentProcessRecord?) {
        hasSentFirstMessage = false
        spawnedProcess = nil
        snapshots = AgentSnapshotStore()
        callEpoch += 1
        ready.close()
        state = .starting
        attach(newRunner, processRecord: processRecord)
    }
}
