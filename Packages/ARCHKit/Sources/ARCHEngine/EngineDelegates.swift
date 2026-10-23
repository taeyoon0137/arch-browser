import AppKit
import Foundation

public enum EngineNavigationDisposition: String, Codable, Sendable {
    case currentTab
    case newForegroundTab
    case newBackgroundTab
    case newWindow
    case newPopup
}

public struct EngineNavigationAction: Sendable {
    public var url: URL
    public var disposition: EngineNavigationDisposition
    public var isUserInitiated: Bool
    public var referrer: URL?
    public init(url: URL, disposition: EngineNavigationDisposition, isUserInitiated: Bool, referrer: URL? = nil) {
        self.url = url
        self.disposition = disposition
        self.isUserInitiated = isUserInitiated
        self.referrer = referrer
    }
}

public enum EngineNavigationPolicy: Sendable {
    case allow
    case cancel
}

public struct EngineNavigation: Sendable {
    public var url: URL
    public var responseStatusCode: Int?
    public var responseHeaders: [String: String]
    public init(url: URL, responseStatusCode: Int? = nil, responseHeaders: [String: String] = [:]) {
        self.url = url
        self.responseStatusCode = responseStatusCode
        self.responseHeaders = responseHeaders
    }
}

public enum EnginePermissionType: String, Codable, Sendable {
    case camera
    case microphone
    case geolocation
    case notifications
    case clipboard
    case midi
    case screenCapture
}

public struct EnginePermissionRequest: Sendable {
    public var origin: URL
    public var types: [EnginePermissionType]
    public init(origin: URL, types: [EnginePermissionType]) {
        self.origin = origin
        self.types = types
    }
}

public struct EngineContextMenuElement: Sendable {
    public var linkURL: URL?
    public var imageURL: URL?
    public var mediaURL: URL?
    public var selectedText: String?
    public var isEditable: Bool
    public init(linkURL: URL? = nil, imageURL: URL? = nil, mediaURL: URL? = nil, selectedText: String? = nil, isEditable: Bool = false) {
        self.linkURL = linkURL
        self.imageURL = imageURL
        self.mediaURL = mediaURL
        self.selectedText = selectedText
        self.isEditable = isEditable
    }
}

public protocol EngineWebContentsNavigationDelegate: AnyObject {
    func webContents(_ webContents: any EngineWebContents, decidePolicyFor action: EngineNavigationAction) -> EngineNavigationPolicy
}

public protocol EngineWebContentsNavigationObserver: AnyObject {
    func webContents(_ webContents: any EngineWebContents, didStartProvisionalNavigation navigation: EngineNavigation)
    func webContents(_ webContents: any EngineWebContents, didReceiveServerRedirect navigation: EngineNavigation)
    func webContents(_ webContents: any EngineWebContents, didCommit navigation: EngineNavigation)
    func webContents(_ webContents: any EngineWebContents, didFinish navigation: EngineNavigation)
    func webContents(_ webContents: any EngineWebContents, didFail navigation: EngineNavigation, error: Error)
    func webContents(_ webContents: any EngineWebContents, didFinishInPageNavigation navigation: EngineNavigation)
}

