// An in-app session's site scope and the addresses it has seen (docs/agents.md, Permissions, approvals, and injection defenses ▸ Site scope and navigation; rule P13). The scope holds registrable domains: the sites of tabs attached at the start or shared later, of addresses the user wrote in the task or a later message, and of addresses the user allowed. The search engine joins only through its results address. A link the agent follows opens without asking, since the page wrote its address. An address the agent writes opens without asking only when the session has seen it verbatim, when it is the search engine's results address, or when it is the bare origin of a host the session has seen or of a site in scope's own name (the registrable domain or `www.` before it), since a host's label can carry data as a query can; any other written address asks in every mode, because its path, query, or fragment can carry what the agent read elsewhere. A redirect hop of a written address's navigation to a site outside the scope asks with the hop's full address. Site exclusions (rule P16) are the policy's and apply before the scope.
import Foundation

/// Sites as the scope counts them: a host's registrable domain, the part a registrant controls, such as `example.co.uk` for `shop.example.co.uk`.
enum AgentSite {
    /// Two-label suffixes under which different owners register names: country codes' second levels and hosting platforms that give each customer a subdomain. macOS has no public interface to the Public Suffix List, so this list covers the common cases; a suffix it lacks counts a platform's customers as one site, which widens the scope's bare origins and redirect hops but never lets a written address with a path, query, or fragment open without asking.
    static let sharedSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "nhs.uk", "police.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "school.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "gr.jp", "ed.jp", "lg.jp", "ad.jp",
        "co.kr", "ne.kr", "or.kr", "re.kr", "pe.kr", "go.kr", "ac.kr", "mil.kr", "es.kr", "hs.kr", "ms.kr", "sc.kr", "kg.kr",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.tw", "net.tw", "org.tw", "edu.tw", "gov.tw", "idv.tw",
        "com.hk", "net.hk", "org.hk", "edu.hk", "gov.hk", "idv.hk",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "edu.in", "gov.in",
        "co.za", "org.za", "gov.za", "ac.za", "net.za",
        "co.il", "org.il", "ac.il", "gov.il", "net.il",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg",
        "com.my", "net.my", "org.my", "edu.my", "gov.my",
        "co.id", "or.id", "ac.id", "go.id", "web.id",
        "co.th", "or.th", "ac.th", "go.th", "in.th",
        "com.ph", "net.ph", "org.ph", "gov.ph", "edu.ph",
        "com.vn", "net.vn", "org.vn", "edu.vn", "gov.vn",
        "com.mx", "net.mx", "org.mx", "gob.mx", "edu.mx",
        "com.ar", "net.ar", "org.ar", "gob.ar", "edu.ar",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr",
        "com.ua", "net.ua", "org.ua", "gov.ua", "edu.ua",
        "co.at", "or.at", "ac.at", "gv.at",
        "com.es", "org.es", "nom.es", "edu.es", "gob.es",
        "com.pl", "net.pl", "org.pl",
        "github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app", "herokuapp.com", "web.app", "firebaseapp.com",
        "appspot.com", "blogspot.com", "azurewebsites.net", "cloudfront.net", "onrender.com", "fly.dev", "glitch.me", "readthedocs.io",
    ]

    /// The site of an http or https address, or nil for another scheme or no host.
    static func of(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")), !host.isEmpty else { return nil }
        return registrableDomain(of: host)
    }

    /// An IP address, `localhost`, or a one-label host is its own site; otherwise the last two labels, or three under a shared suffix.
    static func registrableDomain(of host: String) -> String {
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return sharedSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }
}

/// The search engine's results page with only the search terms set (`SearchEngine.resultsURL` and its `q`), which is in every session's scope as an address, not as a site, so the engine's redirect endpoints are not.
public struct AgentSearchResultsAddress: Equatable, Sendable {
    public var base: URL
    public var termsParameter: String

    public init(base: URL, termsParameter: String = "q") {
        self.base = base
        self.termsParameter = termsParameter
    }

    /// The same scheme, host, port, and path as `base`, and a query with the terms parameter alone, without a fragment.
    func matches(_ url: URL) -> Bool {
        guard let address = AgentSeenAddress(url), let results = AgentSeenAddress(base), address.origin == results.origin, address.path == results.path,
              url.fragment == nil, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        return items.count == 1 && items[0].name == termsParameter
    }
}

/// An address as the scope compares it: the scheme and host in lower case, without a default port, and with `/` for an empty path. The path, query, and fragment stay as written.
struct AgentSeenAddress: Hashable {
    var origin: String
    var host: String
    var path: String
    var query: String?
    var fragment: String?
    /// No port, or the scheme's own; a bare origin has it, since a port can carry data too.
    var hasDefaultPort: Bool

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let isDefaultPort = components.port == nil || (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443)
        hasDefaultPort = isDefaultPort
        self.host = host
        let credentials = components.percentEncodedUser.map { user in user + (components.percentEncodedPassword.map { ":\($0)" } ?? "") + "@" } ?? ""
        origin = "\(scheme)://\(credentials)\(host)\(isDefaultPort ? "" : ":\(components.port!)")"
        path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        query = components.percentEncodedQuery
        fragment = components.percentEncodedFragment
    }

    /// `https://host/` with nothing after it, on the scheme's own port and without a user name.
    var isBareOrigin: Bool {
        path == "/" && query == nil && fragment == nil && hasDefaultPort && !origin.contains("@")
    }
}

