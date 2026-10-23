// Download list for one Chromium browser context. Each embedded browser reports its downloads here through the bridge.
import ARCHEngine
import CEFBridge
import Foundation

/// Every download started from the context's tabs. An item stays listed until `remove()`.
public final class ChromiumDownloads: EngineDownloads {
    public weak var delegate: (any EngineDownloadsDelegate)?
    public private(set) var items: [any EngineDownloadItem] = []
    private var itemsByIdentifier: [UInt32: ChromiumDownloadItem] = [:]

    /// Announces a new download and asks the delegate where to save it. Without a delegate the engine shows its Save As dialog.
    func begin(_ download: ARCHCEFDownload, suggestedName: String, decision: @escaping (String?, Bool) -> Void) {
        let item = ChromiumDownloadItem(download: download, owner: self)
        itemsByIdentifier[download.identifier] = item
        items.append(item)
        delegate?.downloads(self, didCreate: item)
        guard let delegate else { return decision(nil, true) }
        delegate.downloads(self, determineFilenameFor: item, defaultFilename: suggestedName) { url in
            // The engine has no way to refuse at this point, so a refused download starts and is cancelled on its first update.
            if url == nil { download.cancel() }
            decision(url?.path, false)
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

/// One Chromium download. CEF reports no paused state, so the item tracks its own pause requests.
final class ChromiumDownloadItem: EngineDownloadItem {
    let id: String
    let sourceURL: URL
    let startTime = Date()
    let download: ARCHCEFDownload
    private unowned let owner: ChromiumDownloads
    private var isPaused = false
    private(set) var targetPath: URL?
    private(set) var state: EngineDownloadState = .inProgress
    private(set) var completedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0

    init(download: ARCHCEFDownload, owner: ChromiumDownloads) {
        self.download = download
        self.owner = owner
        id = String(download.identifier)
        sourceURL = URL(string: download.url) ?? URL(string: "about:blank")!
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

    func resume() {
        guard state == .paused || state == .failed else { return }
        isPaused = false
        state = .inProgress
        download.resume()
        owner.delegate?.downloads(owner, didUpdate: self)
    }

    func cancel() {
        guard state == .inProgress || state == .paused else { return }
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
