// The web search engines for palette text that is not an address. Settings saves the choice.
import Foundation

/// A web search engine, saved by its raw value under `ARCHSearchEngine`.
public enum SearchEngine: String, CaseIterable {
    case google
    case bing
    case duckDuckGo

    public static let defaultsKey = "ARCHSearchEngine"

    /// The saved choice, or Google if none is saved.
    public static var current: SearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    public var title: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        }
    }

    /// The results page, which takes the query in its `q` parameter.
    var resultsURL: URL {
        switch self {
        case .google: return URL(string: "https://www.google.com/search")!
        case .bing: return URL(string: "https://www.bing.com/search")!
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/")!
        }
    }
}
