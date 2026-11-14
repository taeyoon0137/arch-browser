// The listening end of the control socket (docs/agents.md, Local control channel ▸ Transport; Peer checks): one Unix domain socket in a folder of mode 0700 that Arch checks before it binds, the socket of mode 0600, and for each connection the peer checks before a byte is read, Arch's `ready` first, and before each frame a check that the process holding the peer's end is still the one checked. No TCP, UDP, or other listener exists. The endpoint frames and checks; the service decides what each message may do.
import AgentControl
import Darwin
import Foundation

enum AgentEndpointError: Error, Equatable {
    /// The socket's folder is a symbolic link, not a folder, another user's, or open to others; nothing was bound.
    case unsafeFolder(String)
    /// Another process answers at the socket's path, as a second Arch does; its socket stays.
    case inUse
    /// Something other than a socket sits at the socket's path.
    case unexpectedFile
    case system(String)

    var message: String {
        switch self {
        case .unsafeFolder(let detail): return "The agent socket's folder \(detail), so Arch does not listen."
        case .inUse: return "Another copy of Arch is using the agent channel."
        case .unexpectedFile: return "A file that is not a socket is in the agent socket's place, so Arch does not listen."
        case .system(let detail): return detail
        }
    }
}

/// What the endpoint reports, on the main actor, in the order it happened for each connection.
@MainActor protocol AgentEndpointDelegate: AnyObject {
    func endpoint(_ endpoint: AgentEndpoint, didAccept connection: UUID, peer: AgentPeer)
    func endpoint(_ endpoint: AgentEndpoint, connection: UUID, didReceive message: AgentRPCMessage)
    func endpoint(_ endpoint: AgentEndpoint, didClose connection: UUID)
    /// A connection failed a peer check and was closed: the peer's executable name, when the kernel gave its process, and why.
    func endpoint(_ endpoint: AgentEndpoint, didRefusePeer name: String, reason: String)
}

final class AgentEndpoint: @unchecked Sendable {
    /// How the endpoint reads and checks a peer; the service passes the code identity check against the bundled `arch-cli`, and tests replace either part.
    struct PeerChecks: Sendable {
        var read: @Sendable (Int32) throws -> AgentPeer
        var verify: @Sendable (AgentPeer) throws -> Void
    }

    let location: AgentSocketLocation
    private let checks: PeerChecks
    weak var delegate: (any AgentEndpointDelegate)?

    /// Accepts on this queue; each connection reads and writes on a queue of its own, so that a client that stops reading holds up only itself.
    private let queue = DispatchQueue(label: "xyz.taeyoon.arch.agent.endpoint")
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// The socket file this endpoint bound, so that stopping removes it only while no later listener replaced it.
    private var boundFile: (device: dev_t, inode: ino_t)?
    private var connections: [UUID: Connection] = [:]

    /// How long a write may wait for a client that does not read before the connection closes.
    static let writeTimeoutSeconds = 10

    init(location: AgentSocketLocation, checks: PeerChecks) {
        self.location = location
        self.checks = checks
    }

    var isListening: Bool {
        lock.withLock { listener >= 0 }
    }

    // MARK: Listening

