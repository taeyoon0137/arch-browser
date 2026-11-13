// The control endpoint (docs/agents.md, Local control channel): a connection from a program that is not Arch's tool, another user, or a process that took over the peer's end is closed before its `hello` is answered and logged as refused; an injected check that expects this test process's code accepts; the socket's folder must be this user's, not a link, and of mode 0700; a stale socket is replaced only when nothing answers; the socket exists only while outside access is on or a session needs it; a client refuses a listener whose code does not match; Arch sends `ready` first; and with outside access off, a `hello` without a ticket is refused without a grant sheet.
import AgentControl
import Darwin
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct EndpointTests {
    @Test func aProgramThatIsNotArchsToolIsRefused() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        for (expected, reason) in [(Data(repeating: 0xAB, count: 20), "the peer's code is not the expected code"), (nil, "this program does not run from inside an Arch bundle")] as [(Data?, String)] {
            let service = try await harness.makeOpenService(checks: harness.checks(expectedHash: expected))
            let client = try TestClient(harness.location)
            await #expect(throws: AgentClientError.closedBeforeAnswer) { try await client.hello() }
            try await waitUntil { service.activity.entries.contains { $0.event == .refusedPeer && $0.outcome == reason } }
            #expect(service.activity.entries.last?.clientName.isEmpty == false)
            service.stop()
        }
    }

    @Test func aCheckThatExpectsThisProcessesCodeAccepts() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await harness.makeOpenService()
        let answer = try await TestClient(harness.location).hello()
        #expect(answer == AgentHelloAnswer(version: "9.9.9", status: .noGrant))
    }

    @Test func anotherUserIsRefused() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try await harness.makeOpenService(checks: harness.checks(expectedHash: ownCodeHash(), readPeer: { socket in
            var peer = try AgentPeer.read(socket: socket)
            peer.userID += 1
            return peer
        }))
        await #expect(throws: AgentClientError.closedBeforeAnswer) { try await TestClient(harness.location).hello() }
        try await waitUntil { service.activity.entries.contains { $0.event == .refusedPeer && $0.outcome == "the peer runs as user \(geteuid() + 1)" } }
    }

    @Test func theFolderMustBeThisUsersPrivateFolder() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let checks = harness.checks(expectedHash: nil)
        let socketFolder = harness.folder.appendingPathComponent("Agent")
        try FileManager.default.createDirectory(at: socketFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(throws: AgentEndpointError.unsafeFolder("can be opened by other users")) { try AgentEndpoint(location: harness.location, checks: checks).start() }
        #expect(!harness.socketExists)
        // A link to a private folder elsewhere is no folder of Arch's.
        try FileManager.default.removeItem(at: socketFolder)
        let elsewhere = harness.folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: socketFolder, withDestinationURL: elsewhere)
        #expect(throws: AgentEndpointError.unsafeFolder("is not a folder")) { try AgentEndpoint(location: harness.location, checks: checks).start() }
        try FileManager.default.removeItem(at: socketFolder)
        let endpoint = AgentEndpoint(location: harness.location, checks: checks)
        try endpoint.start()
        var status = stat()
        #expect(lstat(socketFolder.path, &status) == 0 && status.st_mode & 0o777 == 0o700)
        #expect(lstat(harness.location.path, &status) == 0 && status.st_mode & 0o777 == 0o600)
        endpoint.stop()
        #expect(!harness.socketExists)
    }

    @Test func aStaleSocketIsReplacedOnlyWhenNothingAnswers() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let checks = harness.checks(expectedHash: nil)
        // A socket file that nothing listens at, as a crashed Arch leaves.
        try FileManager.default.createDirectory(at: harness.folder.appendingPathComponent("Agent"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = harness.location.address()
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(bound == 0)
        close(stale)
        #expect(harness.socketExists)
        let first = AgentEndpoint(location: harness.location, checks: checks)
        try first.start()
        #expect(first.isListening)
        // A live listener stays: a second endpoint at its path reports the channel as in use.
        let second = AgentEndpoint(location: harness.location, checks: checks)
        #expect(throws: AgentEndpointError.inUse) { try second.start() }
        second.stop()
        #expect(harness.socketExists)
        first.stop()
        #expect(!harness.socketExists)
    }

    @Test func theSocketExistsOnlyWhileNeeded() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        try await harness.settled(service)
        #expect(!harness.socketExists)
        try await service.setAllowsOutsideClients(true)
        #expect(harness.socketExists)
        try await service.setAllowsOutsideClients(false)
        #expect(!harness.socketExists)
        service.sessionsNeedChannel = true
        #expect(harness.socketExists)
        service.sessionsNeedChannel = false
        #expect(!harness.socketExists)
        service.sessionsNeedChannel = true
        service.stop()
        #expect(!harness.socketExists)
    }

    @Test func aClientRefusesAListenerWhoseCodeDoesNotMatch() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await harness.makeOpenService()
        #expect(throws: AgentClientError.notArch(.otherCode)) {
            try TestClient(harness.location, check: { try AgentPeerCheck(expectedHash: Data(repeating: 0xCD, count: 20)).verify(socket: $0) })
        }
    }

    @Test func archSendsReadyFirst() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await harness.makeOpenService()
        let client = try TestClient(harness.location)
        let first = try await client.receive()
        #expect(first == .notification(method: "ready", params: nil))
    }

    /// The check at accept passes; the next read of the peer's token names another process ID version, as after an `exec`, so Arch drops the frame it read and closes the connection.
    @Test func aFrameFromAnotherProcessThanTheCheckedOneIsRefused() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let reads = Shared(0)
        let service = try await harness.makeOpenService(checks: harness.checks(expectedHash: ownCodeHash(), readPeer: { socket in
            var peer = try AgentPeer.read(socket: socket)
            reads.value += 1
            if reads.value > 1 { peer.processIDVersion += 1 }
            return peer
        }))
        await #expect(throws: AgentClientError.closedBeforeAnswer) { try await TestClient(harness.location).hello() }
        try await waitUntil { service.activity.entries.contains { $0.event == .refusedPeer && $0.outcome == AgentPeerCheckFailure.peerChanged.description } }
        #expect(reads.value == 2)
    }

    @Test func withOutsideAccessOffAHelloIsRefusedWithoutASheet() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let service = try harness.makeService()
        try await harness.settled(service)
        service.sessionsNeedChannel = true
        do {
            _ = try await TestClient(harness.location).hello()
            Issue.record("The hello was answered.")
        } catch let error as AgentClientError {
            guard case .refused(let refusal) = error else { throw error }
            #expect(refusal.reason == .outsideAccessOff)
            #expect(error.exitCode == .unavailable)
        }
        // Until in-app sessions bind them, no ticket names a session.
        do {
            _ = try await TestClient(harness.location).hello(ticket: "c2Vzc2lvbg")
            Issue.record("The hello with a ticket was answered.")
        } catch let error as AgentClientError {
            guard case .refused(let refusal) = error else { throw error }
            #expect(refusal.reason == .ticket)
            #expect(error.exitCode == .noGrant)
        }
        #expect(harness.prompt.requests.isEmpty)
    }

    /// The answer names Arch's version, so that a client of another version reports both and exits 75; this client speaks Arch's version and says another, so it sees the refusal's reason, which exits 75 too.
    @Test func anotherProtocolVersionIsRefusedWithArchsVersion() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await harness.makeOpenService()
        do {
            _ = try await TestClient(harness.location).hello(protocol: 2)
            Issue.record("The hello was answered.")
        } catch let error as AgentClientError {
            guard case .refused(let refusal) = error else { throw error }
            #expect(refusal.reason == .protocolMismatch)
            #expect(error.exitCode == .protocolMismatch)
        }
    }

    @Test func aMethodBeforeHelloClosesTheConnectionAndAnUnknownMethodIsNotFound() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        _ = try await harness.makeOpenService()
        let early = try TestClient(harness.location)
        _ = try await early.receive()
        await #expect(throws: AgentClientError.failed(.invalidRequest("Say hello first, once."))) { try await early.call("tools/list") }
        await #expect(throws: AgentClientError.closed) { try await early.receive() }
        let client = try TestClient(harness.location)
        _ = try await client.hello()
        await #expect(throws: AgentClientError.failed(.methodNotFound("task/start"))) { try await client.call("task/start") }
    }
}
