// Bridges WKNavigationDelegate, WKUIDelegate, and KVO into ARCHEngine delegate and observer calls.
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
            webView.observe(\.title) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeTitle($0) } },
            webView.observe(\.url) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeURL($0) } },
            webView.observe(\.isLoading) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeLoadingState($0) } },
            webView.observe(\.estimatedProgress) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeLoadingState($0) } },
            webView.observe(\.themeColor) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeThemeColor($0) } },
        ]
    }

    private func navigation(_ navigation: WKNavigation?) -> EngineNavigation {
        EngineNavigation(url: owner.webView.url ?? URL(string: "about:blank")!)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // A link marked for download starts one instead of a navigation once the page policy allows it.
        let allowed: WKNavigationActionPolicy = navigationAction.shouldPerformDownload ? (owner.allowsDownloads ? .download : .cancel) : .allow
        guard let url = navigationAction.request.url, let delegate = owner.navigationDelegate else {
            decisionHandler(allowed)
            return
        }
        let disposition: EngineNavigationDisposition = navigationAction.targetFrame == nil ? .newForegroundTab : .currentTab
        let action = EngineNavigationAction(url: url, disposition: disposition,
                                            isUserInitiated: navigationAction.navigationType == .linkActivated,
                                            referrer: (navigationAction.value(forKey: "sourceFrame") as? WKFrameInfo)?.request.url)
        decisionHandler(delegate.webContents(owner, decidePolicyFor: action) == .allow ? allowed : .cancel)
    }

    /// A response WebKit cannot render, or one served as an attachment, becomes a download.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        guard navigationResponse.canShowMIMEType, !disposition.lowercased().hasPrefix("attachment") else {
            return decisionHandler(owner.allowsDownloads ? .download : .cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        owner.context.webKitDownloads.add(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        owner.context.webKitDownloads.add(download, from: webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner.observers.forEach { $0.webContents(owner, didStartProvisionalNavigation: self.navigation(navigation)) }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        owner.observers.forEach { $0.webContents(owner, didReceiveServerRedirect: self.navigation(navigation)) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        owner.observers.forEach { $0.webContents(owner, didCommit: self.navigation(navigation)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner.observers.forEach { $0.webContents(owner, didFinish: self.navigation(navigation)) }
        owner.refreshFavicon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner.observers.forEach { $0.webContents(owner, didFail: self.navigation(navigation), error: error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner.observers.forEach { $0.webContents(owner, didFail: self.navigation(navigation), error: error) }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic
                || challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest,
              let delegate = owner.uiDelegate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        delegate.webContents(owner, didReceiveAuthenticationChallenge: challenge) { credential in
            completionHandler(credential == nil ? .cancelAuthenticationChallenge : .useCredential, credential)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner.uiDelegate?.webContentsProcessDidTerminate(owner)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let delegate = owner.uiDelegate else { return nil }
        let child = WebKitWebContents(sessionID: UUID().uuidString, parentConfiguration: configuration, context: owner.context)
        delegate.webContents(owner, didCreateNewWebContents: child, targetURL: navigationAction.request.url, disposition: .newForegroundTab)
        return child.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner.uiDelegate?.webContentsDidClose(owner)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let delegate = owner.uiDelegate else { return completionHandler() }
        delegate.webContents(owner, runJavaScriptAlert: message, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let delegate = owner.uiDelegate else { return completionHandler(false) }
        delegate.webContents(owner, runJavaScriptConfirm: message, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let delegate = owner.uiDelegate else { return completionHandler(nil) }
        delegate.webContents(owner, runJavaScriptPrompt: prompt, defaultText: defaultText, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let delegate = owner.uiDelegate else { return decisionHandler(.prompt) }
        let types: [EnginePermissionType] = type == .camera ? [.camera] : type == .microphone ? [.microphone] : [.camera, .microphone]
        let request = EnginePermissionRequest(origin: URL(string: "\(origin.protocol)://\(origin.host)") ?? URL(string: "about:blank")!, types: types)
        delegate.webContents(owner, requestPermission: request) { decisionHandler($0 ? .grant : .deny) }
    }
}
