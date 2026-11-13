// The client end of the control socket against a listener in a temporary folder, which stands in for Arch: no listener reads as Arch not running (exit 69); the code identity check runs before a byte is sent, passes for the listener's own code, and fails for other code and outside an app bundle (exit 77); `hello` carries the protocol version and returns the answer; another protocol version exits 75, a refusal with outside access off 69, and a connection closed before the answer 6.
import AgentControl
import Darwin
import Foundation
import Security
import Testing

/// A listening socket in a temporary folder of its own, removed when the listener goes.
private final class TestListener {
    let folder: URL
    let location: AgentSocketLocation
    private let socket: Int32

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("act-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location = AgentSocketLocation(path: folder.appendingPathComponent("c.sock").path, isInTemporaryFolder: true)
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = location.address()
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(socket, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    deinit {
        close(socket)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Accepts one connection on another thread and hands it to `serve`; `wait()` waits for `serve` to return.
    func serveOnce(_ serve: @escaping (Int32) -> Void) -> () -> Bool {
        let done = DispatchSemaphore(value: 0)
        let listening = socket
        DispatchQueue.global().async {
            let connection = accept(listening, nil, nil)
            if connection >= 0 {
                serve(connection)
                close(connection)
            }
            done.signal()
        }
        return { done.wait(timeout: .now() + 10) == .success }
    }

    /// Reads one framed message, or nil at the end of the stream; gives up after two seconds.
    static func readMessage(from connection: Int32) -> AgentRPCMessage? {
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var reader = AgentFrameReader()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let message = try? reader.nextMessage() { return try? AgentRPCMessage.decode(message) }
            let count = read(connection, &chunk, chunk.count)
            guard count > 0 else { return nil }
            reader.append(Data(chunk[0 ..< count]))
        }
    }

    /// Answers the `hello` request it reads with `answer`, and returns the request's params.
    static func answerHello(on connection: Int32, with answer: AgentHelloAnswer) -> AgentJSON? {
        guard case .request(let id, "hello", let params)? = readMessage(from: connection) else { return nil }
        let frame = try! AgentFrame.encode(AgentRPCMessage.result(id: id, result: AgentJSON(encoding: answer)).encoded())
        _ = frame.withUnsafeBytes { write(connection, $0.baseAddress!, $0.count) }
        return params
    }
}

private func ownCodeHash() throws -> Data {
    var code: SecCode?
    try #require(SecCodeCopySelf([], &code) == errSecSuccess)
    var information: CFDictionary?
    try #require(SecCodeCopySigningInformation(unsafeBitCast(code!, to: SecStaticCode.self), [], &information) == errSecSuccess)
    return try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
}

private let passes: (Int32) throws -> Void = { _ in }

@Suite(.serialized) struct ClientTests {
    @Test func noListenerMeansArchIsNotRunning() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("act-none")
        let location = AgentSocketLocation(path: folder.appendingPathComponent("c.sock").path, isInTemporaryFolder: true)
        #expect(throws: AgentClientError.notRunning) { try AgentControlConnection(location: location, check: passes) }
        #expect(AgentClientError.notRunning.exitCode.rawValue == 69)
    }

    @Test func theListenersOwnCodePassesAndOtherCodeDoesNot() throws {
        let listener = try TestListener()
        let expected = try ownCodeHash()
        for (hash, failure) in [(expected, nil), (Data(repeating: 0xAB, count: expected.count), AgentPeerCheckFailure.otherCode), (nil, .noExpectedCode)] as [(Data?, AgentPeerCheckFailure?)] {
            let received = CountBox()
            let wait = listener.serveOnce { connection in
                var byte: UInt8 = 0
                var limit = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                received.count = read(connection, &byte, 1)
            }
            if let failure {
                #expect(throws: AgentClientError.notArch(failure)) {
                    try AgentControlConnection(location: listener.location, check: { try AgentPeerCheck(expectedHash: hash).verify(socket: $0) })
                }
                #expect(wait())
                // The check failed before a byte was sent: the listener reads the end of the stream.
                #expect(received.count == 0)
            } else {
                let connection = try AgentControlConnection(location: listener.location, check: { try AgentPeerCheck(expectedHash: hash).verify(socket: $0) })
                try connection.send(.notification(method: "ping", params: nil))
                #expect(wait())
                #expect(received.count == 1)
            }
        }
    }

