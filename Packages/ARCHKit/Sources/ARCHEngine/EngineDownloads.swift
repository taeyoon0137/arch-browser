import Foundation

/// Where a download stands.
public enum EngineDownloadState: String, Codable, Sendable {
    case inProgress
    case paused
    case completed
    case cancelled
    case failed
}

/// One download of an engine, with its addresses, destination, progress, and controls.
public protocol EngineDownloadItem: AnyObject {
    var sourceURL: URL { get }
    /// The address the download was requested at, before any redirect, which `sourceURL` can already follow.
    var requestURL: URL { get }
    /// The address of the page its web contents showed when the download started; nil when they showed none.
    var pageURL: URL? { get }
    /// The web contents that started the download, until they are gone.
    var webContents: (any EngineWebContents)? { get }
    var targetPath: URL? { get }
    var state: EngineDownloadState { get }
    /// Whether the engine can retry this failed download with the original transfer.
    var canRetry: Bool { get }
    var completedBytes: Int64 { get }
    var totalBytes: Int64 { get }
    func pause()
    func resume()
    func cancel()
    func remove()
}

public extension EngineDownloadItem {
    var canRetry: Bool { state == .failed }
    /// An engine whose source address is the requested one reports it for both.
    var requestURL: URL { sourceURL }
}

/// Hears of an engine's downloads as they start, change, and go, and names each download's file.
public protocol EngineDownloadsDelegate: AnyObject {
    func downloads(_ downloads: any EngineDownloads, didCreate item: any EngineDownloadItem)
    func downloads(_ downloads: any EngineDownloads, didUpdate item: any EngineDownloadItem)
    func downloads(_ downloads: any EngineDownloads, didRemove item: any EngineDownloadItem)
    func downloads(_ downloads: any EngineDownloads, determineFilenameFor item: any EngineDownloadItem, defaultFilename: String, completion: @escaping (URL?) -> Void)
}

/// The downloads of one engine profile and the delegate that hears of them.
public protocol EngineDownloads: AnyObject {
    var delegate: (any EngineDownloadsDelegate)? { get set }
    var items: [any EngineDownloadItem] { get }
}
