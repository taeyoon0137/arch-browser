// The errors an AI request ends with, which of them move a request to the route's next model, and the sentence the interface shows for each.
import Foundation

/// The errors an AI request can report to its caller and the interface.
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
    case toolCallLimit
    case cancelled
}

/// A missing or disabled setting that prevents a feature from starting.
public enum AINotConfiguredReason: Sendable {
    case switchedOff
    case noModel
    case noUsableModel
    case unknownFeature
    /// The request named a tier that has no model in Settings ▸ AI ▸ Features.
    case emptyTier(AIModelTier)
}

/// A request refused by Arch's data or route policy.
public enum AIPolicyReason: Sendable {
    /// The excluded host, or the scheme for an address without one.
    case siteExcluded(String)
    case dataNotDeclared(AIDataKind)
    case commandLineToolWithPageData
    /// Claude Code or Codex showed a tool, server, skill, or item that Arch did not ask for, so Arch ended it. The text says what, in a sentence.
    case agentUsedOwnTools(String)
    /// A message that starts with `/` in a session where Claude Code loads Arch's skills, which Claude Code would run as one of its own commands.
    case agentMessageIsCommand
    /// The hook's approved provider destination no longer matches its route or settings.
    case unknownProvider
    /// A request or session named a route or a model for a stored automatic feature, which keeps the models the user chose for it.
    case routeNotAllowed
}

/// The automatic request or spending limit that has been reached.
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
        case .notConfigured, .blockedByPolicy, .budgetReached, .invalidRequest, .refused, .replyTooLong, .toolRoundLimit, .toolCallLimit, .cancelled:
            return false
        }
    }
}

extension AIError: LocalizedError {
    /// Absolute local dates stay meaningful when a user returns to a saved message.
    static func rateLimitMessage(provider: String, until: Date?) -> String {
        guard let until, until > Date() else { return localized("\(provider) is limiting requests.") }
        return localized("\(provider) is limiting requests. Try again after \(until.formatted(date: .abbreviated, time: .standard)).")
    }

    /// One sentence for the interface. It never contains a key.
    public var errorDescription: String? {
        switch self {
        case .notConfigured(.switchedOff):
            return localized("This AI feature is switched off in Settings \u{25B8} AI.")
        case .notConfigured(.noModel):
            return localized("Choose a model for this feature in Settings \u{25B8} AI.")
        case .notConfigured(.noUsableModel):
            return localized("None of this feature\u{2019}s models can serve it. Choose another in Settings \u{25B8} AI.")
        case .notConfigured(.unknownFeature):
            return localized("This AI feature is not available.")
        case .notConfigured(.emptyTier(let tier)):
            return localized("Assign a model to the \(tier.title) tier in Settings \u{25B8} AI.")
        case .blockedByPolicy(.siteExcluded(let site)):
            return localized("AI is off for \(site).")
        case .blockedByPolicy(.dataNotDeclared(let kind)):
            return localized("This feature does not declare that it sends \(kind.rawValue) data.")
        case .blockedByPolicy(.commandLineToolWithPageData):
            return localized("This command-line tool may run its own tools, so it gets no page data.")
        case .blockedByPolicy(.agentUsedOwnTools(let detail)):
            return detail
        case .blockedByPolicy(.agentMessageIsCommand):
            return localized("Claude Code would run a message that starts with \"/\" as one of its own commands, so Arch does not send it.")
        case .blockedByPolicy(.unknownProvider):
            return localized("The provider destination changed. Review it before running this hook.")
        case .blockedByPolicy(.routeNotAllowed):
            return localized("This feature uses the models chosen for it in Settings \u{25B8} AI, so a request cannot name its own.")
        case .budgetReached(.automaticRequestsPerDay):
            return localized("This feature reached its daily limit of automatic requests.")
        case .budgetReached(.monthlySpending):
            return localized("AI requests reached this month\u{2019}s spending limit.")
        case .providerUnavailable(_, let detail):
            return localized("The provider is unavailable: \(detail)")
        case .authentication:
            return localized("The provider did not accept the API key.")
        case .rateLimited(_, let until):
            return Self.rateLimitMessage(provider: localized("The provider"), until: until)
        case .contextTooLong:
            return localized("The request is too long for the model.")
        case .invalidRequest(let message):
            return localized("The provider rejected the request: \(message)")
        case .refused(let message):
            return message.isEmpty ? localized("The model declined to answer.") : localized("The model declined to answer: \(message)")
        case .malformedReply(let message):
            return localized("The reply could not be read: \(message)")
        case .replyTooLong:
            return localized("The reply reached its length limit before it was complete.")
        case .toolCallLimit:
            return localized("The run reached its tool call limit.")
        case .toolRoundLimit:
            return localized("The model made too many rounds of tool calls.")
        case .cancelled:
            return localized("The request was cancelled.")
        }
    }
}
