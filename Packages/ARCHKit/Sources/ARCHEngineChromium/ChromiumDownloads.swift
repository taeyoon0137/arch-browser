// The downloads list for one Chromium browser context. Each embedded browser reports downloads here through the bridge.
import ARCHEngine
import CEFBridge
import Foundation

/// Lists every download started from the context's tabs. Items remain listed until `remove()` is called.
public final class ChromiumDownloads: EngineDownloads {
    public weak var delegate: (any EngineDownloadsDelegate)?
    public private(set) var items: [any EngineDownloadItem] = []
    private var itemsByIdentifier: [UInt32: ChromiumDownloadItem] = [:]

    /// Announces a new download that `webContents` started from the page at `pageURL` and asks the delegate for its destination. The engine shows its Save As dialog if no delegate is set.
    ///
    /// Chromium asks again each time an interrupted download resumes, on its own after a network error or after `resume()`. Such a download keeps its item and the destination it got, which holds its partial file, so the list shows it once, nothing asks where to save it again, and it resumes into the same file.
    func begin(_ download: ARCHCEFDownload, from webContents: ChromiumWebContents, pageURL: URL?, suggestedName: String, decision: @escaping (String?, Bool) -> Void) {
        if let destination = itemsByIdentifier[download.identifier]?.destination { return decision(destination.path, false) }
        let item = ChromiumDownloadItem(download: download, webContents: webContents, pageURL: pageURL, owner: self)
        itemsByIdentifier[download.identifier] = item
        items.append(item)
        delegate?.downloads(self, didCreate: item)
        guard let delegate else { return decision(nil, true) }
        delegate.downloads(self, determineFilenameFor: item, defaultFilename: suggestedName) { [weak item] url in
            // A `nil` destination cancels the download by leaving the callback unexecuted.
            guard let url else { return }
            item?.destination = url
            decision(url.path, false)
        }
    }

    func update(_ download: ARCHCEFDownload) {
        guard let item = itemsByIdentifier[download.identifier] else { return }
        item.refresh()
        delegate?.downloads(self, didUpdate: item)
    }

    func remove(_ item: ChromiumDownloadItem) {
        itemsByIdentifier[item.download.identifier] = nil
        items.removeAll { $0 === item }
        delegate?.downloads(self, didRemove: item)
    }
}

/// One Chromium download. The item tracks its own pause requests because the bridge does not expose CEF's paused state.
final class ChromiumDownloadItem: EngineDownloadItem {
    /// CEF's address after redirects.
    let sourceURL: URL
    let requestURL: URL
    let pageURL: URL?
    private(set) weak var webContents: (any EngineWebContents)?
    let download: ARCHCEFDownload
    private unowned let owner: ChromiumDownloads
    private var isPaused = false
    /// The destination the delegate chose, which a resumed download keeps.
    fileprivate(set) var destination: URL?
    private(set) var targetPath: URL?
    private(set) var state: EngineDownloadState = .inProgress
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0

    init(download: ARCHCEFDownload, webContents: ChromiumWebContents, pageURL: URL?, owner: ChromiumDownloads) {
        self.download = download
        self.webContents = webContents
        self.pageURL = pageURL
        self.owner = owner
        sourceURL = URL(string: download.url) ?? URL(string: "about:blank")!
        requestURL = URL(string: download.originalURL) ?? sourceURL
    }

    func refresh() {
        targetPath = download.path.map { URL(fileURLWithPath: $0) }
        completedBytes = download.receivedBytes
        totalBytes = download.totalBytes
        switch download.state {
        case .inProgress: state = isPaused ? .paused : .inProgress
        case .complete: state = .completed
        case .canceled: state = .cancelled
        case .interrupted: state = .failed
        @unknown default: state = .failed
        }
    }

    func pause() {
        guard state == .inProgress else { return }
        isPaused = true
        state = .paused
        download.pause()
        owner.delegate?.downloads(owner, didUpdate: self)
    }

    /// The engine still considers a paused download in progress. A failed download changes state only when the engine reports that it has resumed.
    func resume() {
        guard state == .paused || state == .failed else { return }
        isPaused = false
        if state == .paused { state = .inProgress }
        download.resume()
        owner.delegate?.downloads(owner, didUpdate: self)
    }

    /// A failed download can still resume, so its page stays open for it; cancelling it discards the partial file and lets that page close.
    func cancel() {
        guard state == .inProgress || state == .paused || state == .failed else { return }
        isPaused = false
        state = .cancelled
        download.cancel()
        owner.delegate?.downloads(owner, didUpdate: self)
    }

    func remove() {
        cancel()
        owner.remove(self)
    }
}