    /// Checks the folder, replaces a socket file that nothing answers at, binds, and listens.
    func start() throws {
        guard !isListening else { return }
        try prepareFolder()
        try removeStaleSocket()
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw AgentEndpointError.system("A socket could not be made: \(String(cString: strerror(errno))).") }
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        var address = location.address()
        // The socket file takes mode 0600 from the umask at bind; the folder's 0700 already keeps other users out.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        let bindError = errno
        umask(previousMask)
        guard bound == 0 else {
            Darwin.close(socket)
            throw AgentEndpointError.system("The agent socket could not be bound: \(String(cString: strerror(bindError))).")
        }
        guard listen(socket, 16) == 0 else {
            let error = errno
            Darwin.close(socket)
            unlink(location.path)
            throw AgentEndpointError.system("The agent socket could not listen: \(String(cString: strerror(error))).")
        }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        var status = stat()
        let file = lstat(location.path, &status) == 0 ? (status.st_dev, status.st_ino) : nil
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(socket) }
        lock.withLock {
            listener = socket
            acceptSource = source
            boundFile = file.map { (device: $0.0, inode: $0.1) }
        }
        source.resume()
    }

    /// Stops listening, removes the socket file, and closes every connection.
    func stop() {
        let (source, file, open) = lock.withLock { () -> (DispatchSourceRead?, (device: dev_t, inode: ino_t)?, [Connection]) in
            defer {
                listener = -1
                acceptSource = nil
                boundFile = nil
                connections = [:]
            }
            return (acceptSource, boundFile, Array(connections.values))
        }
        source?.cancel()
        if let file {
            var status = stat()
            if lstat(location.path, &status) == 0, status.st_dev == file.device, status.st_ino == file.inode { unlink(location.path) }
        }
        for connection in open { connection.close(report: false) }
    }

    /// The folder must be a folder, not a symbolic link, owned by this user, with mode 0700; Arch makes it so when it creates it and never changes one it finds.
    private func prepareFolder() throws {
        let folder = location.folder
        try? FileManager.default.createDirectory(atPath: (folder as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if mkdir(folder, 0o700) != 0, errno != EEXIST {
            throw AgentEndpointError.system("The agent socket's folder could not be made: \(String(cString: strerror(errno))).")
        }
        var status = stat()
        guard lstat(folder, &status) == 0 else { throw AgentEndpointError.system("The agent socket's folder could not be read: \(String(cString: strerror(errno))).") }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw AgentEndpointError.unsafeFolder("is not a folder") }
        guard status.st_uid == geteuid() else { throw AgentEndpointError.unsafeFolder("belongs to another user") }
        guard status.st_mode & 0o777 == 0o700 else { throw AgentEndpointError.unsafeFolder("can be opened by other users") }
    }

    /// A socket file goes only after a `connect` to it fails, so that a second Arch leaves a live one alone.
    private func removeStaleSocket() throws {
        var status = stat()
        guard lstat(location.path, &status) == 0 else { return }
        guard status.st_mode & S_IFMT == S_IFSOCK else { throw AgentEndpointError.unexpectedFile }
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw AgentEndpointError.system("A socket could not be made: \(String(cString: strerror(errno))).") }
        defer { Darwin.close(probe) }
        var address = location.address()
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected == 0 { throw AgentEndpointError.inUse }
        unlink(location.path)
    }

    private func acceptPending() {
        let socket = lock.withLock { listener }
        guard socket >= 0 else { return }
        while true {
            let accepted = accept(socket, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                return
            }
            admit(accepted)
        }
    }

    /// Runs the peer checks before reading a byte; a connection that passes gets `ready` first.
    private func admit(_ socket: Int32) {
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        // The accepted socket inherits the listener's non-blocking flag; its reads come only when bytes wait, and its writes wait up to the timeout.
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) & ~O_NONBLOCK)
        var noSignal: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Self.writeTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let peer: AgentPeer
        do {
            peer = try checks.read(socket)
            try checks.verify(peer)
        } catch {
            let processID = (try? AgentPeer.read(socket: socket))?.processID
            Darwin.close(socket)
            report { $0.endpoint(self, didRefusePeer: processID.flatMap(Self.commandName(of:)) ?? "unknown", reason: Self.describe(error)) }
            return
        }
        let connection = Connection(id: UUID(), socket: socket, peer: peer, endpoint: self)
        lock.withLock { connections[connection.id] = connection }
        report { $0.endpoint(self, didAccept: connection.id, peer: peer) }
        connection.begin()
    }

    // MARK: Connections

    /// Sends one message on a connection; a failed write closes it.
    func send(_ message: AgentRPCMessage, to id: UUID) {
        connection(id)?.send(message)
    }

    /// Closes a connection after the messages sent before.
    func close(_ id: UUID) {
        connection(id)?.close(report: true)
    }

    private func connection(_ id: UUID) -> Connection? {
        lock.withLock { connections[id] }
    }

    fileprivate func connectionDidClose(_ connection: Connection, report shouldReport: Bool) {
        let removed = lock.withLock { connections.removeValue(forKey: connection.id) != nil }
        if removed || shouldReport { report { $0.endpoint(self, didClose: connection.id) } }
    }

    fileprivate func connectionFailedRecheck(_ connection: Connection, reason: String) {
        report { $0.endpoint(self, didRefusePeer: Self.commandName(of: connection.peer.processID) ?? "unknown", reason: reason) }
    }

    fileprivate func recheck(_ connection: Connection) throws {
        let current = try checks.read(connection.socket)
        guard current.isSameProcess(as: connection.peer) else { throw AgentPeerCheckFailure.peerChanged }
    }

    /// Reports on the main queue, which keeps the order in which the reports were made.
    fileprivate func report(_ body: @escaping @MainActor (any AgentEndpointDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let delegate = self?.delegate { body(delegate) }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? AgentPeerCheckFailure)?.description ?? "\(error)"
    }

    /// The kernel's name for a process (`kp_proc.p_comm`), for the activity log's refused peers.
    static func commandName(of processID: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return command.isEmpty ? nil : command
    }
}

