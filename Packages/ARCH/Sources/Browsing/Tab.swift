// Each tab wraps an engine web contents instance. It publishes the state shown in the sidebar and command bar.
import AppKit
import ARCHEngine
import Combine
import Foundation
import History

public final class Tab: ObservableObject, Identifiable {
    public let id = UUID()
    /// Replaced when the tab switches engines.
    @Published public private(set) var webContents: any EngineWebContents
    @Published public var spaceID: UUID
    @Published public var isPinned: Bool
    /// The session updates this on tab selection. Archiving closes unpinned tabs whose dates are too old.
    var lastActivatedAt = Date()
    @Published public private(set) var title: String
    /// The name the user gave the tab, shown in place of the page's title. The session sets it.
    @Published public internal(set) var customTitle: String?
    @Published public private(set) var url: URL?
    @Published public private(set) var isLoading: Bool
    @Published public private(set) var canGoBack: Bool
    @Published public private(set) var canGoForward: Bool
    @Published public private(set) var favicon: NSImage?
    /// Whether the page plays sound, for a speaker badge on its row.
    @Published public private(set) var isAudible = false
    /// Set for a tab that a page opened behind the selected tab, until the user selects it, for a dot on its row. The session sets and clears it.
    @Published public internal(set) var isUnread = false
    /// Set when the page's process quit and nothing has loaded since. The window covers such a page with a notice and a Reload button.
    @Published public private(set) var hasCrashed = false
    /// How many times this tab's page process quit, kept for the tab close log (III.8).
    public private(set) var crashCount = 0
    /// The session sets this callback so popups from this tab open as new tabs.
    var openNewTab: ((any EngineWebContents) -> Void)?
    /// Removes the tab when its page closes itself with `window.close()`. Set by the session.
    var didClose: (() -> Void)?
    /// The session sets this callback to learn that a page finished loading.
    var didFinishLoad: (() -> Void)?
    /// The session sets this callback to close the sheets of a page whose dialogs no longer apply.
    var didCancelDialogs: (() -> Void)?
    /// The session sets this callback to bring the tab forward, so that a sheet it needs can show.
    var requestSelection: (() -> Void)?
    /// The session sets this callback to ask the user before a site gets a permission. Without it every request is denied.
    var requestPermission: ((EnginePermissionRequest, @escaping (Bool) -> Void) -> Void)?
    /// The session sets this callback to show a sheet for the page, which waits until the tab is selected. The flag marks the page's own `alert`, `confirm`, and `prompt`, which the engine can cancel. Without the callback the handler receives `.cancel` and the page gets the safe answer.
    var presentAlert: ((NSAlert, Bool, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    /// The session sets this callback to open an address from the page's context menu in a background tab.
    var openURLInNewTab: ((URL) -> Void)?
    /// The session sets this callback to fill the window with the page while it is in fullscreen. Only engines that leave the transition to the app report it.
    var didChangeFullscreen: ((Bool) -> Void)?
    /// Set while a sheet asks to open a link in another app, so that a page cannot queue more of them.
    private var isOfferingExternalApp = false
    /// The site whose own request to open another app the user declined: its host, or its scheme for a page without one, such as a file. The page asks no more until the tab moves to another site, so changing its own address or reloading does not bring the question back. A link the user clicks or an address the user types still asks.
    private var declinedExternalAppSite: String?
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

    public var displayTitle: String { customTitle ?? pageTitle }

    /// The page's title, or its host if it has no title.
    public var pageTitle: String {
        if !title.isEmpty { return title }
        return url?.host ?? "New Tab"
    }
}

extension Tab: EngineWebContentsUIDelegate {
    public func webContentsDidChangeTitle(_ webContents: any EngineWebContents) { title = webContents.title }
    public func webContentsDidChangeURL(_ webContents: any EngineWebContents) {
        url = webContents.url
        if Self.site(of: url) != declinedExternalAppSite { declinedExternalAppSite = nil }
    }
    public func webContentsDidChangeFavicon(_ webContents: any EngineWebContents) { favicon = webContents.favicon }
    public func webContentsDidChangeAudibleState(_ webContents: any EngineWebContents) { isAudible = webContents.isAudible }
    public func webContentsDidClose(_ webContents: any EngineWebContents) { didClose?() }
    public func webContentsDidRequestEnterFullscreen(_ webContents: any EngineWebContents) { didChangeFullscreen?(true) }
    public func webContentsDidRequestExitFullscreen(_ webContents: any EngineWebContents) { didChangeFullscreen?(false) }
    public func webContentsDidChangeLoadingState(_ webContents: any EngineWebContents) {
        isLoading = webContents.isLoading
        // The Chromium engine reloads a page once after its first crash; any new load clears the notice.
        if isLoading { hasCrashed = false }
        canGoBack = webContents.canGoBack
        canGoForward = webContents.canGoForward
        if !isLoading { didFinishLoad?() }
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

    /// Swaps in a web contents from another engine. The old one stops reporting to the tab before the session closes it, and the tab keeps its title, address, and icon until the new page reports its own.
    func replaceWebContents(with replacement: any EngineWebContents) {
        webContents.uiDelegate = nil
        webContents = replacement
        replacement.uiDelegate = self
        isLoading = replacement.isLoading
        canGoBack = replacement.canGoBack
        canGoForward = replacement.canGoForward
        isAudible = replacement.isAudible
        hasCrashed = false
        isDownloadOnly = false
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
        showAlert(alert, isPageDialog: true) { _ in completion() }
    }

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptConfirm message: String, completion: @escaping (Bool) -> Void) {
        let alert = pageAlert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        showAlert(alert, isPageDialog: true) { completion($0 == .alertFirstButtonReturn) }
    }

    public func webContents(_ webContents: any EngineWebContents, runJavaScriptPrompt message: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        let alert = pageAlert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        showAlert(alert, isPageDialog: true) { completion($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Asks before the page is left. A page cannot choose this sheet's text, so the message is ignored, as in other browsers. Closing a background tab brings it forward so the question can show.
    public func webContents(_ webContents: any EngineWebContents, runBeforeUnloadPanel message: String, completion: @escaping (Bool) -> Void) {
        requestSelection?()
        let alert = NSAlert()
        alert.messageText = "Leave this page?"
        alert.informativeText = "Changes you made may not be saved."
        alert.addButton(withTitle: "Leave")
        alert.addButton(withTitle: "Stay")
        showAlert(alert) { completion($0 != .alertSecondButtonReturn) }
    }

    public func webContentsDidCancelDialogs(_ webContents: any EngineWebContents) {
        didCancelDialogs?()
    }

    // MARK: Context menus

    /// Builds the same menu on both engines: spelling suggestions, then the link, the image, and editing or Copy, separated by lines. Back, Forward, and Reload show only when none of those apply. The engine's own items keep their actions and enabled state.
    public func webContents(_ webContents: any EngineWebContents, willShowContextMenuFor element: EngineContextMenuElement, menu: NSMenu) {
        let engineItems = menu.items
        menu.removeAllItems()
        menu.autoenablesItems = false
        func engineItem(_ identifier: NSUserInterfaceItemIdentifier, _ title: String) -> NSMenuItem? {
            guard let item = engineItems.first(where: { $0.identifier == identifier }) else { return nil }
            item.title = title
            return item
        }
        var sections: [[NSMenuItem]] = []
        let suggestions = engineItems.filter { $0.identifier == EngineContextMenuItem.spellingSuggestion }
        if !suggestions.isEmpty {
            sections.append(Array(suggestions.prefix(5)))
        } else if let noGuesses = engineItem(EngineContextMenuItem.noSpellingSuggestions, "No Guesses Found") {
            noGuesses.isEnabled = false
            sections.append([noGuesses])
        }
        if let link = element.linkURL {
            sections.append([newTabItem("Open Link in New Tab", for: link), ActionMenuItem("Copy Link") { Self.copyToPasteboard(link) }].compactMap { $0 })
        }
        if let image = element.imageURL {
            sections.append([newTabItem("Open Image in New Tab", for: image), ActionMenuItem("Copy Image Address") { Self.copyToPasteboard(image) }].compactMap { $0 })
        }
        if element.isEditable {
            sections.append([engineItem(EngineContextMenuItem.cut, "Cut"), engineItem(EngineContextMenuItem.copy, "Copy"),
                             engineItem(EngineContextMenuItem.paste, "Paste"), engineItem(EngineContextMenuItem.selectAll, "Select All")].compactMap { $0 })
        } else if element.linkURL == nil, element.imageURL == nil, element.mediaURL == nil, let copy = engineItem(EngineContextMenuItem.copy, "Copy") {
            // WebKit offers Copy outside fields only when the click is not on a link, image, or media, so Chromium follows it.
            sections.append([copy])
        }
        sections.removeAll { $0.isEmpty }
        if sections.isEmpty {
            sections.append([
                ActionMenuItem("Back", isEnabled: webContents.canGoBack) { [weak webContents] in webContents?.navigationController.goBack() },
                ActionMenuItem("Forward", isEnabled: webContents.canGoForward) { [weak webContents] in webContents?.navigationController.goForward() },
                ActionMenuItem("Reload") { [weak webContents] in webContents?.navigationController.reload() },
            ])
        }
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
    }

    /// Only web addresses open in a tab; a link for another app offers just Copy Link.
    private func newTabItem(_ title: String, for url: URL) -> NSMenuItem? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return ActionMenuItem(title) { [weak self] in self?.openURLInNewTab?(url) }
    }

    private static func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        pasteboard.writeObjects([item])
    }

    // MARK: Links for other apps

    public func webContents(_ webContents: any EngineWebContents, openExternally url: URL, isUserInitiated: Bool) {
        if isUserInitiated { forgetExternalAppDecline() }
        guard self.webContents(webContents, canNavigateExternallyTo: url) else { return }
        self.webContents(webContents, showExternalProtocolDialogFor: url) { _ in }
    }

    /// The user asked for the next page, as by typing its address, so a site's earlier decline no longer applies.
    func forgetExternalAppDecline() {
        declinedExternalAppSite = nil
    }

    private static func site(of url: URL?) -> String? {
        guard let url else { return nil }
        return url.host ?? "\(url.scheme ?? ""):"
    }

    public func webContents(_ webContents: any EngineWebContents, canNavigateExternallyTo url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    /// Asks before a page hands a link to another app, then opens the link there. One question shows at a time, and a site the user said no to asks no more.
    public func webContents(_ webContents: any EngineWebContents, showExternalProtocolDialogFor url: URL, completion: @escaping (Bool) -> Void) {
        guard !isOfferingExternalApp, declinedExternalAppSite == nil || declinedExternalAppSite != Self.site(of: self.url),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return completion(false) }
        isOfferingExternalApp = true
        let appName = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open \u{201C}\(appName)\u{201D}?"
        alert.informativeText = "\(self.url?.host.map { "\u{201C}\($0)\u{201D}" } ?? "This page") wants to open a \(url.scheme ?? "") link in \(appName)."
        alert.icon = NSWorkspace.shared.icon(forFile: appURL.path)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let pageSite = Self.site(of: self.url)
        showAlert(alert) { [weak self] response in
            let opens = response == .alertFirstButtonReturn
            self?.isOfferingExternalApp = false
            if opens {
                NSWorkspace.shared.open(url)
            } else if response == .alertSecondButtonReturn, let self, Self.site(of: self.url) == pageSite {
                // Only the Cancel button counts as an answer; a sheet the app ended, as for an engine switch, does not.
                self.declinedExternalAppSite = pageSite
            }
            completion(opens)
        }
    }

    // MARK: HTTP authentication

    /// Asks for a user name and password for a site or proxy. The credential lasts for this session only and is never saved.
    public func webContents(_ webContents: any EngineWebContents, didReceiveAuthenticationChallenge challenge: URLAuthenticationChallenge, completion: @escaping (URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = space.isProxy() ? "Log In to the Proxy \u{201C}\(space.host)\u{201D}" : "Log In to \u{201C}\(space.host)\u{201D}"
        var details: [String] = []
        if challenge.previousFailureCount > 0 { details.append("The user name or password was incorrect.") }
        if let realm = space.realm, !realm.isEmpty { details.append("The site says: \u{201C}\(realm)\u{201D}") }
        if !space.receivesCredentialSecurely { details.append("Your login information will be sent without encryption.") }
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: "Log In")
        alert.addButton(withTitle: "Cancel")
        let userField = NSTextField(string: challenge.proposedCredential?.user ?? "")
        userField.placeholderString = "User Name"
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "Password"
        let fields = NSStackView(views: [userField, passwordField])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        userField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        passwordField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        alert.accessoryView = fields
        alert.window.initialFirstResponder = userField
        userField.nextKeyView = passwordField
        showAlert(alert) { response in
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            completion(URLCredential(user: userField.stringValue, password: passwordField.stringValue, persistence: .forSession))
        }
    }

    /// Names the site in the title so that a page cannot pass its dialog off as one from the app.
    private func pageAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = url?.host.map { "\u{201C}\($0)\u{201D} says" } ?? "This page says"
        alert.informativeText = message
        return alert
    }

    private func showAlert(_ alert: NSAlert, isPageDialog: Bool = false, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let presentAlert else { return completion(.cancel) }
        presentAlert(alert, isPageDialog, completion)
    }
}

/// A menu item that runs a closure, because a tab is not an Objective-C object that menu actions can target.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
