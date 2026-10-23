import Foundation

public struct EngineHistoryItem: Hashable, Codable, Sendable {
    public var id: Int64
    public var url: URL
    public var title: String
    public var lastVisitTime: Date
    public var visitCount: Int
    public var typedCount: Int
    public init(id: Int64, url: URL, title: String, lastVisitTime: Date, visitCount: Int, typedCount: Int) {
        self.id = id
        self.url = url
        self.title = title
        self.lastVisitTime = lastVisitTime
        self.visitCount = visitCount
        self.typedCount = typedCount
    }
}

public struct EngineHistoryQueryOptions: Sendable {
    public var searchText: String?
    public var beginTime: Date?
    public var endTime: Date?
    public var maxResults: Int
    public init(searchText: String? = nil, beginTime: Date? = nil, endTime: Date? = nil, maxResults: Int = 100) {
        self.searchText = searchText
        self.beginTime = beginTime
        self.endTime = endTime
        self.maxResults = maxResults
    }
}

public protocol EngineHistory: AnyObject {
    func query(_ options: EngineHistoryQueryOptions, completion: @escaping ([EngineHistoryItem]) -> Void)
    func mostVisited(limit: Int, completion: @escaping ([EngineHistoryItem]) -> Void)
    func delete(urls: [URL], completion: @escaping () -> Void)
    func deleteAll(completion: @escaping () -> Void)
}

/// No autofill settings here: passwords, cards, and addresses are handled by Apple Passwords or 1Password.
public struct EnginePreferences: Hashable, Codable, Sendable {
    public var downloadFilePath: URL?
    public var promptForDownloadPath: Bool
    public var searchSuggestEnabled: Bool
    public var notificationPermissionRequestsEnabled: Bool
    public init(downloadFilePath: URL? = nil, promptForDownloadPath: Bool = false, searchSuggestEnabled: Bool = true, notificationPermissionRequestsEnabled: Bool = true) {
        self.downloadFilePath = downloadFilePath
        self.promptForDownloadPath = promptForDownloadPath
        self.searchSuggestEnabled = searchSuggestEnabled
        self.notificationPermissionRequestsEnabled = notificationPermissionRequestsEnabled
    }
}

public protocol EngineBrowserContextDelegate: AnyObject {
    func browserContextDidStartRestoringSession(_ context: any EngineBrowserContext)
    func browserContextDidFinishRestoringSession(_ context: any EngineBrowserContext)
    func browserContextDidSkipRestoringSession(_ context: any EngineBrowserContext)
    func browserContextDidDestroy(_ context: any EngineBrowserContext)
}

/// A browser context (profile): history, downloads, preferences, and session.
public protocol EngineBrowserContext: AnyObject {
    var id: EngineBrowserContextID { get }
    var type: EngineBrowserContextType { get }
    var userVisibleName: String { get }
    var delegate: (any EngineBrowserContextDelegate)? { get set }
    var history: any EngineHistory { get }
    var downloads: any EngineDownloads { get }
    var preferences: EnginePreferences { get set }
    /// Tier 2 capability. nil when the engine does not support it.
    var extensions: (any EngineExtensions)? { get }
}
