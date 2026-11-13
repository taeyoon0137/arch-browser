// The errors an AI request ends with, which of them move a request to the route's next model, and the sentence the interface shows for each.
import Foundation

public enum AIError: Error, Sendable {
    case notConfigured(AINotConfiguredReason)
    case blockedByPolicy(AIPolicyReason)
    case budgetReached(AIBudget)
    case providerUnavailable(AIProviderID, detail: String)
    case authentication(AIProviderID)
    case rateLimited(AIProviderID, until: Date?)
    case contextTooLong(AIProviderID)
    case invalidRequest(String)
    case refused(String)
    case malformedReply(String)
    /// A reply that reached the request's output limit before any text or tool call, or a `.json` reply that reached it before its value was complete.
    case replyTooLong
    case toolRoundLimit
    case cancelled
}

public enum AINotConfiguredReason: Sendable {
    case switchedOff
    case noModel
    case noUsableModel
    case unknownFeature
}

public enum AIPolicyReason: Sendable {
    /// The excluded host, or the scheme for an address without one.
    case siteExcluded(String)
    case dataNotDeclared(AIDataKind)
    case commandLineToolWithPageData
    /// Claude Code or Codex showed a tool, server, skill, or item that Arch did not ask for, so Arch ended it. The text says what, in a sentence.
    case agentUsedOwnTools(String)
}

public enum AIBudget: Sendable {
    case automaticRequestsPerDay
    case monthlySpending
}

extension AIError {
    /// Wraps errors that are not `AIError`, such as task cancellation, so a stream always ends with an `AIError`.
    init(_ error: any Error) {
        switch error {
        case let error as AIError:
            self = error
        case is CancellationError:
            self = .cancelled
        case let error as URLError where error.code == .cancelled:
            self = .cancelled
        default:
            self = .invalidRequest(error.localizedDescription)
        }
    }

    /// Whether the service moves to the route's next model after this error, when no reply text or tool call has reached the caller yet. A rate limit moves on only for a cool-down longer than 10 seconds; the service decides that.
    var movesToNextModel: Bool {
        switch self {
        case .providerUnavailable, .authentication, .rateLimited, .contextTooLong, .malformedReply:
            return true
        case .notConfigured, .blockedByPolicy, .budgetReached, .invalidRequest, .refused, .replyTooLong, .toolRoundLimit, .cancelled:
            return false
        }
    }
}

extension AIError: LocalizedError {
    /// One sentence for the interface. It never contains a key.
    public var errorDescription: String? {
        switch self {
        case .notConfigured(.switchedOff):
            return "This AI feature is switched off in Settings \u{25B8} AI."
        case .notConfigured(.noModel):
            return "Choose a model for this feature in Settings \u{25B8} AI."
        case .notConfigured(.noUsableModel):
            return "None of this feature's models can serve it. Choose another in Settings \u{25B8} AI."
        case .notConfigured(.unknownFeature):
            return "This AI feature is not available."
        case .blockedByPolicy(.siteExcluded(let site)):
            return "AI is off for \(site)."
        case .blockedByPolicy(.dataNotDeclared(let kind)):
            return "This feature does not declare that it sends \(kind.rawValue) data."
        case .blockedByPolicy(.commandLineToolWithPageData):
            return "This command-line tool may run its own tools, so it gets no page data."
        case .blockedByPolicy(.agentUsedOwnTools(let detail)):
            return detail
        case .budgetReached(.automaticRequestsPerDay):
            return "This feature reached its daily limit of automatic requests."
        case .budgetReached(.monthlySpending):
            return "AI requests reached this month's spending limit."
        case .providerUnavailable(_, let detail):
            return "The provider is unavailable: \(detail)"
        case .authentication:
            return "The provider did not accept the API key."
        case .rateLimited(_, let until):
            guard let until, until > Date() else { return "The provider is limiting requests. Try again shortly." }
            return "The provider is limiting requests. Try again in \(Int(until.timeIntervalSinceNow.rounded(.up))) seconds."
        case .contextTooLong:
            return "The request is too long for the model."
        case .invalidRequest(let message):
            return "The provider rejected the request: \(message)"
        case .refused(let message):
            return message.isEmpty ? "The model declined to answer." : "The model declined to answer: \(message)"
        case .malformedReply(let message):
            return "The reply could not be read: \(message)"
        case .replyTooLong:
            return "The reply reached its length limit before it was complete."
        case .toolRoundLimit:
            return "The model made too many rounds of tool calls."
        case .cancelled:
            return "The request was cancelled."
        }
    }
}