    @Test func aClientOutsideAnAppBundleExpectsNoCode() throws {
        let listener = try TestListener()
        let wait = listener.serveOnce { _ in }
        #expect(throws: AgentClientError.notArch(.noExpectedCode)) {
            try AgentControlConnection(location: listener.location, check: AgentControlConnection.archCheck(forClientAt: URL(fileURLWithPath: "/usr/local/bin/arch-cli")))
        }
        #expect(wait())
        #expect(AgentClientError.notArch(.noExpectedCode).exitCode.rawValue == 77)
    }

    @Test func helloReturnsArchsAnswer() throws {
        let listener = try TestListener()
        let answer = AgentHelloAnswer(version: "0.1.0", status: .granted(AgentGrantSummary(level: .readOnly, persona: "Agents", expiry: .whenArchQuits)))
        let params = JSONBox()
        let wait = listener.serveOnce { params.value = TestListener.answerHello(on: $0, with: answer) }
        let connection = try AgentControlConnection(location: listener.location, check: passes)
        #expect(try connection.hello(AgentHello(client: .cli, version: "0.1.0")) == answer)
        #expect(wait())
        #expect(params.value == ["protocol": 1, "client": "arch-cli", "version": "0.1.0"])
    }

    @Test func anotherProtocolVersionExits75() throws {
        let listener = try TestListener()
        let wait = listener.serveOnce { _ = TestListener.answerHello(on: $0, with: AgentHelloAnswer(protocol: 2, version: "0.2.0", status: .refused(AgentRefusal(reason: .protocolMismatch, message: "Arch speaks version 2.")))) }
        let connection = try AgentControlConnection(location: listener.location, check: passes)
        #expect(throws: AgentClientError.protocolMismatch(arch: 2)) { try connection.hello(AgentHello(client: .cli, version: "0.1.0")) }
        #expect(wait())
        #expect(AgentClientError.protocolMismatch(arch: 2).exitCode.rawValue == 75)
    }

    @Test func aRefusalWithOutsideAccessOffExits69() throws {
        let listener = try TestListener()
        let refusal = AgentRefusal(reason: .outsideAccessOff, message: "Outside access is off.")
        let wait = listener.serveOnce { _ = TestListener.answerHello(on: $0, with: AgentHelloAnswer(version: "0.1.0", status: .refused(refusal))) }
        let connection = try AgentControlConnection(location: listener.location, check: passes)
        #expect(throws: AgentClientError.refused(refusal)) { try connection.hello(AgentHello(client: .cli, version: "0.1.0")) }
        #expect(wait())
        #expect(AgentClientError.refused(refusal).exitCode.rawValue == 69)
    }

    @Test func aConnectionClosedBeforeTheAnswerExits6() throws {
        let listener = try TestListener()
        let wait = listener.serveOnce { _ = TestListener.readMessage(from: $0) }
        let connection = try AgentControlConnection(location: listener.location, check: passes)
        #expect(throws: AgentClientError.closedBeforeAnswer) { try connection.hello(AgentHello(client: .cli, version: "0.1.0")) }
        #expect(wait())
        #expect(AgentClientError.closedBeforeAnswer.exitCode.rawValue == 6)
    }

    @Test func aListenerThatDoesNotAnswerTimesOut() throws {
        let listener = try TestListener()
        let release = DispatchSemaphore(value: 0)
        let wait = listener.serveOnce { _ in release.wait() }
        let connection = try AgentControlConnection(location: listener.location, check: passes)
        #expect(throws: AgentClientError.timedOut) { try connection.hello(AgentHello(client: .cli, version: "0.1.0"), timeout: 0.2) }
        release.signal()
        #expect(wait())
    }
}

private final class CountBox: @unchecked Sendable {
    var count = -1
}

private final class JSONBox: @unchecked Sendable {
    var value: AgentJSON?
}
