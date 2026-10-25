import Foundation

public enum EngineDownloadState: String, Codable, Sendable {
    case inProgress
    case paused
    case completed
    case cancelled
    case failed
}

public protocol EngineDownloadItem: AnyObject {
    var id: String { get }
    var sourceURL: URL { get }
    /// The address of the page its web contents showed when the download started; nil when they showed none.
    var pageURL: URL? { get }
    /// The web contents that started the download, until they are gone.
    var webContents: (any EngineWebContents)? { get }
    var targetPath: URL? { get }
    var state: EngineDownloadState { get }
    var completedBytes: Int64 { get }
    var totalBytes: Int64 { get }
    var startTime: Date { get }
    func pause()
    func resume()
    func cancel()
    func remove()
}

public protocol EngineDownloadsDelegate: AnyObject {
    func downloads(_ downloads: any EngineDownloads, didInitializeWith items: [any EngineDownloadItem])
    func downloads(_ downloads: any EngineDownloads, didCreate item: any EngineDownloadItem)
    func downloads(_ downloads: any EngineDownloads, didUpdate item: any EngineDownloadItem)
    func downloads(_ downloads: any EngineDownloads, didRemove item: any EngineDownloadItem)
    func downloads(_ downloads: any EngineDownloads, determineFilenameFor item: any EngineDownloadItem, defaultFilename: String, completion: @escaping (URL?) -> Void)
}

public protocol EngineDownloads: AnyObject {
    var delegate: (any EngineDownloadsDelegate)? { get set }
    var items: [any EngineDownloadItem] { get }
}
