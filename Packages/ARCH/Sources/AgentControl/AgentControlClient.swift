// The client end of the control socket, for `arch-cli` and `arch-mcp` (docs/agents.md, Local control channel ▸ Client checks of Arch; Framing and methods): it connects, checks that the listening process is the Arch of the bundle that contains the client before it sends a byte, waits for Arch's `ready`, and says `hello`. Every frame it reads must come while the checked process holds Arch's end. Calls are blocking, which suits a command-line process that does one thing at a time.
import Darwin
import Foundation
import Security

public enum AgentClientError: Error, Equatable {
    /// Neither the home folder's socket path nor the temporary folder's fits `sun_path`.
    case noSocketLocation
    /// Nothing listens at the socket's path: Arch is not running, or no agent feature uses the socket.
    case notRunning
    /// The listener failed the code identity check; nothing was sent.
    case notArch(AgentPeerCheckFailure)
    /// Arch speaks another control protocol version, named here.
    case protocolMismatch(arch: Int)
    case refused(AgentRefusal)
    /// Arch closed the connection before it answered `hello` or before `ready`, as it does for a client that fails its own peer check.
    case closedBeforeAnswer
    case closed
    case timedOut
    case malformedAnswer(String)
    case system(String)
    /// The user did not allow this client, or Arch asked a moment ago; Arch's sentence.
    case noGrant(String)
    /// The grant ended while the call ran; Arch's sentence.
    case revoked(String)
    /// Arch answered a method with a JSON-RPC error.
    case failed(AgentRPCError)

    public var exitCode: AgentExitCode {
        switch self {
        case .noSocketLocation, .timedOut, .malformedAnswer, .system, .failed: return .internalError
        case .notRunning, .closed: return .unavailable
        case .notArch: return .notArch
        case .protocolMismatch: return .protocolMismatch
        case .closedBeforeAnswer, .noGrant, .revoked: return .noGrant
        case .refused(let refusal):
            switch refusal.reason {
            case .protocolMismatch: return .protocolMismatch
            case .outsideAccessOff: return .unavailable
            default: return .noGrant
            }
        }
    }

    /// One sentence for the user.
    public var message: String {
        switch self {
        case .noSocketLocation: return "The home folder's path is too long for Arch's control socket, and so is the temporary folder's."
        case .notRunning: return "Arch is not running, or agent access is off. Open Arch and turn on Allow Outside Clients in Settings ▸ AI ▸ Agents."
        case .notArch(let failure):
            switch failure {
            case .invalidCode(errSecCSStaticCodeChanged), .otherCode:
                // A bundle rebuilt or updated under a running Arch fails validity with a changed static code, and another copy of Arch has another hash; both look like a stranger, so the sentence names the likely fix without claiming either.
                return "The program at Arch's socket is not the Arch that contains this arch-cli (\(failure.description)). If Arch was rebuilt or updated while open, or another copy of Arch is open, quit Arch and open the one that contains this arch-cli."
            default:
                return "The socket is not Arch's: \(failure.description)."
            }
        case .protocolMismatch(let arch): return "Arch speaks version \(arch) of the control protocol, and this program speaks version \(AgentControlProtocol.version). Use the arch-cli inside the running Arch."
        case .refused(let refusal): return refusal.message
        case .closedBeforeAnswer: return "Arch refused this connection. Use the arch-cli inside the running Arch."
        case .closed: return "Arch closed the connection."
        case .timedOut: return "Arch did not answer."
        case .malformedAnswer(let detail): return "Arch's answer could not be read: \(detail)"
        case .system(let detail): return detail
        case .noGrant(let message), .revoked(let message): return message
        case .failed(let error): return "Arch could not answer: \(error.message)"
        }
    }
}

public final class AgentControlConnection {
    private let socket: Int32
    /// The listener as the check saw it.
    private let peer: AgentPeer
    private var reader = AgentFrameReader()
    private var nextRequestID = 1

