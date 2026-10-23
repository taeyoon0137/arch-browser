// Each tab wraps an engine web contents instance. It publishes the state shown in the sidebar and command bar.
import AppKit
import ARCHEngine
import Combine
import Foundation
import History

public final class Tab: ObservableObject, Identifiable {
    public let id = UUID()
    public let webContents: any EngineWebContents
    @Published public var spaceID: UUID
    @Published public var isPinned: Bool
    /// The session updates this when the tab is selected. Archiving closes unpinned tabs whose date is too old.
    var lastActivatedAt = Date()
    @Published public private(set) var title: String
    @Published public private(set) var url: URL?
    @Published public private(set) var isLoading: Bool
    @Published public private(set) var canGoBack: Bool
    @Published public private(set) var canGoForward: Bool
    @Published public private(set) var favicon: NSImage?
    /// The session sets this callback so popups from this tab open as new tabs.
    var openNewTab: ((any EngineWebContents) -> Void)?
    /// The session sets this callback to remove the tab when its page closes itself with `window.close()`.
    var didClose: (() -> Void)?
    /// The last page recorded in history, so a page counts once per navigation. Restored tabs start with their saved page here.
    var recordedURL: URL?

    init(webContents: any EngineWebContents, spaceID: UUID, isPinned: Bool) {
        self.webContents = webContents
        self.spaceID = spaceID
        self.isPinned = isPinned
        self.title = webContents.title
        self.url = webContents.url
        self.isLoading = webContents.isLoading
        self.canGoBack = webContents.canGoBack
        self.canGoForward = webContents.canGoForward
        self.favicon = webContents.favicon
        webContents.uiDelegate = self
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host ?? "New Tab"
    }
}

extension Tab: EngineWebContentsUIDelegate {
    public func webContentsDidChangeTitle(_ webContents: any EngineWebContents) { title = webContents.title }
    public func webContentsDidChangeURL(_ webContents: any EngineWebContents) { url = webContents.url }
    public func webContentsDidChangeFavicon(_ webContents: any EngineWebContents) { favicon = webContents.favicon }
    public func webContentsDidClose(_ webContents: any EngineWebContents) { didClose?() }
    public func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) {
        isLoading = webContents.isLoading
        canGoBack = webContents.canGoBack
        canGoForward = webContents.canGoForward
        // A web page is recorded when its load finishes, when the title is usually known.
        if !isLoading, let url = webContents.url, url != recordedURL, url.scheme == "http" || url.scheme == "https" {
            recordedURL = url
            HistoryStore.shared.record(url, title: webContents.title)
        }
    }
    public func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {
        openNewTab?(newWebContents)
    }
}
