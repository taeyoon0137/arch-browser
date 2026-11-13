// The code identity check both ends of the control socket make of each other before a message passes (docs/agents.md, Local control channel ▸ Peer checks, Client checks of Arch): the peer runs as the same user, and its running code is valid and has the expected code directory hash. Arch expects the hash of its bundled `arch-cli`; the client expects that of `Contents/MacOS/Arch` in the bundle that contains it. The rule is the same for Apple Development and ad hoc signatures, and nothing names a signing identity or team. Each frame read afterward must come while the checked process, with the same process ID version, holds the other end.
import Darwin
import Foundation
import Security

/// What the kernel reports about the process at the other end of a connected Unix domain socket.
public struct AgentPeer: Sendable {
    public var userID: uid_t
    public var processID: pid_t
    /// The process ID version, which tells a reused process ID apart.
    public var processIDVersion: Int32
    public var auditToken: audit_token_t

    /// Reads the peer's credentials (`LOCAL_PEERCRED`) and audit token (`LOCAL_PEERTOKEN`). The token is that of the process that last read or wrote the other end, as the process is now: right after `connect`, the one that listened.
    public static func read(socket: Int32) throws -> AgentPeer {
        var credentials = xucred()
        var credentialsLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsLength) == 0, credentials.cr_version == XUCRED_VERSION else {
            throw AgentPeerCheckFailure.unreadablePeer(errno)
        }
        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0 else { throw AgentPeerCheckFailure.unreadablePeer(errno) }
        return AgentPeer(userID: credentials.cr_uid, processID: audit_token_to_pid(token), processIDVersion: audit_token_to_pidversion(token), auditToken: token)
    }

    /// Whether both name one process running one program: the process ID version changes at each `exec`.
    public func isSameProcess(as other: AgentPeer) -> Bool {
        processID == other.processID && processIDVersion == other.processIDVersion
    }
}

public enum AgentPeerCheckFailure: Error, Equatable {
    case unreadablePeer(Int32)
    /// The peer runs as another user.
    case otherUser(uid_t)
    /// Security found no valid code for the peer, with its status.
    case invalidCode(OSStatus)
    /// The peer's code is valid but not the expected code.
    case otherCode
    /// No expected hash: the client runs outside an app bundle, or the bundle's file has no readable signature.
    case noExpectedCode
    /// A frame came while another process, or another program in the same process, held the peer's end than the one checked.
    case peerChanged

    public var description: String {
        switch self {
        case .unreadablePeer(let error): return "the peer's credentials could not be read (\(String(cString: strerror(error))))"
        case .otherUser(let user): return "the peer runs as user \(user)"
        case .invalidCode(let status): return "the peer's code is not valid (\(status))"
        case .otherCode: return "the peer's code is not the expected code"
        case .noExpectedCode: return "this program does not run from inside an Arch bundle"
        case .peerChanged: return "another process than the one checked answered"
        }
    }
}

public enum AgentCodeIdentity {
    /// The code directory hash (`kSecCodeInfoUnique`) of the signed file at a path.
    public static func uniqueHash(ofFileAt url: URL) throws -> Data {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw AgentPeerCheckFailure.invalidCode(status) }
        return try uniqueHash(of: code)
    }

    /// The code directory hash of the running process an audit token names, once Security finds its code valid. The token carries the process ID version, so a process that reused the ID does not pass.
    public static func uniqueHash(ofProcessWith auditToken: audit_token_t) throws -> Data {
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        var status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else { throw AgentPeerCheckFailure.invalidCode(status) }
        status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else { throw AgentPeerCheckFailure.invalidCode(status) }
        // `SecCodeCopySigningInformation` takes a running code as well as a static one (`SecCode.h`), and then reports the hash the kernel holds for the running process.
        return try uniqueHash(of: unsafeBitCast(code, to: SecStaticCode.self))
    }

    private static func uniqueHash(of code: SecStaticCode) throws -> Data {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(code, [], &information)
        guard status == errSecSuccess, let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw AgentPeerCheckFailure.invalidCode(status == errSecSuccess ? errSecCSUnsigned : status)
        }
        return hash
    }
}

/// Checks the process at the other end of a connected socket against an expected code directory hash.
public struct AgentPeerCheck: Sendable {
    public var expectedHash: Data?

    public init(expectedHash: Data?) {
        self.expectedHash = expectedHash
    }

    /// Throws `AgentPeerCheckFailure` unless the peer runs as this process's user with valid code whose hash is the expected one, and returns the peer it checked.
    @discardableResult
    public func verify(socket: Int32) throws -> AgentPeer {
        guard let expectedHash else { throw AgentPeerCheckFailure.noExpectedCode }
        let peer = try AgentPeer.read(socket: socket)
        guard peer.userID == geteuid() else { throw AgentPeerCheckFailure.otherUser(peer.userID) }
        guard try AgentCodeIdentity.uniqueHash(ofProcessWith: peer.auditToken) == expectedHash else { throw AgentPeerCheckFailure.otherCode }
        return peer
    }
}
