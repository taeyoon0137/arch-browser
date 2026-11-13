// What the agent tests share: a browser host with Personas and spaces in memory, a grant prompt and an authenticator that answer as told, a seal key in memory, a clock, a temporary folder for `agent.json`, the activity log, and the socket, and a client that runs its blocking calls off the main actor, where the service runs. The tests reach no Keychain, window, or Arch; the client is this test process, whose own code the service's peer check expects.
import AgentControl
import AI
import AppKit
import ARCHEngine
import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import Agent

@MainActor final class FakeHost: AgentBrowserHost {
    var personas: [AgentPersonaInfo]
    var spacesByPersona: [UUID: [AgentSpaceInfo]]
    var tabs: [AgentTabInfo] = []
    private(set) var agentOnlyPersonaID: UUID?
    private(set) var madeAgentsPersonas = 0
    var personasDidChange: (() -> Void)?

    nonisolated static let defaultPersona = AgentPersonaInfo(id: UUID(uuidString: "D59DAF4B-E372-4AF9-890E-455B8B3860F3")!, name: "Default")
    nonisolated static let workPersona = AgentPersonaInfo(id: UUID(), name: "Work")

    init() {
        personas = [Self.defaultPersona, Self.workPersona]
        spacesByPersona = [
            Self.defaultPersona.id: [AgentSpaceInfo(id: UUID(), name: "Home"), AgentSpaceInfo(id: UUID(), name: "Reading")],
            Self.workPersona.id: [AgentSpaceInfo(id: UUID(), name: "Office")],
        ]
    }

    func spaces(in personaID: UUID) -> [AgentSpaceInfo] { spacesByPersona[personaID] ?? [] }

    func tabs(withIDs ids: Set<UUID>) -> [AgentTabInfo] { tabs.filter { ids.contains($0.id) } }

    func makeAgentsPersona() -> UUID {
        madeAgentsPersonas += 1
        let persona = AgentPersonaInfo(id: UUID(), name: "Agents")
        personas.append(persona)
        spacesByPersona[persona.id] = [AgentSpaceInfo(id: UUID(), name: "Personal")]
        return persona.id
    }

    func setAgentOnlyPersona(_ id: UUID?) { agentOnlyPersonaID = id }

    func windowForSheet() -> NSWindow? { nil }

    func deletePersona(_ id: UUID) {
        personas.removeAll { $0.id == id }
        spacesByPersona[id] = nil
        personasDidChange?()
    }
}

/// A runner on a CLI that records what the session sends and emits the events a test gives it.
@MainActor final class FakeRunner: AgentSessionRunning {
    let request: AIAgentSessionRequest
    let events: AsyncThrowingStream<AIAgentEvent, any Error>
    private let continuation: AsyncThrowingStream<AIAgentEvent, any Error>.Continuation
    var processID: pid_t?
    var processDidStart: ((pid_t) -> Void)?
    private(set) var sent: [String] = []
    private(set) var stops = 0
    private(set) var endedKeepingThread: Bool?
    private(set) var activeToolCalls = 0
    private(set) var toolCalls = 0
    private(set) var reportedTools: [[String]] = []

    init(request: AIAgentSessionRequest) {
        self.request = request
        (events, continuation) = AsyncThrowingStream.makeStream()
    }

    /// The CLI process starts, as `posix_spawn` returns.
    func startProcess(_ processID: pid_t) {
        self.processID = processID
        processDidStart?(processID)
    }

    func emit(_ event: AIAgentEvent) {
        continuation.yield(event)
    }

    func fail(_ error: AIError) {
        continuation.finish(throwing: error)
    }

    /// As `AIAgentSession` does while Claude Code may hold a session with Arch's skills.
    func checkMessage(_ message: String) throws {
        if request.skills != nil, message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") { throw AIError.blockedByPolicy(.agentMessageIsCommand) }
    }

    func send(_ message: String) throws {
        try checkMessage(message)
        sent.append(message)
    }

    func stop() { stops += 1 }

    func end(keepingThread: Bool) async {
        endedKeepingThread = keepingThread
        processID = nil
        continuation.finish()
    }

