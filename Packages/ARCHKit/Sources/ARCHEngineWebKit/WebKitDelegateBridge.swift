// Bridges WKNavigationDelegate, WKUIDelegate, and KVO into ARCHEngine delegate calls.
import AppKit
import ARCHEngine
import Foundation
import WebKit

extension WebKitWebContents {
    /// Called right after creation to wire delegates and KVO.
    func installBridge() {
        bridge = WebKitDelegateBridge(owner: self)
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge
    }
}

final class WebKitDelegateBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
    unowned let owner: WebKitWebContents
    private var observations: [NSKeyValueObservation] = []

    init(owner: WebKitWebContents) {
        self.owner = owner
        super.init()
        let webView = owner.webView
        observations = [
            webView.observe(\.title) { [weak owner] _, _ in
                owner?.extensionTabDidChange(.title)
                owner.map { $0.uiDelegate?.webContentsDidChangeTitle($0) }
            },
            webView.observe(\.url) { [weak owner] _, _ in
                owner?.extensionTabDidChange(.url)
                owner.map { $0.uiDelegate?.webContentsDidChangeURL($0) }
            },
            webView.observe(\.isLoading) { [weak owner] _, _ in
                owner?.extensionTabDidChange(.loading)
                owner?.loadingStateDidChange()
            },
            webView.observe(\.estimatedProgress) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeLoadingState($0) } },
        ]
    }

    /// The scheme of web extensions' pages, which WebKit loads besides the web schemes: an options page or another extension page in a tab, and a frame an extension adds to a page. `WebKitExtensions` gives each extension its base URL in it.
    static let extensionScheme = "webkit-extension"

    /// Whether the address belongs to another app: its scheme is neither one both engines load nor WebKit's extension scheme.
    private static func opensExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !EngineURLSchemes.web.contains(scheme) && scheme != extensionScheme
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, Self.opensExternally(url) {
            decisionHandler(.cancel)
            owner.uiDelegate?.webContents(owner, openExternally: url, isUserInitiated: navigationAction.navigationType == .linkActivated)
            return
        }
        // Downloads a link marked for download instead of navigating, if the page policy allows it.
        let allowed: WKNavigationActionPolicy = navigationAction.shouldPerformDownload ? (mayDownload(navigationAction.request.url, in: webView) ? .download : .cancel) : .allow
        var policy = allowed
        if let url = navigationAction.request.url, let delegate = owner.navigationDelegate {
            let action = EngineNavigationAction(url: url, disposition: Self.disposition(of: navigationAction),
                                                isUserInitiated: navigationAction.navigationType == .linkActivated)
            if delegate.webContents(owner, decidePolicyFor: action) != .allow { policy = .cancel }
        }
        guard policy == .allow, navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else { return decisionHandler(policy) }
        let isAppLoad = owner.appLoadURL == url.absoluteURL
        if isAppLoad { owner.appLoadURL = nil }
        // WebKit loads a web extension's pages only in a web view made for that extension and no other page there, so a main frame navigation across that line loads in a replacement: one out to a web page from a link, a script, or the address field, and one into an extension's page that the app starts, as the address field and `tabs.update` do, or that a frame may start (`mayStartReplacement`). Any other navigation into an extension's pages, as a web page's link, script, redirect, or new window, loads nothing, as on Chromium. Any other navigation that goes ahead here ends a wait for an extension.
        if owner.needsReplacement(toLoad: url) {
            decisionHandler(.cancel)
            if isAppLoad || owner.mayStartReplacement(toLoad: url, from: Self.sourceOrigin(of: navigationAction)) { owner.scheduleReplacement(loading: url) }
            return
        }
        owner.stopWaitingForExtension()
        decisionHandler(policy)
    }

    /// A link clicked with Shift and without Command asks for a new window, as Chromium reads the click, so both engines report it alike. A link marked for download is not one. Other navigations open in place or, without a target frame, in a new tab.
    private static func disposition(of navigationAction: WKNavigationAction) -> EngineNavigationDisposition {
        let modifiers = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated, !navigationAction.shouldPerformDownload, modifiers.contains(.shift), !modifiers.contains(.command) {
            return .newWindow
        }
        return navigationAction.targetFrame == nil ? .newForegroundTab : .currentTab
    }

    /// The origin of the frame that started a navigation, as an address with an empty path, or nil when the origin is opaque or unknown, which leaves its protocol empty.
    private static func sourceOrigin(of navigationAction: WKNavigationAction) -> URL? {
        let origin = navigationAction.sourceFrame.securityOrigin
        guard !origin.protocol.isEmpty else { return nil }
        let port = origin.port == 0 ? "" : ":\(origin.port)"
        return URL(string: "\(origin.protocol)://\(origin.host)\(port)/")
    }

    /// Downloads responses WebKit cannot render or that are served as attachments.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        guard navigationResponse.canShowMIMEType, !disposition.lowercased().hasPrefix("attachment") else {
            return decisionHandler(mayDownload(navigationResponse.response.url, in: webView) ? .download : .cancel)
        }
        decisionHandler(.allow)
    }

    /// A web view that has not committed a navigation has never shown a page.
    private func mayDownload(_ url: URL?, in webView: WKWebView) -> Bool {
        guard let url, let delegate = owner.uiDelegate else { return true }
        return delegate.webContents(owner, shouldDownload: url, hasPage: webView.backForwardList.currentItem != nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        owner.context.webKitDownloads.add(download, from: owner)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        owner.context.webKitDownloads.add(download, from: owner)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        owner.uiDelegate?.webContents(owner, didCommitDocumentAt: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner.uiDelegate?.webContentsDidFinishLoadingDocument(owner)
        owner.refreshFavicon()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The same methods the Chromium engine asks about with a user name and password.
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM]
                .contains(challenge.protectionSpace.authenticationMethod),
              let delegate = owner.uiDelegate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        delegate.webContents(owner, didReceiveAuthenticationChallenge: challenge) { credential in
            completionHandler(credential == nil ? .cancelAuthenticationChallenge : .useCredential, credential)
        }
    }

    /// The tab stays blank until a reload restarts the process. The application counts the crash.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner.clearAudibleDocuments()
        owner.uiDelegate?.webContentsProcessDidTerminate(owner)
        owner.context.application?.rendererDidCrash()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let delegate = owner.uiDelegate else { return nil }
        // A new window for a link that belongs to another app opens no tab, as on the Chromium engine.
        if let url = navigationAction.request.url, Self.opensExternally(url) {
            delegate.webContents(owner, openExternally: url, isUserInitiated: navigationAction.navigationType == .linkActivated)
            return nil
        }
        // WebKit loads no web page in a web view made for an extension, so a web page that an extension's page opens loads in a web contents of its own, without an opener. A window that a web page opens for an extension's page gets its opener's configuration, and its navigation policy loads the page in a replacement only when the opener may start that navigation (`mayStartReplacement`), as for a page the extension makes web-accessible to the opener's site; otherwise the window stays blank.
        if let url = navigationAction.request.url, owner.extensionBaseURL != nil, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let child = WebKitWebContents(context: owner.context,
                                          configuration: EngineWebContentsConfiguration(initialURL: url, pageScripts: owner.userContent.pageScripts))
            delegate.webContents(owner, didCreateNewWebContents: child, targetURL: url, disposition: .newForegroundTab)
            return nil
        }
        let child = WebKitWebContents(parentConfiguration: configuration, extensionBaseURL: owner.extensionBaseURL, context: owner.context)
        delegate.webContents(owner, didCreateNewWebContents: child, targetURL: navigationAction.request.url, disposition: .newForegroundTab)
        return child.webView
    }


    func webViewDidClose(_ webView: WKWebView) {
        owner.uiDelegate?.webContentsDidClose(owner)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let delegate = owner.uiDelegate, !owner.suppressesDialogs else { return completionHandler() }
        let answer = owner.trackDialog(safeAnswer: ()) { completionHandler() }
        delegate.webContents(owner, runJavaScriptAlert: message) { answer(()) }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let delegate = owner.uiDelegate, !owner.suppressesDialogs else { return completionHandler(false) }
        delegate.webContents(owner, runJavaScriptConfirm: message, completion: owner.trackDialog(safeAnswer: false, completion: completionHandler))
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let delegate = owner.uiDelegate, !owner.suppressesDialogs else { return completionHandler(nil) }
        delegate.webContents(owner, runJavaScriptPrompt: prompt, defaultText: defaultText, completion: owner.trackDialog(safeAnswer: nil, completion: completionHandler))
    }

    /// The UI delegate decides for the site; granting access also requires the system's camera or microphone permission for this app, which is requested before the page gets access. Without a UI delegate the request gets the safe answer, a denial, rather than a prompt of WebKit's own. WebKit handles geolocation through the app's location authorization.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let delegate = owner.uiDelegate else { return decisionHandler(.deny) }
        let types: [EnginePermissionType] = type == .camera ? [.camera] : type == .microphone ? [.microphone] : [.camera, .microphone]
        let mediaTypes = EngineCaptureAccess.mediaTypes(for: types)
        // Skip the site's permission request if the system already denies this app access to the device.
        guard !EngineCaptureAccess.isRefusedBySystem(mediaTypes) else { return decisionHandler(.deny) }
        // Port 0 stands for the scheme's default port; any other port belongs to the origin, as in Chromium's requests.
        let port = origin.port == 0 ? "" : ":\(origin.port)"
        let request = EnginePermissionRequest(origin: URL(string: "\(origin.protocol)://\(origin.host)\(port)") ?? URL(string: "about:blank")!, types: types)
        delegate.webContents(owner, requestPermission: request) { granted in
            guard granted else { return decisionHandler(.deny) }
            EngineCaptureAccess.requestAccess(for: mediaTypes) { decisionHandler($0 ? .grant : .deny) }
        }
    }
}
