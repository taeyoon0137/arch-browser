// Learns whether a WebKit page plays sound and what its media is. WebKit has no public API for either, so a script in its own content world watches each document's media elements.
import ARCHEngine
import WebKit

/// Reports whether a document's media elements play sound, and describes the element that last played sound together with the page's Media Session metadata. It runs in its own content world, so pages cannot read or replace it. Keep it in step with the Chromium engine's script in CEFBridgeHelper.mm.
final class WebKitAudibleScript: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "ARCHMedia")
    static let handlerName = "archAudible"
    static let source = """
    (() => {
      const id = `${Date.now()}-${Math.random()}`;
      const post = (body) => window.webkit.messageHandlers.\(handlerName).postMessage({ id, ...body });
      const session = navigator.mediaSession;
      let audible = false, hidden = false, current = null, actions = [], reported = 'null';
      const sounds = (m) => !m.paused && !m.ended && !m.muted && m.volume > 0;
      const largest = (artwork) => {
        let best = '', area = -1;
        for (const image of artwork || []) {
          const sizes = String(image.sizes || '').toLowerCase().split(/\\s+/);
          const size = sizes.includes('any') ? Infinity : Math.max(0, ...sizes.map((s) => { const [w, h] = s.split('x').map(Number); return w * h || 0; }));
          if (size > area) { area = size; best = image.src; }
        }
        return best;
      };
      const describe = () => {
        if (hidden || !current || !current.isConnected) return null;
        const metadata = session && session.metadata, duration = current.duration;
        return {
          playing: !current.paused && !current.ended, duration: Number.isFinite(duration) ? duration : 0, live: duration === Infinity,
          position: current.currentTime, rate: current.playbackRate,
          metadata: metadata && { title: metadata.title, artist: metadata.artist, album: metadata.album, artwork: largest(metadata.artwork) },
          next: actions.includes('nexttrack'), previous: actions.includes('previoustrack'),
        };
      };
      const updateMedia = () => { const media = describe(), text = JSON.stringify(media); if (text !== reported) { reported = text; post({ media }); } };
      const update = (event) => {
        if (event && event.target instanceof HTMLMediaElement && sounds(event.target)) current = event.target;
        const now = !hidden && [...document.querySelectorAll('video, audio')].some(sounds);
        if (now !== audible) { audible = now; post({ audible: now }); }
        updateMedia();
      };
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'seeked', 'ratechange', 'durationchange', 'loadedmetadata']) document.addEventListener(type, update, true);
      addEventListener('pagehide', () => { hidden = true; update(); });
      addEventListener('pageshow', () => { hidden = false; update(); });
      // The page world's script reports the actions the page handles whenever they or the metadata change.
      document.addEventListener('__archmediasession', (event) => { actions = String(event.detail).split(' '); updateMedia(); });
      // The app runs media actions here: the page's own handler through the page world's script, or else the media itself.
      window.__archMediaControl = (target, action) => {
        if (target !== id) return;
        if (actions.includes(action)) return document.dispatchEvent(new CustomEvent('__archmediaaction', { detail: action }));
        if (action === 'play' && current) current.play().catch(() => {});
        if (action === 'pause') { if (current) current.pause(); for (const m of document.querySelectorAll('video, audio')) if (sounds(m)) m.pause(); }
      };
    })();
    """

    /// Runs in the page's world, where the page sets its Media Session action handlers, which another world cannot read or call. It records them, tells the media script above which actions the page handles, and runs a handler when that script asks.
    static let pageSource = """
    (() => {
      const session = navigator.mediaSession;
      if (!session) return;
      const apply = Reflect.apply, prototype = Object.getPrototypeOf(session), original = prototype.setActionHandler;
      const metadata = Object.getOwnPropertyDescriptor(prototype, 'metadata'), handlers = new Map();
      const announce = () => document.dispatchEvent(new CustomEvent('__archmediasession', { detail: [...handlers.keys()].join(' ') }));
      prototype.setActionHandler = function setActionHandler(action, handler) {
        apply(original, this, [action, handler]);
        if (this !== session) return;
        if (typeof handler === 'function') handlers.set(action, handler); else handlers.delete(action);
        announce();
      };
      if (metadata && metadata.set) Object.defineProperty(prototype, 'metadata', { ...metadata, set(value) { apply(metadata.set, this, [value]); if (this === session) announce(); } });
      document.addEventListener('__archmediaaction', (event) => { const handler = handlers.get(event.detail); if (handler) apply(handler, session, [{ action: event.detail }]); });
    })();
    """

    /// Adds the scripts and the handler once per content controller; popups share their opener's.
    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: pageSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.add(WebKitAudibleScript(), contentWorld: world, name: handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? String,
              let contents = (message.webView as? WebKitWebView)?.contents else { return }
        if let isAudible = body["audible"] as? Bool {
            contents.setDocument(id, audible: isAudible)
        }
        if let media = body["media"] {
            contents.setDocument(id, media: media, frame: message.frameInfo)
        }
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

    /// Records one document's media, or its lack of media, and the frame where its media actions run.
    func setDocument(_ id: String, media: Any, frame: WKFrameInfo) {
        mediaFrames[id] = media is [String: Any] ? frame : nil
        webKitMediaSession.update(document: id, report: media)
    }

    /// Runs a media action in the document's media script.
    func performMediaAction(_ action: ScriptMediaSession.Action, inDocument id: String) {
        guard let frame = mediaFrames[id] else { return }
        webView.callAsyncJavaScript("__archMediaControl(id, action)", arguments: ["id": id, "action": action.rawValue], in: frame, in: WebKitAudibleScript.world)
    }

    /// A page whose process quit plays nothing, and its documents never report again.
    func clearAudibleDocuments() {
        mediaFrames.removeAll()
        webKitMediaSession.removeAllDocuments()
        guard isAudible else { return }
        audibleDocuments.removeAll()
        uiDelegate?.webContentsDidChangeAudibleState(self)
    }
}