    func toolCallDidStart() {
        activeToolCalls += 1
        toolCalls += 1
    }

    func toolCallDidEnd() { activeToolCalls -= 1 }

    func toolListDidChange(_ tools: [String]) { reportedTools.append(tools) }

    func endProcesses() { processID = nil }
}

/// Answers each sheet with the next of `answers`, or Don't Allow once they run out.
@MainActor final class FakePrompt: AgentGrantPrompting {
    var answers: [AgentGrantChoice?] = []
    private(set) var requests: [AgentGrantRequest] = []

    func ask(_ request: AgentGrantRequest) async -> AgentGrantChoice? {
        requests.append(request)
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func cancelAll() {}
}

final class FakeAuthenticator: AgentAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer = true
    private var _count = 0

    var answer: Bool {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    var count: Int { lock.withLock { _count } }

    func authenticate(reason: String) async -> Bool {
        lock.withLock {
            _count += 1
            return _answer
        }
    }
}

/// A seal key and its generation in memory; `failure` makes it act as a Keychain that does not give the key.
final class MemoryKeys: AgentSealKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AgentSealKey?
    private var _failure: String?

    init(key: SymmetricKey? = nil) {
        stored = key.map { AgentSealKey(key: $0) }
    }

    var failure: String? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var key: SymmetricKey? { lock.withLock { stored?.key } }
    /// The generation of the last write recorded.
    var generation: Int? { lock.withLock { stored?.generation } }

    func key() async throws -> AgentSealKey? {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            return stored
        }
    }

    func keyCreatingIfNeeded() async throws -> AgentSealKey {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            if let stored { return stored }
            let key = AgentSealKey(key: SymmetricKey(size: .bits256))
            stored = key
            return key
        }
    }

    func record(_ key: AgentSealKey) async throws {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            stored = key
        }
    }
}

struct TestKeyError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// The code directory hash of this test process's running code, which the service's check expects when the client is this process.
func ownCodeHash() throws -> Data {
    var code: SecCode?
    try #require(SecCodeCopySelf([], &code) == errSecSuccess)
    var information: CFDictionary?
    try #require(SecCodeCopySigningInformation(unsafeBitCast(code!, to: SecStaticCode.self), [], &information) == errSecSuccess)
    return try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
}

