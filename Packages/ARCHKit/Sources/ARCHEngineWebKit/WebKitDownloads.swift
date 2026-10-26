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

/// One `WKDownload`. Progress arrives through key-value observing of the download's `Progress`. `WebKitDownloadLifecycle` decides pause, resume, and cancel; the item carries out its decisions on WebKit's objects: a resume restarts from WebKit's resume data, or from the start without it, on the originating web view, or on the list's own web view once that one has closed.
final class WebKitDownloadItem: NSObject, EngineDownloadItem, WKDownloadDelegate {
    let sourceURL: URL
    let pageURL: URL?
    private(set) weak var webContents: (any EngineWebContents)?
    private(set) var targetPath: URL?
    var state: EngineDownloadState { lifecycle.state }
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private var download: WKDownload
    private weak var webView: WKWebView?
    private unowned let owner: WebKitDownloads
    private var lifecycle = WebKitDownloadLifecycle()
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

    /// Runs one of the lifecycle's decisions and reports the item when its state changed.
    private func decide<Value>(_ decision: (inout WebKitDownloadLifecycle) -> Value) -> Value {
        let previous = lifecycle.state
        let value = decision(&lifecycle)
        if lifecycle.state != previous { owner.delegate?.downloads(owner, didUpdate: self) }
        return value
    }

    func pause() {
        guard decide({ $0.pause() }) else { return }
        download.cancel { [weak self] data in
            guard let self, let restart = self.decide({ $0.didStop(resumeData: data) }) else { return }
            self.perform(restart)
        }
    }

    func resume() {
        guard let restart = decide({ $0.resume() }) else { return }
        perform(restart)
    }

    /// Asks WebKit for a new download. One that arrives after the item was cancelled or removed stops.
    private func perform(_ restart: WebKitDownloadLifecycle.Restart) {
        let webView = webView ?? owner.resumingWebView
        let take = { [weak self] (download: WKDownload) in
            guard let self, self.lifecycle.didRestart() else { return download.cancel() }
            self.attach(download)
            self.owner.delegate?.downloads(self.owner, didUpdate: self)
        }
        switch restart {
        case .resumeData(let data): webView.resumeDownload(fromResumeData: data, completionHandler: take)
        case .start: webView.startDownload(using: URLRequest(url: sourceURL), completionHandler: take)
        }
    }

    func cancel() {
        guard decide({ $0.cancel() }) else { return }
        download.cancel()
    }

    func remove() {
        cancel()
        owner.remove(self)
    }

    // MARK: WKDownloadDelegate

    /// WebKit stops a download that gets no destination.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let choose = { [weak self] (url: URL?) in
            guard let self else { return completionHandler(nil) }
            self.targetPath = url
            completionHandler(url)
            if url == nil { _ = self.decide { $0.cancel() } }
        }
        guard let delegate = owner.delegate else { return choose(owner.defaultDestination(for: suggestedFilename)) }
        delegate.downloads(owner, determineFilenameFor: self, defaultFilename: suggestedFilename, completion: choose)
    }

    /// Reports from a download that a resumed one replaced change nothing.
    func downloadDidFinish(_ download: WKDownload) {
        guard download === self.download else { return }
        decide { $0.didFinish() }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === self.download else { return }
        decide { $0.didFail(resumeData: resumeData) }
    }
}

/// The decisions of one download's pause, resume, and cancel, apart from WebKit's objects, so that tests can meet them with WebKit's reports in any order. Each method takes a request of the user or a report of WebKit and returns what the item asks of WebKit.
struct WebKitDownloadLifecycle {
    /// How WebKit starts the download again.
    enum Restart: Equatable {
        case resumeData(Data)
        case start
    }

    private(set) var state: EngineDownloadState = .inProgress
    /// What WebKit left to resume from: a pause's or a failure's resume data.
    private(set) var resumeData: Data?
    /// Set from a pause until WebKit, stopping the download, hands over its resume data.
    private(set) var isStopping = false
    /// Set by a resume while the pause stops the download, which then restarts once the resume data is in.
    private var resumesAfterStop = false
    /// Set from a restart until WebKit hands over the new download.
    private(set) var isRestarting = false

    /// Returns whether WebKit is to stop the download for its resume data. Only a download in progress pauses.
    mutating func pause() -> Bool {
        guard state == .inProgress else { return false }
        state = .paused
        isStopping = true
        return true
    }

    /// WebKit stopped the download that `pause()` paused. A download that finished or was cancelled meanwhile keeps that state. A resume that waited restarts the download, from the start without resume data; otherwise a pause without resume data cancels the download.
    mutating func didStop(resumeData data: Data?) -> Restart? {
        isStopping = false
        guard state == .paused else { return nil }
        resumeData = data
        if resumesAfterStop {
            resumesAfterStop = false
            return restart()
        }
        if data == nil { state = .cancelled }
        return nil
    }

    /// Restarts a paused or failed download, from the start for a failed one that left no resume data. The download stays paused or failed until WebKit hands over the new one, and a second resume meanwhile does nothing. A resume while the pause stops the download waits for its resume data.
    mutating func resume() -> Restart? {
        guard state == .paused || state == .failed, !isRestarting else { return nil }
        guard !isStopping else {
            resumesAfterStop = true
            return nil
        }
        return restart()
    }

    private mutating func restart() -> Restart {
        isRestarting = true
        return resumeData.map(Restart.resumeData) ?? .start
    }

    /// WebKit handed over the download that a restart asked for. Returns whether the item takes it; WebKit is to stop one that arrives after the item was cancelled or finished.
    mutating func didRestart() -> Bool {
        isRestarting = false
        guard state == .paused || state == .failed else { return false }
        resumeData = nil
        state = .inProgress
        return true
    }

    /// Returns whether WebKit is to stop the download, which only one in progress needs. A paused or failed download gives up its resume data.
    mutating func cancel() -> Bool {
        guard state == .inProgress || state == .paused || state == .failed else { return false }
        let isRunning = state == .inProgress
        resumeData = nil
        state = .cancelled
        return isRunning
    }

    /// WebKit reports a finish only once the file is whole, so the download completes whatever was asked of it meanwhile.
    mutating func didFinish() {
        resumeData = nil
        state = .completed
    }

    /// Pausing and cancelling set the state before WebKit reports the interruption, so only a download in progress fails.
    mutating func didFail(resumeData data: Data?) {
        guard state == .inProgress else { return }
        resumeData = data
        state = .failed
    }
}
