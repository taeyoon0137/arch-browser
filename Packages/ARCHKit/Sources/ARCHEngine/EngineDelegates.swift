import AppKit
import Foundation

public enum EngineNavigationDisposition: String, Codable, Sendable {
    case currentTab
    case newForegroundTab
    case newBackgroundTab
    /// Where browsers open a link the user clicked with Shift. Both engines report such a link to the navigation delegate with this disposition.
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

/// Identifiers an engine gives the context menu items it runs itself.
public enum EngineContextMenuItem {
    /// A replacement for the misspelled word. Its title is the replacement, so it keeps its title.
    public static let spellingSuggestion = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.spellingSuggestion")
    public static let noSpellingSuggestions = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.noSpellingSuggestions")
    public static let cut = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.cut")
    public static let copy = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.copy")
    public static let paste = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.paste")
    public static let selectAll = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.selectAll")
}

public struct EngineContextMenuElement: Sendable {
    public var linkURL: URL?
    public var imageURL: URL?
    public var mediaURL: URL?
    public var selectedText: String?
    public var isEditable: Bool
    /// Whether the menu opened in the page's main frame, not in a frame inside the page, which can show another site. False when the engine could not tell.
    public var isInMainFrame: Bool
    public init(linkURL: URL? = nil, imageURL: URL? = nil, mediaURL: URL? = nil, selectedText: String? = nil, isEditable: Bool = false, isInMainFrame: Bool = false) {
        self.linkURL = linkURL
        self.imageURL = imageURL
        self.mediaURL = mediaURL
        self.selectedText = selectedText
        self.isEditable = isEditable
        self.isInMainFrame = isInMainFrame
    }
}

/// Decides whether a navigation goes ahead. The WebKit engine asks about every navigation; the Chromium engine asks only about links the user clicked with Shift (`newWindow`).
public protocol EngineWebContentsNavigationDelegate: AnyObject {
    func webContents(_ webContents: any EngineWebContents, decidePolicyFor action: EngineNavigationAction) -> EngineNavigationPolicy
}

/// A lightweight user interface (UI) delegate. It excludes callbacks for autofill, translation bubbles, and vendor integrations.
public protocol EngineWebContentsUIDelegate: AnyObject {
    func webContentsDidChangeTitle(_ webContents: any EngineWebContents)
    func webContentsDidChangeURL(_ webContents: any EngineWebContents)
    func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents)
    /// The main frame finished loading a document, whose frames may still be loading. Navigations within the document report nothing.
    func webContentsDidFinishLoadingDocument(_ webContents: any EngineWebContents)
    func webContentsDidChangeFavicon(_ webContents: any EngineWebContents)
    func webContentsDidChangeThemeColor(_ webContents: any EngineWebContents)
    /// `isAudible` changed.
    func webContentsDidChangeAudibleState(_ webContents: any EngineWebContents)
    func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition)
    func webContentsDidClose(_ webContents: any EngineWebContents)
    /// The page asks to be shown, with its tab, its window, and the app in front, as the return button of its picture-in-picture window does.
    func webContentsDidRequestActivation(_ webContents: any EngineWebContents)
    /// The page entered fullscreen, as through the Fullscreen API, and asks the app to fill the window with it. Only an engine that leaves the window's transition to the app sends this, as Chromium does; WebKit moves the element into a full-screen window of its own and sends nothing.
    func webContentsDidRequestEnterFullscreen(_ webContents: any EngineWebContents)
    /// The page left the fullscreen that `webContentsDidRequestEnterFullscreen` reported. Only Chromium sends this.
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
    /// Builds the page's context menu. On entry `menu` holds only the spelling and editing items the engine runs itself, marked with `EngineContextMenuItem` identifiers, and they carry their enabled state. The delegate may retitle, reorder, or remove them, except that a spelling suggestion keeps its title, and sets `isEnabled` on every item it adds. The engine shows the menu after this returns, unless it is empty.
    func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu)
    /// Offers a link that belongs to another app. The engines call this instead of loading a scheme they do not handle. `isUserInitiated` is true when the user clicked the link.
    func webContents(_ webContents: any EngineWebContents, openExternally url: URL, isUserInitiated: Bool)
    func webContents(_ webContents: any EngineWebContents, didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge, completion: @escaping (URLCredential?) -> Void)
    func webContentsProcessDidTerminate(_ webContents: any EngineWebContents)
}

// Default implementations let feature code override only the callbacks it handles. Dialogs and permissions default to the safe answer, and a link for another app stays unopened.
public extension EngineWebContentsUIDelegate {
    func webContentsDidChangeTitle(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeURL(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) {}
    func webContentsDidFinishLoadingDocument(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeFavicon(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeThemeColor(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeAudibleState(_ webContents: any EngineWebContents) {}
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
    func webContents(_ webContents: any EngineWebContents, openExternally url: URL, isUserInitiated: Bool) {}
    func webContents(_ webContents: any EngineWebContents, didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge, completion: @escaping (URLCredential?) -> Void) { completion(nil) }
    func webContentsProcessDidTerminate(_ webContents: any EngineWebContents) {}
}

/// Schemes both engines load. A link with any other scheme, such as `mailto:`, belongs to another app.
public enum EngineURLSchemes {
    public static let web: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript"]
}

public extension URL {
    /// Parses an address an engine reported. Browsers serialize addresses with characters such as `|` left unescaped, which `URL(string:)` rejects before macOS 14, so in that case the bytes are taken as they are.
    init?(engineString string: String) {
        if let url = URL(string: string) {
            self = url
        } else if let url = URL(dataRepresentation: Data(string.utf8), relativeTo: nil, isAbsolute: true) {
            self = url
        } else {
            return nil
        }
    }
}
