// What a source lists, and how fetching it can fail (docs/bookmarks.md, Live folders ▸ Feeds and GitHub).
import Foundation

/// One entry of a source: a feed item, a pull request, or an issue. Its tab's saved page is its address and title (bookmark rule 2).
public struct LiveItem: Codable, Hashable, Sendable, Identifiable {
    /// Stable across fetches: a feed item's ID or address, or a GitHub node's address.
    public var id: String
    /// Always `http` or `https`.
    public var url: URL
    /// Plain text, at most `maximumTitleLength` characters.
    public var title: String
    /// A feed item's update or publication date, or a GitHub node's `updatedAt`.
    public var date: Date?
    /// Set for GitHub items.
    public var gitHub: GitHubItem?

    public static let maximumTitleLength = 300

    public init(id: String, url: URL, title: String, date: Date? = nil, gitHub: GitHubItem? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.date = date
        self.gitHub = gitHub
    }
}

/// What a GitHub pull request or issue adds to its item, for the row's symbol and tooltip. Review decisions, mergeable states, and check states keep GitHub's values.
public struct GitHubItem: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pullRequest, issue
    }

    public enum State: String, Codable, Sendable {
        case open, draft, merged, closed
    }

    public enum ReviewDecision: String, Codable, Sendable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    public enum Mergeable: String, Codable, Sendable {
        case mergeable = "MERGEABLE"
        case conflicting = "CONFLICTING"
        case unknown = "UNKNOWN"
    }

    public enum CheckState: String, Codable, Sendable {
        case success = "SUCCESS"
        case failure = "FAILURE"
        case pending = "PENDING"
        case error = "ERROR"
        case expected = "EXPECTED"
    }

    public var kind: Kind
    public var state: State
    /// `owner/repo`.
    public var repository: String
    public var number: Int
    /// The author's login; nil for a deleted account.
    public var author: String?
    public var reviewDecision: ReviewDecision?
    public var mergeable: Mergeable?
    /// The state of the last commit's checks.
    public var checks: CheckState?

    public init(kind: Kind, state: State, repository: String, number: Int, author: String?, reviewDecision: ReviewDecision? = nil, mergeable: Mergeable? = nil, checks: CheckState? = nil) {
        self.kind = kind
        self.state = state
        self.repository = repository
        self.number = number
        self.author = author
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.checks = checks
    }

    /// "owner/repo #123 · author".
    public var detail: String {
        let reference = "\(repository) #\(number)"
        guard let author, !author.isEmpty else { return reference }
        return "\(reference) · \(author)"
    }
}

/// Why a refresh or a check failed. Messages name no address, since a private feed's address carries its token (live folder rule 8).
public enum LiveFolderError: Error, Equatable, Sendable, LocalizedError {
    /// An address that cannot be a feed's, with the reason.
    case invalidAddress(String)
    /// The document is neither RSS nor Atom.
    case notAFeed
    /// The document does not parse as XML, with the parser's message.
    case unreadableFeed(String)
    /// An HTTP status other than success and 304. 429 and 503 can carry the time `Retry-After` names.
    case httpStatus(Int, retryAfter: Date?)
    /// The response passed its size limit.
    case tooLarge(bytes: Int)
    case timedOut
    /// The Mac is offline; such a failure does not count toward the backoff (live folder rule 6).
    case offline
    /// Another network failure, with the system's description.
    case network(String)
    case gitHubNotInstalled
    case gitHubSignedOut(host: String)
    /// `gh` failed, with its message.
    case gitHubFailed(String)
    /// GitHub's rate limit, until its reset.
    case rateLimited(until: Date)
    /// A private feed's address is missing from the Keychain.
    case privateAddressMissing
    /// A Keychain failure, with the system's message.
    case keychain(String)

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .invalidAddress(let reason): return reason
        case .notAFeed: return "This address is not an RSS or Atom feed."
        case .unreadableFeed(let detail): return "The feed could not be read: \(detail)"
        case .httpStatus(let status, _): return "The server answered \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))."
        case .tooLarge(let bytes): return "The response is larger than \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))."
        case .timedOut: return "The source did not answer within 30 seconds."
        case .offline: return "The Mac is offline."
        case .network(let detail): return detail
        case .gitHubNotInstalled: return "The GitHub CLI is not installed."
        case .gitHubSignedOut(let host): return "The GitHub CLI is not signed in to \(host)."
        case .gitHubFailed(let detail): return detail
        case .rateLimited: return "GitHub's rate limit was reached."
        case .privateAddressMissing: return "The feed's address is missing from the Keychain."
        case .keychain(let detail): return detail
        }
    }

    public var isOffline: Bool {
        self == .offline
    }

    /// The earliest time to try again that the source named.
    public var retryDate: Date? {
        switch self {
        case .httpStatus(_, let date): return date
        case .rateLimited(let date): return date
        default: return nil
        }
    }
}
