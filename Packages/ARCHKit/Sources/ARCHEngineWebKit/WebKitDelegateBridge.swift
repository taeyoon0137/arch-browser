// Bridges WKNavigationDelegate, WKUIDelegate, and KVO into ARCHEngine delegate and observer calls.
import AppKit
import ARCHEngine
import AVFoundation
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
            webView.observe(\.isLoading) { [weak owner] _, _ in owner?.loadingStateDidChange() },
            webView.observe(\.estimatedProgress) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeLoadingState($0) } },
            webView.observe(\.themeColor) { [weak owner] _, _ in owner.map { $0.uiDelegate?.webContentsDidChangeThemeColor($0) } },
        ]
    }

    private func navigation(_ navigation: WKNavigation?) -> EngineNavigation {
        EngineNavigation(url: owner.webView.url ?? URL(string: "about:blank")!)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), !EngineURLSchemes.web.contains(scheme) {
            decisionHandler(.cancel)
            owner.uiDelegate?.webContents(owner, openExternally: url, isUserInitiated: navigationAction.navigationType == .linkActivated)
            return
        }
        // A link marked for download starts one instead of a navigation once the page policy allows it.
        let allowed: WKNavigationActionPolicy = navigationAction.shouldPerformDownload ? (mayDownload(navigationAction.request.url, in: webView) ? .download : .cancel) : .allow
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
            return decisionHandler(mayDownload(navigationResponse.response.url, in: webView) ? .download : .cancel)
        }
        decisionHandler(.allow)
    }

    /// A web view that has not committed a navigation has never shown a page.
    private func mayDownload(_ url: URL?, in webView: WKWebView) -> Bool {
        guard owner.allowsDownloads else { return false }
        guard let url, let delegate = owner.uiDelegate else { return true }
        return delegate.webContents(owner, shouldDownload: url, hasPage: webView.backForwardList.currentItem != nil)
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

    /// The tab goes blank until a reload relaunches the process. The application tallies the crash.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner.uiDelegate?.webContentsProcessDidTerminate(owner)
        owner.context.application?.rendererDidCrash()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let delegate = owner.uiDelegate else { return nil }
        // A new window for a link that belongs to another app opens no tab, as on the Chromium engine.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), !EngineURLSchemes.web.contains(scheme) {
            delegate.webContents(owner, openExternally: url, isUserInitiated: navigationAction.navigationType == .linkActivated)
            return nil
        }
        let child = WebKitWebContents(sessionID: UUID().uuidString, parentConfiguration: configuration, context: owner.context)
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

    /// The UI delegate decides for the site; granting access also requires the system's camera or microphone permission for this app, which is requested before the page gets access. WebKit handles geolocation through the app's location authorization.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let delegate = owner.uiDelegate else { return decisionHandler(.prompt) }
        let types: [EnginePermissionType] = type == .camera ? [.camera] : type == .microphone ? [.microphone] : [.camera, .microphone]
        let mediaTypes: [AVMediaType] = types.map { $0 == .camera ? .video : .audio }
        // Skip the site's permission request if the system already denies this app access to the device.
        let isRefusedBySystem = mediaTypes.contains { mediaType in
            let status = AVCaptureDevice.authorizationStatus(for: mediaType)
            return status == .denied || status == .restricted
        }
        guard !isRefusedBySystem else { return decisionHandler(.deny) }
        let request = EnginePermissionRequest(origin: URL(string: "\(origin.protocol)://\(origin.host)") ?? URL(string: "about:blank")!, types: types)
        delegate.webContents(owner, requestPermission: request) { granted in
            guard granted else { return decisionHandler(.deny) }
            Self.requestCaptureAccess(for: mediaTypes) { decisionHandler($0 ? .grant : .deny) }
        }
    }

    /// Requests system permission for each media type in turn. Completes on the main thread with `false` as soon as one is denied.
    private static func requestCaptureAccess(for mediaTypes: [AVMediaType], completion: @escaping (Bool) -> Void) {
        guard let mediaType = mediaTypes.first else { return completion(true) }
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            DispatchQueue.main.async {
                if granted {
                    Self.requestCaptureAccess(for: Array(mediaTypes.dropFirst()), completion: completion)
                } else {
                    completion(false)
                }
            }
        }
    }
}
