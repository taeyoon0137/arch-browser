// What fills a live folder and how often (docs/bookmarks.md, Live folders ▸ Sources; live folder rules 2, 6, 7, and 8): a feed address or a GitHub search, with the folder's item limit and refresh interval. `TabFolder.live` keeps a configuration in `session.json`.
import Foundation

public enum LiveFolderSource: Codable, Hashable, Sendable {
    /// An RSS or Atom feed over HTTPS. `address` is what `session.json` keeps: the whole address, or for a private feed, whose whole address the Keychain keeps (live folder rule 8), the address without its query and fragment.
    case feed(address: URL, isPrivate: Bool)
    /// A search that the user's `gh` runs.
    case gitHub(search: GitHubSearch)

    public var isGitHub: Bool {
        if case .gitHub = self { return true }
        return false
    }

    /// The source for a feed address the user gave and, when the address has a query, which can carry a token, the whole address for the Keychain. Throws `LiveFolderError.invalidAddress` for an address that is not `http` or `https` or that holds a user name or password. An `http` address becomes `https`, since the app's `URLSession` refuses plain HTTP (live folder rule 2).
    public static func makeFeed(address: URL) throws -> (source: LiveFolderSource, keychainAddress: URL?) {
        let whole = try feedAddress(address)
        guard var components = URLComponents(url: whole, resolvingAgainstBaseURL: false) else { throw LiveFolderError.invalidAddress("This is not a web address.") }
        components.fragment = nil
        guard let query = components.query, !query.isEmpty else {
            components.query = nil
            return (.feed(address: components.url ?? whole, isPrivate: false), nil)
        }
        let wholeWithoutFragment = components.url ?? whole
        components.query = nil
        return (.feed(address: components.url ?? whole, isPrivate: true), wholeWithoutFragment)
    }

    /// `address` checked as a feed address (live folder rules 2 and 7), with `http` replaced by `https`.
    public static func feedAddress(_ address: URL) throws -> URL {
        guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw LiveFolderError.invalidAddress("A feed's address starts with https://.")
        }
        guard components.user == nil, components.password == nil else {
            throw LiveFolderError.invalidAddress("A feed's address cannot hold a user name or password.")
        }
        components.scheme = "https"
        guard let url = components.url else { throw LiveFolderError.invalidAddress("This is not a web address.") }
        return url
    }
}

/// A GitHub search on a host: github.com or a GitHub Enterprise Server host.
public struct GitHubSearch: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case myPullRequests, reviewRequests, assignedIssues, search
    }

    public var host: String
    public var kind: Kind
    /// The user's text in GitHub's search syntax for `search`, empty for the other kinds.
    public var text: String

    public init(host: String = "github.com", kind: Kind, text: String = "") {
        self.host = host
        self.kind = kind
        self.text = text
    }

    /// The search sent to GitHub. Requests to the user's teams need a search of their own with `review-requested:@me` (open decision 4).
    public var query: String {
        switch kind {
        case .myPullRequests: return "is:pr is:open author:@me archived:false sort:updated-desc"
        case .reviewRequests: return "is:pr is:open user-review-requested:@me archived:false sort:updated-desc"
        case .assignedIssues: return "is:issue is:open assignee:@me archived:false sort:updated-desc"
        case .search:
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.contains("sort:") ? text : text + " sort:updated-desc"
        }
    }

    /// The folder's name until the user gives it another.
    public var defaultName: String {
        switch kind {
        case .myPullRequests: return "Pull Requests"
        case .reviewRequests: return "Review Requests"
        case .assignedIssues: return "Issues"
        case .search: return "GitHub Search"
        }
    }

    /// Whether `host` can name a GitHub host for `gh --hostname`: letters, digits, dots, and hyphens, with an optional port, not starting with a hyphen.
    public static func isValidHost(_ host: String) -> Bool {
        guard let first = host.first, first != "-", first != "." else { return false }
        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts[0].isEmpty else { return false }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isASCIIDigit) { return false }
        return parts[0].allSatisfy { $0.isASCIIAlphanumeric || $0 == "." || $0 == "-" }
    }
}

/// A live folder's source, item limit, and refresh interval. Values outside the allowed ones, as in a file edited by hand, take the nearest allowed one.
public struct LiveFolderConfiguration: Codable, Hashable, Sendable {
    public static let itemLimits = [10, 25, 50]
    public static let defaultItemLimit = 25
    /// Minutes between refreshes.
    public static let refreshIntervals = [15, 30, 60, 180]
    /// Live folders in the app (live folder rule 7).
    public static let maximumFolders = 20

    public var source: LiveFolderSource
    public var itemLimit: Int
    /// Minutes between refreshes, one of `refreshIntervals`.
    public var refreshMinutes: Int

    /// Without a refresh interval, a feed refreshes every 30 minutes and a GitHub search every 15 (live folder rule 6).
    public init(source: LiveFolderSource, itemLimit: Int = defaultItemLimit, refreshMinutes: Int? = nil) {
        self.source = source
        self.itemLimit = Self.nearest(to: itemLimit, in: Self.itemLimits)
        self.refreshMinutes = Self.nearest(to: refreshMinutes ?? (source.isGitHub ? 15 : 30), in: Self.refreshIntervals)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try container.decode(LiveFolderSource.self, forKey: .source),
                  itemLimit: try container.decode(Int.self, forKey: .itemLimit),
                  refreshMinutes: try container.decode(Int.self, forKey: .refreshMinutes))
    }

    public var refreshInterval: TimeInterval {
        TimeInterval(refreshMinutes * 60)
    }

    private static func nearest(to value: Int, in allowed: [Int]) -> Int {
        allowed.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIIAlphanumeric: Bool { isASCII && (isLetter || isNumber) }
}
