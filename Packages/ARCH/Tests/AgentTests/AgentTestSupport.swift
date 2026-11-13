// What the agent tests share: a browser host with Personas and spaces in memory, a grant prompt and an authenticator that answer as told, a seal key in memory, a clock, a temporary folder for `agent.json`, the activity log, and the socket, and a client that runs its blocking calls off the main actor, where the service runs. The tests reach no Keychain, window, or Arch; the client is this test process, whose own code the service's peer check expects.
import AgentControl
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

/// A seal key in memory; `failure` makes it act as a Keychain that does not give the key.
final class MemoryKeys: AgentSealKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?
    private var _failure: String?

    init(key: SymmetricKey? = nil) {
        stored = key
    }

    var failure: String? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var key: SymmetricKey? { lock.withLock { stored } }

    func key() async throws -> SymmetricKey? {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            return stored
        }
    }

    func keyCreatingIfNeeded() async throws -> SymmetricKey {
        try lock.withLock {
            if let failure = _failure { throw TestKeyError(message: failure) }
            if let stored { return stored }
            let key = SymmetricKey(size: .bits256)
            stored = key
            return key
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
        let service = AgentService(directory: folder, host: host, version: "9.9.9", dependencies: AgentService.Dependencies(
            location: location,
            keys: keys,
            peerChecks: try checks ?? self.checks(expectedHash: ownCodeHash()),
            identify: { _ in identity.value },
            processStart: { starts.value[$0] },
            prompt: prompt,
            authenticator: authenticator,
            allowsAI: { $0.host != "excluded.example" },
            now: { [unowned self] in self.now }))
        services.append(service)
        return service
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

    func hello(protocol version: Int = AgentControlProtocol.version, ticket: String? = nil) async throws -> AgentHelloAnswer {
        try await Task.detached { try self.connection.hello(AgentHello(protocol: version, client: .cli, version: "9.9.9", ticket: ticket), timeout: 5) }.value
    }

    func callTool(_ name: String, _ arguments: [String: AgentJSON] = [:]) async throws -> AgentToolResult {
        try await Task.detached { try self.connection.callTool(AgentToolCall(name: name, arguments: arguments), timeout: 5) }.value
    }

    func call(_ method: String) async throws -> AgentJSON {
        try await Task.detached { try self.connection.call(method, timeout: 5) }.value
    }

    func receive() async throws -> AgentRPCMessage {
        try await Task.detached { try self.connection.receive(timeout: 5) }.value
    }
}
