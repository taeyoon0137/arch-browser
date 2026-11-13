// The client end of the control socket, for `arch-cli` and `arch-mcp` (docs/agents.md, Local control channel ▸ Client checks of Arch; Framing and methods): it connects, checks that the listening process is the Arch of the bundle that contains the client before it sends a byte, and says `hello`. Calls are blocking, which suits a command-line process that does one thing at a time.
import Darwin
import Foundation

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
    /// Arch closed the connection before it answered `hello`, as it does for a client that fails its own peer check.
    case closedBeforeAnswer
    case closed
    case timedOut
    case malformedAnswer(String)
    case system(String)

    public var exitCode: AgentExitCode {
        switch self {
        case .noSocketLocation, .timedOut, .malformedAnswer, .system: return .internalError
        case .notRunning, .closed: return .unavailable
        case .notArch: return .notArch
        case .protocolMismatch: return .protocolMismatch
        case .closedBeforeAnswer: return .noGrant
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
        case .notArch(let failure): return "The socket is not Arch's: \(failure.description)."
        case .protocolMismatch(let arch): return "Arch speaks version \(arch) of the control protocol, and this program speaks version \(AgentControlProtocol.version). Use the arch-cli inside the running Arch."
        case .refused(let refusal): return refusal.message
        case .closedBeforeAnswer: return "Arch refused this connection. Use the arch-cli inside the running Arch."
        case .closed: return "Arch closed the connection."
        case .timedOut: return "Arch did not answer."
        case .malformedAnswer(let detail): return "Arch's answer could not be read: \(detail)"
        case .system(let detail): return detail
        }
    }
}

public final class AgentControlConnection {
    private let socket: Int32
    private var reader = AgentFrameReader()
    private var nextRequestID = 1

    /// The check of the client's own bundle: the listener must run `Contents/MacOS/Arch` of the app bundle that contains this executable, which outside an app bundle nothing does. The expected hash is read only once something listens.
    public static func archCheck(forClientAt executable: URL? = AgentBundleLayout.currentExecutable()) -> (Int32) throws -> Void {
        { socket in
            let layout = executable.flatMap(AgentBundleLayout.containing(helper:))
            let expected = layout.flatMap { try? AgentCodeIdentity.uniqueHash(ofFileAt: $0.archExecutableURL) }
            try AgentPeerCheck(expectedHash: expected).verify(socket: socket)
        }
    }

    /// Connects to the socket at `location`, then runs `check` on the connected socket before anything is sent. A failed check closes the connection.
    public init(location: AgentSocketLocation, check: (Int32) throws -> Void) throws {
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
        do {
            try check(socket)
        } catch let failure as AgentPeerCheckFailure {
            Darwin.close(socket)
            throw AgentClientError.notArch(failure)
        } catch {
            Darwin.close(socket)
            throw error
        }
        self.socket = socket
    }

    deinit {
        Darwin.close(socket)
    }

    /// Says `hello` and returns Arch's answer. Throws for another protocol version and for a refusal, which Arch follows by closing the connection.
    public func hello(_ hello: AgentHello, timeout: TimeInterval = 10) throws -> AgentHelloAnswer {
        let id = AgentRPCID.number(nextRequestID)
        nextRequestID += 1
        let request = AgentRPCMessage.request(id: id, method: AgentControlProtocol.helloMethod, params: try AgentJSON(encoding: hello))
        let message: AgentRPCMessage
        do {
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

    /// Reads the next message, waiting at most `timeout` seconds for each read when one is given.
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
}
