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
    public init(url: URL, disposition: EngineNavigationDisposition, isUserInitiated: Bool) {
        self.url = url
        self.disposition = disposition
        self.isUserInitiated = isUserInitiated
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

/// Identifiers of the items an engine hands its UI delegate in the page context menu: the spelling and editing items it runs itself, and macOS's text items, which `EngineTextMenuItems` builds alike for both engines.
public enum EngineContextMenuItem {
    /// A replacement for the misspelled word. Its title is the replacement, so it keeps its title.
    public static let spellingSuggestion = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.spellingSuggestion")
    public static let noSpellingSuggestions = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.noSpellingSuggestions")
    /// Clears the misspelled word's marks where it was clicked.
    public static let ignoreSpelling = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.ignoreSpelling")
    /// Adds the misspelled word to the system's spelling dictionary.
    public static let learnSpelling = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.learnSpelling")
    public static let cut = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.cut")
    public static let copy = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.copy")
    public static let paste = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.paste")
    public static let selectAll = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.selectAll")
    /// Look Up “…”, which shows the selection's definition at the click. Its title quotes the selection, so it keeps its title, as do the other text items.
    public static let lookUp = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.lookUp")
    /// Translate “…”, which shows the system's translation of the selection at the click.
    public static let translate = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.translate")
    /// The Spelling and Grammar submenu of a field.
    public static let spellingAndGrammar = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.spellingAndGrammar")
    /// The Substitutions submenu of a field.
    public static let substitutions = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.substitutions")
    /// The Transformations submenu of a field with a selection.
    public static let transformations = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.transformations")
    /// The Speech submenu, in a field and for a selection outside one.
    public static let speech = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.speech")
    /// Share…, the system's share item for the link, image, media, and selection.
    public static let share = NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.share")
}

public struct EngineContextMenuElement: Sendable {
    public var linkURL: URL?
    public var imageURL: URL?
    public var mediaURL: URL?
    public var selectedText: String?
    public var isEditable: Bool
    /// Whether the menu opened in the page's main frame, not in a frame inside the page, which can show another site. False when the engine could not tell.
    public var isInMainFrame: Bool
    /// Whether the field holds a password, whose text no item may read, speak, search, or share: a password field, one that has been one, as when a page shows its password as text, or one that masks its text with `-webkit-text-security`. WebKit's script finds such a field under the click; Chromium's page view has no text input context in one.
    public var isPasswordField: Bool
    public init(linkURL: URL? = nil, imageURL: URL? = nil, mediaURL: URL? = nil, selectedText: String? = nil, isEditable: Bool = false, isInMainFrame: Bool = false,
                isPasswordField: Bool = false) {
        self.linkURL = linkURL
        self.imageURL = imageURL
        self.mediaURL = mediaURL
        self.selectedText = selectedText
        self.isEditable = isEditable
        self.isInMainFrame = isInMainFrame
        self.isPasswordField = isPasswordField
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
    /// The main frame committed a new document at `url`, which then loads. It can come before `webContentsDidChangeURL` reports `url`. Navigations within the document and loads that fail report nothing.
    func webContents(_ webContents: any EngineWebContents, didCommitDocumentAt url: URL?)
    /// The main frame finished loading a document, whose frames may still be loading. Navigations within the document report nothing.
    func webContentsDidFinishLoadingDocument(_ webContents: any EngineWebContents)
    func webContentsDidChangeFavicon(_ webContents: any EngineWebContents)
    /// `isAudible` changed.
    func webContentsDidChangeAudibleState(_ webContents: any EngineWebContents)
    /// `isCapturingMedia` changed.
    func webContentsDidChangeMediaCapture(_ webContents: any EngineWebContents)
    func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition)
    /// The engine cannot load a main frame navigation in this web contents and made `replacement`, in the same browser context and with the same page scripts, which loads it instead with a back-forward list of its own, as WebKit does for a navigation into or out of a web extension's pages. The delegate puts `replacement` in this web contents' place, hands it to its browser with `takeOwnership(of:)`, and closes this one, which keeps its page until then. Without a delegate, or with one that drops `replacement`, the navigation loads nothing.
    func webContents(_ webContents: any EngineWebContents, didCreateReplacement replacement: any EngineWebContents)
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
    /// Builds the page's context menu. On entry `menu` holds only the spelling and editing items the engine runs itself and macOS's text items that `EngineTextMenuItems` builds alike for both engines, marked with `EngineContextMenuItem` identifiers, and they carry their enabled state. The delegate may retitle, reorder, or remove them, except that a spelling suggestion and a text item keep their titles, and sets `isEnabled` on every item it adds. The engine shows the menu after this returns, unless it is empty, as a context menu for the page, so that AppKit adds its own items, such as AutoFill and Services, which never appear in `menu`.
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
    func webContents(_ webContents: any EngineWebContents, didCommitDocumentAt url: URL?) {}
    func webContentsDidFinishLoadingDocument(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeFavicon(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeAudibleState(_ webContents: any EngineWebContents) {}
    func webContentsDidChangeMediaCapture(_ webContents: any EngineWebContents) {}
    func webContents(_ webContents: any EngineWebContents, didCreateNewWebContents newWebContents: any EngineWebContents, targetURL: URL?, disposition: EngineNavigationDisposition) {}
    func webContents(_ webContents: any EngineWebContents, didCreateReplacement replacement: any EngineWebContents) {}
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