    /// The check of the client's own bundle: the listener must run `Contents/MacOS/Arch` of the app bundle that contains this executable, which outside an app bundle nothing does. The expected hash is read only once something listens.
    public static func archCheck(forClientAt executable: URL? = AgentBundleLayout.currentExecutable()) -> (Int32) throws -> AgentPeer {
        { socket in
            let layout = executable.flatMap(AgentBundleLayout.containing(helper:))
            let expected = layout.flatMap { try? AgentCodeIdentity.uniqueHash(ofFileAt: $0.archExecutableURL) }
            return try AgentPeerCheck(expectedHash: expected).verify(socket: socket)
        }
    }

    /// Connects to the socket at `location`, then runs `check` on the connected socket before anything is sent. `check` returns the peer it checked, which every frame read later must still name. A failed check closes the connection.
    public init(location: AgentSocketLocation, check: (Int32) throws -> AgentPeer) throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw AgentClientError.system("A socket could not be made: \(String(cString: strerror(errno))).") }
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = location.address()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            let error = errno
            Darwin.close(socket)
            if [ENOENT, ECONNREFUSED, ENOTDIR].contains(error) { throw AgentClientError.notRunning }
            throw AgentClientError.system("Arch's control socket could not be reached: \(String(cString: strerror(error))).")
        }
        let peer: AgentPeer
        do {
            peer = try check(socket)
        } catch let failure as AgentPeerCheckFailure {
            Darwin.close(socket)
            throw AgentClientError.notArch(failure)
        } catch {
            Darwin.close(socket)
            throw error
        }
        self.socket = socket
        self.peer = peer
    }

    deinit {
        Darwin.close(socket)
    }

    /// Waits for Arch's `ready`, says `hello`, and returns Arch's answer. Throws for another protocol version and for a refusal, which Arch follows by closing the connection. Call it first: `hello`, with its ticket, goes only after `ready` came from the checked process, so a program that took the socket's path reads nothing.
    public func hello(_ hello: AgentHello, timeout: TimeInterval = 10) throws -> AgentHelloAnswer {
        let id = AgentRPCID.number(nextRequestID)
        nextRequestID += 1
        let request = AgentRPCMessage.request(id: id, method: AgentControlProtocol.helloMethod, params: try AgentJSON(encoding: hello))
        let message: AgentRPCMessage
        do {
            guard case .notification(AgentControlProtocol.readyMethod, _) = try receive(timeout: timeout) else {
                throw AgentClientError.malformedAnswer("its first message is not ready.")
            }
            try send(request)
            message = try receive(timeout: timeout)
        } catch AgentClientError.closed {
            throw AgentClientError.closedBeforeAnswer
        }
        let answer: AgentHelloAnswer
        switch message {
        case .result(id, let result):
            do {
                answer = try result.decode(as: AgentHelloAnswer.self)
            } catch {
                throw AgentClientError.malformedAnswer("its answer to hello is not one this program knows.")
            }
        case .error(_, let error):
            throw AgentClientError.malformedAnswer("it answered hello with an error: \(error.message)")
        default:
            throw AgentClientError.malformedAnswer("it answered hello with another message.")
        }
        guard answer.protocol == AgentControlProtocol.version else { throw AgentClientError.protocolMismatch(arch: answer.protocol) }
        if case .refused(let refusal) = answer.status { throw AgentClientError.refused(refusal) }
        return answer
    }

    /// Calls a method after `hello` and returns its result. Waits as long as Arch takes, which for a first `tools/call` includes the user's answer to the grant sheet, or at most `timeout` seconds for each message when one is given; each `progress` notification for the call goes to `progress`. Throws `noGrant` and `revoked` for Arch's answers that end the client's access.
    public func call(_ method: String, params: AgentJSON? = nil, timeout: TimeInterval? = nil, progress: (String) -> Void = { _ in }) throws -> AgentJSON {
        let id = AgentRPCID.number(nextRequestID)
        nextRequestID += 1
        try send(.request(id: id, method: method, params: params))
        while true {
            switch try receive(timeout: timeout) {
            case .result(id, let result):
                return result
            case .error(id, let error):
                if error.code == AgentControlErrorCode.noGrant { throw AgentClientError.noGrant(error.message) }
                throw AgentClientError.failed(error)
            case .notification(AgentControlMethod.revokedNotification, let params):
                throw AgentClientError.revoked(params?["message"]?.stringValue ?? "Your access to Arch ended.")
            case .notification(AgentControlMethod.progressNotification, let params):
                if let message = params?["message"]?.stringValue { progress(message) }
            default:
                continue
            }
        }
    }

    /// Calls one tool and returns its result.
    public func callTool(_ call: AgentToolCall, timeout: TimeInterval? = nil, progress: (String) -> Void = { _ in }) throws -> AgentToolResult {
        let result = try self.call(AgentControlMethod.toolsCall, params: AgentJSON(encoding: call), timeout: timeout, progress: progress)
        do {
            return try result.decode(as: AgentToolResult.self)
        } catch {
            throw AgentClientError.malformedAnswer("its tool result is not one this program knows.")
        }
    }

    /// Sends one message as one frame.
    public func send(_ message: AgentRPCMessage) throws {
        let frame = try AgentFrame.encode(message.encoded())
        try frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(socket, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EPIPE || errno == ECONNRESET { throw AgentClientError.closed }
                    throw AgentClientError.system("Writing to Arch failed: \(String(cString: strerror(errno))).")
                }
                offset += written
            }
        }
    }

    /// Reads the next message, waiting at most `timeout` seconds for each read when one is given. Throws `notArch(.peerChanged)` and shuts the connection when the message came while another process held Arch's end than the checked one.
    public func receive(timeout: TimeInterval? = nil) throws -> AgentRPCMessage {
        var limit = timeval(tv_sec: Int(timeout ?? 0), tv_usec: Int32(((timeout ?? 0).truncatingRemainder(dividingBy: 1)) * 1_000_000))
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let frame: Data?
            do {
                frame = try reader.nextMessage()
            } catch AgentFrameError.tooLong(let length) {
                throw AgentClientError.malformedAnswer("a frame of \(length) bytes is over the limit.")
            }
            if let frame {
                try confirmPeer()
                do {
                    return try AgentRPCMessage.decode(frame)
                } catch let error as AgentRPCError {
                    throw AgentClientError.malformedAnswer(error.message)
                }
            }
            let count = Darwin.read(socket, &chunk, chunk.count)
            if count == 0 { throw AgentClientError.closed }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw AgentClientError.timedOut }
                if errno == ECONNRESET { throw AgentClientError.closed }
                throw AgentClientError.system("Reading from Arch failed: \(String(cString: strerror(errno))).")
            }
            reader.append(Data(chunk[0 ..< count]))
        }
    }

    /// The kernel's peer token names the process that last read or wrote Arch's end, as that process is now, so the check at connect cannot show who reads and writes afterward. Each frame is therefore checked against the process ID and version that the code check saw; since the version changes at each `exec`, an unchanged pair is the program that passed, and Security need not run again. A peer that has fully closed its end (`ENOTCONN`/`EINVAL`) is not a different live process and cannot read what the client sends next, so the already-buffered frame stands; a live process whose ID or version differs is a handoff and fails.
    private func confirmPeer() throws {
        let current: AgentPeer
        do {
            current = try AgentPeer.read(socket: socket)
        } catch let AgentPeerCheckFailure.unreadablePeer(code) where code == ENOTCONN || code == EINVAL {
            return
        } catch let failure as AgentPeerCheckFailure {
            Darwin.shutdown(socket, SHUT_RDWR)
            throw AgentClientError.notArch(failure)
        }
        guard current.isSameProcess(as: peer) else {
            Darwin.shutdown(socket, SHUT_RDWR)
            throw AgentClientError.notArch(.peerChanged)
        }
    }
}
