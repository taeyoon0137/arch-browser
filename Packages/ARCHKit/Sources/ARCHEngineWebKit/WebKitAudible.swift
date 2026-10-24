// Learns whether a WebKit page plays sound. WebKit has no public API for it, so a script in its own content world watches each document's media elements.
import ARCHEngine
import WebKit

/// Reports whether a document's media elements play sound. It runs in its own content world, so pages cannot read or replace it. Keep it in step with the Chromium engine's script in CEFBridge.mm.
final class WebKitAudibleScript: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "ARCHMedia")
    static let handlerName = "archAudible"
    static let source = """
    (() => {
      const id = `${Date.now()}-${Math.random()}`;
      let audible = false;
      const set = (now) => { if (now !== audible) { audible = now; window.webkit.messageHandlers.\(handlerName).postMessage({ id, audible: now }); } };
      const update = () => set([...document.querySelectorAll('video, audio')].some((m) => !m.paused && !m.ended && !m.muted && m.volume > 0));
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) document.addEventListener(type, update, true);
      addEventListener('pagehide', () => set(false));
      addEventListener('pageshow', update);
    })();
    """

    /// Adds the script and its handler once per content controller; popups share their opener's.
    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(WebKitAudibleScript(), contentWorld: world, name: handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? String, let isAudible = body["audible"] as? Bool,
              let contents = (message.webView as? WebKitWebView)?.contents else { return }
        contents.setDocument(id, audible: isAudible)
    }
}

extension WebKitWebContents {
    func installAudibleScript() {
        WebKitAudibleScript.install(in: webView.configuration.userContentController)
    }

    /// Records one document's state; the page is audible while any of its documents is.
    func setDocument(_ id: String, audible: Bool) {
        let wasAudible = isAudible
        if audible {
            audibleDocuments.insert(id)
        } else {
            audibleDocuments.remove(id)
        }
        if isAudible != wasAudible { uiDelegate?.webContentsDidChangeAudibleState(self) }
    }

    /// A page whose process quit plays nothing, and its documents never report again.
    func clearAudibleDocuments() {
        guard isAudible else { return }
        audibleDocuments.removeAll()
        uiDelegate?.webContentsDidChangeAudibleState(self)
    }
}