/// A mutable value that `@Sendable` closures can read, such as the identity a test hands the service.
final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@MainActor final class Harness {
    let folder: URL
    let location: AgentSocketLocation
    let host = FakeHost()
    let prompt = FakePrompt()
    let authenticator = FakeAuthenticator()
    let keys: MemoryKeys
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let identity = Shared(AgentClientIdentity(key: .signed(identifier: "com.example.agent", team: "ABCDE12345"), name: "agent", executablePath: "/Applications/Agent.app/Contents/MacOS/agent", host: "Agent", isInterpreter: false))
    let processStarts = Shared<[pid_t: AgentProcessStart]>([:])
    /// The process table the tickets' ancestry check reads.
    let processRecords = Shared<[pid_t: AgentProcessRecord]>([:])
    /// The runners the service started, in order, and the requests it started them with.
    private(set) var runners: [FakeRunner] = []
    private(set) var requests: [AIAgentSessionRequest] = []
    var agentModels = [AIModelRef(provider: AIProviderID(rawValue: "claude"), model: "sonnet"), AIModelRef(provider: AIProviderID(rawValue: "codex"), model: "gpt-6")]
    var services: [AgentService] = []

    init(keys: MemoryKeys = MemoryKeys()) throws {
        // Short, so that the socket's path fits `sun_path`.
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location = AgentSocketLocation(path: folder.appendingPathComponent("Agent/control.sock").path, isInTemporaryFolder: true)
        self.keys = keys
    }

    func cleanUp() {
        services.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: folder)
    }

    var settingsURL: URL { folder.appendingPathComponent("agent.json") }

    /// Checks that pass for this test process's own code, with `readPeer` in place of the kernel's report when given.
    func checks(expectedHash: Data?, readPeer: (@Sendable (Int32) throws -> AgentPeer)? = nil) -> AgentEndpoint.PeerChecks {
        let check = AgentPeerCheck(expectedHash: expectedHash)
        return AgentEndpoint.PeerChecks(read: readPeer ?? { try AgentPeer.read(socket: $0) }, verify: { try check.verify($0) })
    }

    func makeService(checks: AgentEndpoint.PeerChecks? = nil) throws -> AgentService {
        let identity = identity
        let starts = processStarts
        let records = processRecords
        let sessionsFolder = folder.appendingPathComponent("sessions", isDirectory: true)
        let service = AgentService(directory: folder, host: host, version: "9.9.9", dependencies: AgentService.Dependencies(
            location: location,
            keys: keys,
            peerChecks: try checks ?? self.checks(expectedHash: ownCodeHash()),
            identify: { _ in identity.value },
            processStart: { starts.value[$0] },
            prompt: prompt,
            authenticator: authenticator,
            allowsAI: { $0.host != "excluded.example" },
            now: { [unowned self] in self.now },
            processRecord: { records.value[$0] },
            startRunner: { [unowned self] request in
                let runner = FakeRunner(request: request)
                self.runners.append(runner)
                self.requests.append(request)
                return runner
            },
            mcpExecutable: URL(fileURLWithPath: "/Applications/Arch.app/Contents/Helpers/arch-mcp"),
            sessionFolder: { sessionsFolder.appendingPathComponent($0.uuidString, isDirectory: true) },
            agentModels: { [unowned self] in self.agentModels },
            toolName: { $0.rawValue == "codex" ? "Codex" : "Claude Code" }))
        services.append(service)
        return service
    }

    /// Makes `processID` a child of `parent`, which started at `start`, in the process table the ticket check reads.
    func addProcess(_ processID: pid_t, parent: pid_t, start: AgentProcessStart = AgentProcessStart(seconds: 1_000, microseconds: 0)) {
        processRecords.value[processID] = AgentProcessRecord(processID: processID, parentID: parent, start: start)
    }

    /// A service whose settings are read and whose outside access is on.
    func makeOpenService(checks: AgentEndpoint.PeerChecks? = nil) async throws -> AgentService {
        let service = try makeService(checks: checks)
        try await settled(service)
        try await service.setAllowsOutsideClients(true)
        return service
    }

    /// Waits until the service has checked `agent.json`.
    func settled(_ service: AgentService) async throws {
        try await waitUntil { service.state != .reading }
    }

    var socketExists: Bool {
        var status = stat()
        return lstat(location.path, &status) == 0
    }
}

/// Polls on the main actor, which lets the endpoint's reports in, for at most five seconds.
@MainActor func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0 ..< 500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("A condition did not come true within five seconds.")
}

/// A client that runs each blocking call on a thread of its own, so that the main actor stays free for the service.
final class TestClient: @unchecked Sendable {
    let connection: AgentControlConnection

    init(_ location: AgentSocketLocation, check: @escaping (Int32) throws -> AgentPeer = { try AgentPeer.read(socket: $0) }) throws {
        connection = try AgentControlConnection(location: location, check: check)
    }

    /// Says `hello` as `arch-cli`, or as `arch-mcp --session` when it presents a ticket, as only that client does.
    func hello(protocol version: Int = AgentControlProtocol.version, ticket: String? = nil, client: AgentClientKind? = nil) async throws -> AgentHelloAnswer {
        let kind = client ?? (ticket == nil ? .cli : .mcp)
        return try await Task.detached { try self.connection.hello(AgentHello(protocol: version, client: kind, version: "9.9.9", ticket: ticket), timeout: 5) }.value
    }

    func callTool(_ name: String, _ arguments: [String: AgentJSON] = [:]) async throws -> AgentToolResult {
        try await Task.detached { try self.connection.callTool(AgentToolCall(name: name, arguments: arguments), timeout: 5) }.value
    }

    func call(_ method: String, params: AgentJSON? = nil) async throws -> AgentJSON {
        try await Task.detached { try self.connection.call(method, params: params, timeout: 5) }.value
    }

    func receive() async throws -> AgentRPCMessage {
        try await Task.detached { try self.connection.receive(timeout: 5) }.value
    }
}