/// What the scope says about an address the agent wrote, or about a redirect hop.
enum AgentScopeDecision: Equatable {
    /// Opens without asking.
    case opens
    /// Asks the user, in every mode (rule P13), with what the card shows.
    case asks(AgentAddressQuestion)
}

/// A P13 question: the full address, the parts of it the session has not seen, and whether its site is outside the scope.
struct AgentAddressQuestion: Equatable {
    enum Part: String, Equatable {
        /// A host of a site in scope that the session never saw, which the address's name alone could carry data to.
        case host, path, query, fragment
    }

    var url: URL
    var unseenParts: [Part]
    var isOutsideScope: Bool

    /// The address as the card shows it, with the ranges of the parts the session has not seen, which the card marks.
    var markedAddress: (text: String, unseen: [Range<String.Index>]) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let text = components.string else { return (url.absoluteString, []) }
        let ranges = unseenParts.compactMap { part -> Range<String.Index>? in
            switch part {
            case .host: return components.rangeOfHost
            case .path: return components.rangeOfPath.flatMap { $0.isEmpty ? nil : $0 }
            case .query: return components.rangeOfQuery
            case .fragment: return components.rangeOfFragment
            }
        }
        return (text, ranges)
    }

    /// The card's sentence, such as "The agent wants to open shop.example/t?d=… — an address no page showed, on a site you did not name."
    var sentence: String {
        var reasons: [String] = []
        if !unseenParts.isEmpty { reasons.append("an address no page showed") }
        if isOutsideScope { reasons.append(unseenParts.isEmpty ? "a site you did not name" : "on a site you did not name") }
        return "The agent wants to open \(url.absoluteString) \u{2014} \(reasons.joined(separator: ", "))."
    }
}

struct AgentSiteScope: Equatable {
    /// The scope's sites in the order they joined.
    private(set) var sites: [String] = []
    private var seen: Set<AgentSeenAddress> = []
    var searchResults: AgentSearchResultsAddress?

    init(searchResults: AgentSearchResultsAddress? = nil) {
        self.searchResults = searchResults
    }

    /// The site of a tab attached or shared, or of an address the user allowed, joins the scope; the address itself is seen.
    mutating func add(_ url: URL) {
        see(url)
        guard let site = AgentSite.of(url), !sites.contains(site) else { return }
        sites.append(site)
    }

    /// The addresses in the user's own words join the scope with their sites, as the task and each later message bring them. Text an outside client wrote never comes here.
    mutating func addAddresses(inUserText text: String) {
        Self.addresses(in: text).forEach { add($0) }
    }

    /// An address the session has seen: a committed address of one of its tabs, or the full address behind a link ref in one of its snapshots.
    mutating func see(_ url: URL) {
        if let address = AgentSeenAddress(url) { seen.insert(address) }
    }

    func contains(_ url: URL) -> Bool {
        AgentSite.of(url).map(sites.contains) ?? false
    }

    /// An address the agent wrote in `open_tab` or `navigate`.
    func written(_ url: URL) -> AgentScopeDecision {
        guard let address = AgentSeenAddress(url) else { return .asks(AgentAddressQuestion(url: url, unseenParts: [.path], isOutsideScope: true)) }
        if seen.contains(address) || searchResults?.matches(url) == true { return .opens }
        let isInScope = contains(url)
        let isHostKnown = knows(host: address.host)
        if address.isBareOrigin, isInScope, isHostKnown { return .opens }
        var parts = unseenParts(of: address)
        // A host label can carry data as a query can, so a host the session never saw asks even without a path.
        if isInScope, !isHostKnown, parts.isEmpty { parts = [.host] }
        return .asks(AgentAddressQuestion(url: url, unseenParts: parts, isOutsideScope: !isInScope))
    }

    /// A redirect hop of a navigation the agent started. A hop of a written address's navigation that leads off the scope asks with the hop's full address; hops of followed links, and hops within the scope, go on.
    func hop(to url: URL, ofWrittenAddress: Bool) -> AgentScopeDecision {
        guard ofWrittenAddress, !contains(url), searchResults?.matches(url) != true else { return .opens }
        let address = AgentSeenAddress(url)
        return .asks(AgentAddressQuestion(url: url, unseenParts: address.map(unseenParts(of:)) ?? [.path], isOutsideScope: true))
    }

    /// Whether a host of a site in scope may open as a bare origin: the registrable domain itself, `www.` before it, or a host the session has seen.
    private func knows(host: String) -> Bool {
        let site = AgentSite.registrableDomain(of: host)
        return host == site || host == "www." + site || seen.contains { $0.host == host }
    }

    /// The parts of an address that no seen address on its origin shares: its path, then its query on that path, then its fragment on that path and query.
    private func unseenParts(of address: AgentSeenAddress) -> [AgentAddressQuestion.Part] {
        let sameOrigin = seen.filter { $0.origin == address.origin }
        let samePath = sameOrigin.filter { $0.path == address.path }
        var parts: [AgentAddressQuestion.Part] = []
        if address.path != "/", samePath.isEmpty { parts.append(.path) }
        let sameQuery = samePath.filter { $0.query == address.query }
        if address.query != nil, sameQuery.isEmpty { parts.append(.query) }
        if address.fragment != nil, !sameQuery.contains(where: { $0.fragment == address.fragment }) { parts.append(.fragment) }
        return parts
    }

    /// The http and https addresses in text, as a link detector finds them: `example.org/plans` reads as `http://example.org/plans`.
    static func addresses(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }
}
