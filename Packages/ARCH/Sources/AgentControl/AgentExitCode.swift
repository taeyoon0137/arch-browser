// `arch-cli`'s exit codes and the result statuses they report (docs/agents.md, arch-cli; Tools ▸ Results). Codes 69, 70, 75, and 77 follow `sysexits.h`: unavailable, internal software error, temporary failure, and permission denied.
import Foundation

public enum AgentExitCode: Int32, CaseIterable, Sendable {
    case done = 0
    case toolError = 1
    case usage = 2
    case denied = 3
    case refused = 4
    case timedOut = 5
    case noGrant = 6
    case unavailable = 69
    case internalError = 70
    case protocolMismatch = 75
    case notArch = 77

    /// The exit code for the status of the result a command ends with.
    public init(status: AgentResultStatus) {
        switch status {
        case .ok: self = .done
        case .error, .stale: self = .toolError
        case .denied: self = .denied
        case .refused: self = .refused
        // arch-cli keeps waiting on a pending approval through `approval_wait`, so a command that still ends on one has run out of time.
        case .timeout, .approvalPending: self = .timedOut
        }
    }

    /// What the code means, as `arch-cli --help` lists it.
    public var meaning: String {
        switch self {
        case .done: return "Done."
        case .toolError: return "A tool error, such as a stale ref."
        case .usage: return "A usage error."
        case .denied: return "The user denied the step."
        case .refused: return "A rule in Arch refused the step."
        case .timedOut: return "The step timed out."
        case .noGrant: return "No grant, or Arch refused this client's access."
        case .unavailable: return "Arch is not running, or agent access is off."
        case .internalError: return "An internal error."
        case .protocolMismatch: return "Arch and this program speak different versions of the control protocol."
        case .notArch: return "The socket is not Arch's."
        }
    }
}

/// A tool result's status (docs/agents.md, Tools ▸ Results). `denied` means the user said no; `refused` means a rule did.
public enum AgentResultStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case denied
    case refused
    case stale
    case timeout
    case approvalPending
    case error
}
