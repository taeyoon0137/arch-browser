// Each WebKit page script world has separate globals that the page and other worlds cannot see.
// A reply-capable message handler in that world carries its channel to the app.
// `executeJavaScript` uses private evaluation without a user gesture when the private API flags allow it; otherwise public evaluation carries WebKit's gesture.
// `executeJavaScriptWithoutUserGesture` and `postPageScriptMessage` require their own flags and that private member. Otherwise they run nothing.
import ARCHEngine
import ARCHPrivateAPI
import WebKit

/// The content controller of a WebKit web contents, which also holds its page scripts. A web contents a page opens uses its opener's controller, and so its page scripts.
final class WebKitUserContentController: WKUserContentController {
    /// The worlds whose channel has its message handler. WebKit refuses a second handler of the same name in a world, and a world keeps its handler, so a channel already open in a document stays open, as on the Chromium engine.
    private var openWorlds: Set<String> = []
    /// The page scripts the controller runs.
    private(set) var pageScripts: [EnginePageScript] = []

    /// Replaces the page scripts and keeps the controller's other scripts. WebKit removes user scripts only all at once, so the page scripts are told apart by the marker their sources start with.
    func setPageScripts(_ scripts: [EnginePageScript]) {
        pageScripts = scripts
        let otherScripts = userScripts.filter { !$0.source.hasPrefix(WebKitPageScripts.marker) }
        removeAllUserScripts()
        otherScripts.forEach(addUserScript)
        var worlds: [String] = []
        for script in scripts where !worlds.contains(script.world) {
            worlds.append(script.world)
        }
        for world in worlds {
            let worldScripts = scripts.filter { $0.world == world }
            let contentWorld = openChannel(inWorld: world)
            addUserScript(WKUserScript(source: WebKitPageScripts.channelSource, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: worldScripts.allSatisfy(\.mainFrameOnly), in: contentWorld))
            for script in worldScripts {
                addUserScript(WKUserScript(source: WebKitPageScripts.marker + WebKitPageScripts.call(script.source),
                                           injectionTime: script.injectionTime == .documentStart ? .atDocumentStart : .atDocumentEnd,
                                           forMainFrameOnly: script.mainFrameOnly, in: contentWorld))
            }
        }
    }

    /// The world's content world, with the message handler of its channel.
    func openChannel(inWorld world: String) -> WKContentWorld {
        let contentWorld = WebKitPageScripts.contentWorld(world)
        if openWorlds.insert(world).inserted {
            addScriptMessageHandler(WebKitPageScriptHandler(world: world), contentWorld: contentWorld, name: WebKitPageScripts.handlerName)
        }
        return contentWorld
    }
}

/// The scripts and names the adapter's page scripts use.
enum WebKitPageScripts {
    /// Starts the source of every page script the controller adds.
    static let marker = "// ARCHPageScript\n"
    static let handlerName = "archPageScript"

    /// Page script worlds are apart from the adapter's own worlds, whatever their names.
    static func contentWorld(_ world: String) -> WKContentWorld {
        .world(name: "ARCHPageScript." + world)
    }

    /// Defines the world's channel in the document, once, as `__archPageScriptChannel`, and the function the app delivers posted values to. Keep it in step with the Chromium engine's channel script in CEFBridgeHelper.mm.
    static let channelSource = marker + """
    (() => {
      if (globalThis.__archPageScriptChannel) return;
      const handler = window.webkit.messageHandlers.\(handlerName), listeners = [];
      const send = (value) => new Promise((resolve) => {
        const json = JSON.stringify(value);
        if (typeof json !== "string") throw new TypeError("A page script can send only values JSON can hold.");
        resolve(handler.postMessage(json).then((reply) => typeof reply === "string" ? JSON.parse(reply) : undefined));
      });
      const onMessage = (listener) => {
        if (typeof listener !== "function") throw new TypeError("A page script's message listener must be a function.");
        listeners.push(listener);
      };
      Object.defineProperty(globalThis, "__archPageScriptChannel", { value: Object.freeze({ send, onMessage }) });
      Object.defineProperty(globalThis, "__archPageScriptDeliver", { value: (json) => {
        const value = JSON.parse(json);
        for (const listener of listeners) {
          try { listener(value); } catch (error) { reportError(error); }
        }
      } });
    })();
    """

    /// Calls a function expression with the world's channel. The function's text stands on lines of its own, so a final line comment in it cannot hide the call.
    static func call(_ function: String) -> String {
        "(\n\(function)\n)(globalThis.__archPageScriptChannel)"
    }
}

/// Carries one world's channel to the page script delegate of the web contents whose page sent the value.
final class WebKitPageScriptHandler: NSObject, WKScriptMessageHandlerWithReply {
    let world: String

    init(world: String) {
        self.world = world
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let reply = EnginePageScriptReply { replyHandler($0, nil) }
        guard let json = message.body as? String, let contents = (message.webView as? WebKitWebView)?.contents,
              let delegate = contents.pageScriptDelegate else { return reply.send(nil) }
        let frame = message.frameInfo
        delegate.webContents(contents, didReceive: EnginePageScriptMessage(world: world, frameURL: frame.request.url, isMainFrame: frame.isMainFrame, json: json),
                             reply: reply.send)
    }
}