/// A lightweight user interface (UI) delegate. It excludes callbacks for autofill, translation bubbles, and vendor integrations.
public protocol EngineWebContentsUIDelegate: AnyObject {
    func webContentsDidChangeTitle(_ webContents: any EngineWebContents)
    func webContentsDidChangeURL(_ webContents: any EngineWebContents)
    func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents)
    func webContentsDidChangeFavicon(_ webContents: any EngineWebContents)
    func webContentsDidChangeThemeColor(_ webContents: any EngineWebContents)
    func webContents(_ webContents: any EngineWebContents, didChangeStatusText text: String?)
    func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition)
    func webContentsDidClose(_ webContents: any EngineWebContents)
    func webContentsDidRequestActivation(_ webContents: any EngineWebContents)
    func webContentsDidRequestEnterFullscreen(_ webContents: any EngineWebContents)
    func webContentsDidRequestExitFullscreen(_ webContents: any EngineWebContents)
    func webContents(_ webContents: any EngineWebContents, runJavaScriptAlert message: String, completion: @escaping () -> Void)
    func webContents(_ webContents: any EngineWebContents, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void)
    func webContents(_ webContents: any EngineWebContents, runJavaScriptPrompt message: String, defaultText: String?, completion: @escaping (String?) -> Void)
    func webContents(_ webContents: any EngineWebContents, runBeforeUnloadPanel message: String, completion: @escaping (Bool) -> Void)
    /// The page's open dialogs no longer apply, as after a navigation.
    func webContentsDidCancelDialogs(_ webContents: any EngineWebContents)
    func webContents(_ webContents: any EngineWebContents, requestPermission request: EnginePermissionRequest, completion: @escaping (Bool) -> Void)
    /// Asks whether a download that `url` starts may proceed. `hasPage` is false when the web contents never showed a page, as when a tab opens straight onto a file.
    func webContents(_ webContents: any EngineWebContents, shouldDownload url: URL, hasPage: Bool) -> Bool
    func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu)
    func webContents(_ webContents: any EngineWebContents, canNavigateExternallyTo url: URL) -> Bool
    func webContents(_ webContents: any EngineWebContents, showExternalProtocolDialogFor url: URL, completion: @escaping (Bool) -> Void)
    /// Offers a link that belongs to another app. The engines call this instead of loading a scheme they do not handle. `isUserInitiated` is true when the user clicked the link.
    func webContents(_ webContents: any EngineWebContents, openExternally url: URL, isUserInitiated: Bool)
    func webContents(_ webContents: any EngineWebContents, didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge, completion: @escaping (URLCredential?) -> Void)
    func webContents(_ webContents: any EngineWebContents, didChangeAudibleState isAudible: Bool)
    func webContents(_ webContents: any EngineWebContents, didChangeMuteState isMuted: Bool)
    func webContents(_ webContents: any EngineWebContents, blockedPopupCountDidChange count: Int)
    func webContentsProcessDidTerminate(_ webContents: any EngineWebContents)
    func webContents(_ webContents: any EngineWebContents, didConsumeKeyEvent event: NSEvent) -> Bool
}

// Default implementations let feature code override only the callbacks it handles. Dialogs and permissions default to the safe answer.
public extension EngineWebContentsUIDelegate {
    func webContentsDidChangeTitle(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeURL(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeFavicon(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeThemeColor(_ webContents: any EngineWebContents) {}
    func webContents(_ webContents: any EngineWebContents, didChangeStatusText text: String?) {}
    func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {}
    func webContentsDidClose(_ webContents: any EngineWebContents) {}
    func webContentsDidRequestActivation(_ webContents: any EngineWebContents) {}
    func webContentsDidRequestEnterFullscreen(_ webContents: any EngineWebContents) {}
    func webContentsDidRequestExitFullscreen(_ webContents: any EngineWebContents) {}
    func webContents(_ webContents: any EngineWebContents, runJavaScriptAlert message: String, completion: @escaping () -> Void) { completion() }
    func webContents(_ webContents: any EngineWebContents, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func webContents(_ webContents: any EngineWebContents, runJavaScriptPrompt message: String, defaultText: String?, completion: @escaping (String?) -> Void) { completion(nil) }
    func webContents(_ webContents: any EngineWebContents, runBeforeUnloadPanel message: String, completion: @escaping (Bool) -> Void) { completion(true) }
    func webContentsDidCancelDialogs(_ webContents: any EngineWebContents) {}
    func webContents(_ webContents: any EngineWebContents, requestPermission request: EnginePermissionRequest, completion: @escaping (Bool) -> Void) { completion(false) }
    func webContents(_ webContents: any EngineWebContents, shouldDownload url: URL, hasPage: Bool) -> Bool { true }
    func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {}
    func webContents(_ webContents: any EngineWebContents, canNavigateExternallyTo url: URL) -> Bool { false }
    func webContents(_ webContents: any EngineWebContents, showExternalProtocolDialogFor url: URL, completion: @escaping (Bool) -> Void) { completion(false) }
    func webContents(_ webContents: any EngineWebContents, didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge, completion: @escaping (URLCredential?) -> Void) { completion(nil) }
    func webContents(_ webContents: any EngineWebContents, didChangeAudibleState isAudible: Bool) {}
    func webContents(_ webContents: any EngineWebContents, didChangeMuteState isMuted: Bool) {}
    func webContents(_ webContents: any EngineWebContents, blockedPopupCountDidChange count: Int) {}
    func webContentsProcessDidTerminate(_ webContents: any EngineWebContents) {}
    func webContents(_ webContents: any EngineWebContents, didConsumeKeyEvent event: NSEvent) -> Bool { false }
}

/// Schemes both engines load. A link with any other scheme, such as `mailto:`, belongs to another app.
public enum EngineURLSchemes {
    public static let web: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript"]
}

public extension EngineWebContentsUIDelegate {
    func webContents(_ webContents: any EngineWebContents, openExternally url: URL, isUserInitiated: Bool) {
        guard self.webContents(webContents, canNavigateExternallyTo: url) else { return }
        self.webContents(webContents, showExternalProtocolDialogFor: url) { _ in }
    }
}
