// Adapts `WKDownload` to the `ARCHEngine` download protocols, with one list per browser context.
import ARCHEngine
import Foundation
import WebKit

/// Lists all downloads started from the context's tabs. Items stay listed until `remove()`.
public final class WebKitDownloads: EngineDownloads {
    public weak var delegate: (any EngineDownloadsDelegate)?
    public private(set) var items: [any EngineDownloadItem] = []
    unowned let context: WebKitBrowserContext
    /// Resumes a download whose web view has closed. `resumeDownload` needs a web view in the same data store, and the tab's may be gone.
    lazy var resumingWebView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = context.dataStore
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    init(context: WebKitBrowserContext) {
        self.context = context
    }

    /// Wraps and announces a new WebKit download that `webContents` started.
    func add(_ download: WKDownload, from webContents: WebKitWebContents) {
        let item = WebKitDownloadItem(download: download, webContents: webContents, owner: self)
        items.append(item)
        delegate?.downloads(self, didCreate: item)
    }

    func remove(_ item: WebKitDownloadItem) {
        items.removeAll { $0 === item }
        delegate?.downloads(self, didRemove: item)
    }

    /// When no delegate picks a destination, uses the preferred folder or `~/Downloads` with an unused name. WebKit refuses to overwrite files.
    func defaultDestination(for filename: String) -> URL {
        let directory = context.preferences.downloadFilePath
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
        }
        return candidate
    }
}

/// One `WKDownload`. Progress arrives through key-value observing of the download's `Progress`. Pause keeps WebKit's resume data; resume restarts from it, or from the start without it, on the originating web view, or on the list's own web view once that one has closed.
final class WebKitDownloadItem: NSObject, EngineDownloadItem, WKDownloadDelegate {
    let id = UUID().uuidString
    let sourceURL: URL
    let pageURL: URL?
    private(set) weak var webContents: (any EngineWebContents)?
    private(set) var targetPath: URL?
    private(set) var state: EngineDownloadState = .inProgress
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    let startTime = Date()
    private var download: WKDownload
    private weak var webView: WKWebView?
    private unowned let owner: WebKitDownloads
    private var resumeData: Data?
    /// Set from `resume()` until WebKit hands over the new download.
    private var isResuming = false
    private var observations: [NSKeyValueObservation] = []

    init(download: WKDownload, webContents: WebKitWebContents, owner: WebKitDownloads) {
        let webView = webContents.webView
        self.download = download
        self.webView = webView
        self.webContents = webContents
        self.owner = owner
        self.sourceURL = download.originalRequest?.url ?? webView.url ?? URL(string: "about:blank")!
        // While a navigation turns into a download, the web view's address can already be the download's, so the page is the current back-forward item.
        self.pageURL = webView.backForwardList.currentItem?.url
        super.init()
        attach(download)
    }

    private func attach(_ download: WKDownload) {
        self.download = download
        download.delegate = self
        let progress = download.progress
        observations = [
            progress.observe(\.completedUnitCount) { [weak self] progress, _ in DispatchQueue.main.async { self?.report(progress) } },
            progress.observe(\.totalUnitCount) { [weak self] progress, _ in DispatchQueue.main.async { self?.report(progress) } },
        ]
    }

    private func report(_ progress: Progress) {
        completedBytes = progress.completedUnitCount
        totalBytes = progress.totalUnitCount
        owner.delegate?.downloads(owner, didUpdate: self)
    }

    private func setState(_ newState: EngineDownloadState) {
        state = newState
        owner.delegate?.downloads(owner, didUpdate: self)
    }

    /// A download that finished or was cancelled before WebKit stopped it keeps that state.
    func pause() {
        guard state == .inProgress else { return }
        setState(.paused)
        download.cancel { [weak self] data in
            guard let self, self.state == .paused else { return }
            self.resumeData = data
            if data == nil { self.setState(.cancelled) }
        }
    }

    /// Restarts from the resume data, or from the start for a failed download that left none. The item stays paused or failed until WebKit hands over the new download, and a second call meanwhile does nothing; a download that arrives after the item was cancelled or removed stops.
    func resume() {
        guard state == .paused || state == .failed, !isResuming else { return }
        isResuming = true
        let webView = webView ?? owner.resumingWebView
        let attach = { [weak self] (download: WKDownload) in
            guard let self, self.state == .paused || self.state == .failed else { return download.cancel() }
            self.isResuming = false
            self.resumeData = nil
            self.attach(download)
            self.setState(.inProgress)
        }
        if let resumeData {
            webView.resumeDownload(fromResumeData: resumeData, completionHandler: attach)
        } else {
            webView.startDownload(using: URLRequest(url: sourceURL), completionHandler: attach)
        }
    }

    /// A failed download that could resume gives up its resume data.
    func cancel() {
        guard state == .inProgress || state == .paused || state == .failed else { return }
        if state == .inProgress { download.cancel() }
        resumeData = nil
        setState(.cancelled)
    }

    func remove() {
        cancel()
        owner.remove(self)
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let choose = { [weak self] (url: URL?) in
            guard let self else { return completionHandler(nil) }
            self.targetPath = url
            completionHandler(url)
            if url == nil { self.setState(.cancelled) }
        }
        guard let delegate = owner.delegate else { return choose(owner.defaultDestination(for: suggestedFilename)) }
        delegate.downloads(owner, determineFilenameFor: self, defaultFilename: suggestedFilename, completion: choose)
    }

    /// Reports from a download that a resumed one replaced change nothing.
    func downloadDidFinish(_ download: WKDownload) {
        guard download === self.download else { return }
        setState(.completed)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // Pausing or cancelling sets the state before WebKit reports the interruption.
        guard download === self.download, state == .inProgress else { return }
        self.resumeData = resumeData
        setState(.failed)
    }
}