extension WebKitWebContents {
    public func setPageScripts(_ scripts: [EnginePageScript]) {
        userContent.setPageScripts(scripts)
    }

    /// The content controller, which a popup shares with its opener.
    public var pageScriptListID: ObjectIdentifier { ObjectIdentifier(userContent) }

    /// The channel script runs first and defines the channel only where the document has none. The function runs without a user gesture while the private API flags allow it (`WebKitUserGestureAPI`), so that the page's handlers for the events it dispatches get no user activation.
    public func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        let source = Self.runSource(calling: script)
        let contentWorld = userContent.openChannel(inWorld: world)
        if WebKitUserGestureAPI.isAllowed {
            return WebKitUserGestureAPI.evaluateWithoutUserGesture(source, in: webView, world: contentWorld) { completion($0.map { $0 as? String }) }
        }
        webView.evaluateJavaScript(source, in: nil, in: contentWorld) { result in
            completion(result.map { $0 as? String })
        }
    }

    /// Runs as `executeJavaScript(_:inWorld:completion:)` does without a user gesture, only while the private API flags allow plugins' page runs (`WebKitUserGestureAPI.pluginRunsFeatureID`), and otherwise runs nothing, not even the channel script.
    public func executeJavaScriptWithoutUserGesture(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void) {
        guard WebKitUserGestureAPI.allowsPluginRuns else { return completion(.failure(EngineUserGestureError())) }
        WebKitUserGestureAPI.evaluateWithoutUserGesture(Self.runSource(calling: script), in: webView, world: userContent.openChannel(inWorld: world)) {
            completion($0.map { $0 as? String })
        }
    }

    /// The channel script, then a call of the function with the channel that evaluates to the string it returns, or to null for any other value.
    private static func runSource(calling function: String) -> String {
        WebKitPageScripts.channelSource + "\n(() => { const result = \(WebKitPageScripts.call(function)); return typeof result === \"string\" ? result : null; })()"
    }

    /// Delivers through the evaluation without a user gesture, only while the private API flags allow plugins' page runs, and otherwise delivers nothing: the public `callAsyncJavaScript` runs the listeners with the user's gesture, so a listener's `click()` on a file input opens the chooser. The JSON text reaches the delivery function as a string literal, which `JSON.parse` reads, so its keys stay data.
    public func postPageScriptMessage(_ json: String, toWorld world: String) throws {
        guard WebKitUserGestureAPI.allowsPluginRuns else { throw EngineUserGestureError() }
        let literal = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        WebKitUserGestureAPI.evaluateWithoutUserGesture("globalThis.__archPageScriptDeliver?.(\(literal)); null", in: webView, world: WebKitPageScripts.contentWorld(world)) { _ in }
    }
}

/// WebKit's private evaluation without a user gesture is registered on the flags page for two features.
/// The agents' page script falls back to public evaluation. One-time plugin page scripts and messages to page scripts do not run without it.
/// Public `evaluateJavaScript(_:in:in:completionHandler:)` and `callAsyncJavaScript(_:arguments:in:in:completionHandler:)` run as though the user clicked.
/// Page handlers for events those scripts dispatch, and timers they start within a second, receive transient user activation. That can allow clipboard writes, a share sheet, a passkey prompt, or fullscreen.
enum WebKitUserGestureAPI {
    static let apiID = "webkit.evaluateWithoutUserGesture"
    static let featureID = "webkit.pageScriptsWithoutUserGesture"
    static let pluginRunsFeatureID = "webkit.pluginPageRunsWithoutUserGesture"
    static let selector = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")

    @MainActor static func register() {
        let flags = PrivateAPIFlags.shared
        flags.register(PrivateAPI(id: apiID, name: "WKWebView._evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:", framework: "WebKit") {
            WKWebView.instancesRespond(to: selector)
        })
        flags.register(PrivateAPIFeature(id: featureID, name: "Page scripts without the user's gesture", apiIDs: [apiID]))
        flags.register(PrivateAPIFeature(id: pluginRunsFeatureID, name: "Plugins' page runs and messages", apiIDs: [apiID]))
    }

    /// Whether the feature may run now. The flags live on the main thread, where web views run scripts.
    static var isAllowed: Bool { MainActor.assumeIsolated { PrivateAPIFlags.shared.allows(featureID) } }

    /// Whether plugins' page runs and messages may run now.
    static var allowsPluginRuns: Bool { MainActor.assumeIsolated { PrivateAPIFlags.shared.allows(pluginRunsFeatureID) } }

    /// Evaluates `source` in the main frame in `world` with no user gesture, through the member the availability check looked up.
    static func evaluateWithoutUserGesture(_ source: String, in webView: WKWebView, world: WKContentWorld, completion: @escaping (Result<Any?, Error>) -> Void) {
        typealias Method = @convention(c) (WKWebView, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool, @escaping @convention(block) (Any?, (any Error)?) -> Void) -> Void
        let method = unsafeBitCast(webView.method(for: selector), to: Method.self)
        method(webView, selector, source as NSString, nil, nil, world, false) { value, error in
            completion(error.map { .failure($0) } ?? .success(value))
        }
    }
}
