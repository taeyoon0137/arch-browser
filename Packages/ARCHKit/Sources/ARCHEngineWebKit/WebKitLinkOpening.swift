// Tracks explicit opener links in an isolated world; native popup creation keeps their browsing context.
import Foundation
import WebKit

final class WebKitLinkOpeningScript: NSObject, WKScriptMessageHandler {
    private static let name = "archOpenerLink"
    private static let world = WKContentWorld.world(name: "ARCHOpenerLink")
    private static let source = """
    (() => {
      const send = window.webkit.messageHandlers.archOpenerLink.postMessage.bind(window.webkit.messageHandlers.archOpenerLink);
      addEventListener("click", event => {
        if (!event.isTrusted) return;
        const link = event.composedPath().find(node => node instanceof HTMLAnchorElement || node instanceof HTMLAreaElement);
        send(event.button === 0 && !event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey &&
             link && [...link.relList].some(token => token.toLowerCase() === "opener") && !link.hasAttribute("download") ? link.href : "");
      }, true);
    })();
    """

    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(WebKitLinkOpeningScript(), contentWorld: world, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let bridge = (message.webView as? WebKitWebView)?.contents?.bridge else { return }
        bridge.openerLink = text.isEmpty ? nil : URL(string: text).map {
            WebKitOpenerLink(url: $0, frameURL: message.frameInfo.request.url, time: ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// Evidence only suppresses automatic Peek for the matching native popup; explicit Shift remains a preview.
struct WebKitOpenerLink {
    let url: URL
    let frameURL: URL?
    let time: TimeInterval

    func matches(url: URL?, frameURL: URL?, time: TimeInterval) -> Bool {
        self.url == url && self.frameURL == frameURL && time >= self.time && time - self.time < 1
    }
}