/// One accepted connection. Its reads, writes, and closing run on its own queue, in order.
private final class Connection: @unchecked Sendable {
    let id: UUID
    let socket: Int32
    /// The peer as the checks at accept saw it; every frame must come while the same process holds its end.
    let peer: AgentPeer
    private weak var endpoint: AgentEndpoint?
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var reader = AgentFrameReader()
    private var isClosed = false

    init(id: UUID, socket: Int32, peer: AgentPeer, endpoint: AgentEndpoint) {
        self.id = id
        self.socket = socket
        self.peer = peer
        self.endpoint = endpoint
        queue = DispatchQueue(label: "xyz.taeyoon.arch.agent.connection")
    }

    /// Sends `ready`, then starts reading.
    func begin() {
        queue.async { [self] in
            write(.notification(method: AgentControlProtocol.readyMethod, params: nil))
            guard !isClosed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            let socket = socket
            source.setCancelHandler { Darwin.close(socket) }
            self.source = source
            source.resume()
        }
    }

    func send(_ message: AgentRPCMessage) {
        queue.async { [self] in write(message) }
    }

    func close(report: Bool) {
        queue.async { [self] in finish(report: report) }
    }

    private func readAvailable() {
        guard !isClosed else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(socket, &chunk, chunk.count)
        if count < 0, errno == EINTR || errno == EAGAIN { return }
        guard count > 0 else { return finish(report: true) }
        reader.append(Data(chunk[0 ..< count]))
        while !isClosed {
            let frame: Data?
            do {
                frame = try reader.nextMessage()
            } catch {
                return finish(report: true)
            }
            guard let frame else { return }
            // The token names whoever holds the peer's end now: a frame counts only from the process that passed, with the same process ID version.
            do {
                try endpoint?.recheck(self)
            } catch {
                endpoint?.connectionFailedRecheck(self, reason: AgentEndpoint.describe(error))
                return finish(report: true)
            }
            let message: AgentRPCMessage
            do {
                message = try AgentRPCMessage.decode(frame)
            } catch let error as AgentRPCError {
                write(.error(id: nil, error: error))
                continue
            } catch {
                return finish(report: true)
            }
            let id = id
            endpoint?.report { [weak endpoint] delegate in
                if let endpoint { delegate.endpoint(endpoint, connection: id, didReceive: message) }
            }
        }
    }

    private func write(_ message: AgentRPCMessage) {
        guard !isClosed else { return }
        guard let frame = try? AgentFrame.encode(message.encoded()) else { return finish(report: true) }
        let failed = frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(socket, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return true
                }
                offset += written
            }
            return false
        }
        if failed { finish(report: true) }
    }

    private func finish(report: Bool) {
        guard !isClosed else { return }
        isClosed = true
        if let source {
            source.cancel()
        } else {
            Darwin.close(socket)
        }
        endpoint?.connectionDidClose(self, report: report)
    }
}
