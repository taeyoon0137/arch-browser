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
    /// Set when the page's process quit and nothing has loaded since. The window covers such a page with a notice and a Reload button.
    @Published public private(set) var hasCrashed = false
    /// How many times this tab's page process quit, kept for the tab close log (III.8).
    public private(set) var crashCount = 0
    /// The session sets this callback so popups from this tab open as new tabs.
    var openNewTab: ((any EngineWebContents) -> Void)?
    /// The session sets this callback to remove the tab when its page closes itself with `window.close()`.
    var didClose: (() -> Void)?
    /// The session sets this callback to ask the user before a site gets a permission. Without it every request is denied.
    var requestPermission: ((EnginePermissionRequest, @escaping (Bool) -> Void) -> Void)?
    /// The session sets this callback to show a page's dialog as a sheet, which waits until the tab is selected. Without it the handler receives `.cancel` and the page gets the dialog's safe answer.
    var presentAlert: ((NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    /// The last page recorded in history, so it counts only once until the tab moves to another page. Restored tabs use their saved page as the initial value.
    var recordedURL: URL?
    /// The session sets this for tabs it restores from the saved session.
    var isRestored = false
    /// The session sets this callback to learn that the tab only ever pointed at a file. The argument tells whether the file downloads; the session removes the tab without a closed-list entry.
    var didOpenOnlyDownload: ((Bool) -> Void)?
    /// Set when the tab turned out to point at a file, so the file's address does not enter history.
    private var isDownloadOnly = false

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

    /// The engine that renders the tab.
    public var engineKind: EngineKind { webContents.engineKind }

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
        // The Chromium engine reloads a page once after its first crash; any new load clears the notice.
        if isLoading { hasCrashed = false }
        canGoBack = webContents.canGoBack
        canGoForward = webContents.canGoForward
        // Record a page when it finishes loading, when its title is usually known.
        if !isLoading, !isDownloadOnly, let url = webContents.url, url != recordedURL, url.scheme == "http" || url.scheme == "https" {
            recordedURL = url
            HistoryStore.shared.record(url, title: webContents.title)
        }
    }
    public func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {
        openNewTab?(newWebContents)
    }
    public func webContents(_ webContents: any EngineWebContents, requestPermission request: EnginePermissionRequest, completion: @escaping (Bool) -> Void) {
        guard let requestPermission else { return completion(false) }
        requestPermission(request, completion)
    }

    /// A tab that opened straight onto a file closes once its download starts. A restored tab like that does not fetch the file again.
    public func webContents(_ webContents: any EngineWebContents, shouldDownload url: URL, hasPage: Bool) -> Bool {
        guard !hasPage else { return true }
        isDownloadOnly = true
        didOpenOnlyDownload?(!isRestored)
        return !isRestored
    }

    public func webContentsProcessDidTerminate(_ webContents: any EngineWebContents) {
        crashCount += 1
        hasCrashed = true
    }

    /// Loads the crashed page's address again, which starts a new page process.
    public func reloadAfterCrash() {
        guard let url else { return webContents.navigationController.reload() }
        webContents.navigationController.load(URLRequest(url: url))
    }

    // MARK: JavaScript dialogs

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptAlert message: String, completion: @escaping () -> Void) {
        let alert = pageAlert(message)
        alert.addButton(withTitle: "OK")
        showAlert(alert) { _ in completion() }
    }

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void) {
        let alert = pageAlert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        showAlert(alert) { completion($0 == .alertFirstButtonReturn) }
    }

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptPrompt message: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        let alert = pageAlert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        showAlert(alert) { completion($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Asks before the page is left. A page cannot choose this sheet's text, so the message is ignored, as in other browsers.
    public func webContents(_ webContents: any EngineWebContents, runBeforeUnloadPanel message: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Leave this page?"
        alert.informativeText = "Changes you made may not be saved."
        alert.addButton(withTitle: "Leave")
        alert.addButton(withTitle: "Stay")
        showAlert(alert) { completion($0 != .alertSecondButtonReturn) }
    }

    /// Names the site in the title so that a page cannot pass its dialog off as one from the app.
    private func pageAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = url?.host.map { "\u{201C}\($0)\u{201D} says" } ?? "This page says"
        alert.informativeText = message
        return alert
    }

    private func showAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let presentAlert else { return completion(.cancel) }
        presentAlert(alert, completion)
    }
}
