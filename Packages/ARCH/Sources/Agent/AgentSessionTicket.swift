// An in-app session's ticket has 32 random bytes encoded as base64url (docs/agents.md, In-app sessions: tickets).
// The CLI's MCP configuration passes it to `arch-mcp --session`. Arch compares it in constant time and binds the connection only if the session's running CLI process is an ancestor of the peer.
// The ancestor check uses process ID and start time, so a ticket copied from another process's environment binds nothing. The ticket dies with the session.
import Darwin
import Foundation
import Security

struct AgentSessionTicket: Sendable {
    /// What `ARCH_AGENT_TICKET` carries.
    let text: String

    /// A new ticket from Security's random number generator, or nil if it fails; each caller then refuses to start what the ticket was for.
    static func make() -> AgentSessionTicket? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return AgentSessionTicket(bytes: bytes)
    }

    private init(bytes: [UInt8]) {
        text = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Whether a presented ticket is this one. It takes the same time wherever the two differ.
    func matches(_ presented: String) -> Bool {
        Self.constantTimeEqual(Array(text.utf8), Array(presented.utf8))
    }

    /// Compares every byte of the longer of the two, so that neither where they differ nor how long their common start is changes the time it takes; a length mismatch also counts as a difference.
    static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}

/// The process ancestry check of tickets.
enum AgentProcessAncestry {
    /// Longer chains than any real one end the walk as not found.
    static let maximumDepth = 64

    /// Whether `ancestor`, as it was when Arch started it, is the process `processID` or one of its ancestors now. Each step reads the process's parent through `records`; a process that has ended or whose start time differs is not the one Arch started.
    static func isProcess(_ processID: pid_t, descendedFrom ancestor: AgentProcessRecord, records: (pid_t) -> AgentProcessRecord?) -> Bool {
        var current = processID
        for _ in 0 ..< maximumDepth {
            guard current > 1, let record = records(current) else { return false }
            if record.processID == ancestor.processID { return record.start == ancestor.start }
            current = record.parentID
        }
        return false
    }
}
