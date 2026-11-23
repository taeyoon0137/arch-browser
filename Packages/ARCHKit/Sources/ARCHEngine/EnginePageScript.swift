// Page scripts run in each new document of a web contents and reach the app through a channel.
// Plugins add their scripts through these types (`docs/plugins.md`).
import Foundation

/// When an `EnginePageScript` runs in a new document.
public enum EnginePageScriptInjectionTime: String, Hashable, Sendable {
    /// Before the page's own scripts.
    case documentStart
    /// Once the document is parsed, when it reaches `DOMContentLoaded`.
    case documentEnd
}

/// A script the engine runs in each new document of a web contents. Scripts in one world share globals and one channel to the app.
///
/// WebKit gives each world a separate content world that the page cannot reach.
/// Chromium gives each world an isolated world of its own where Arch's engine makes them (VI.6), and otherwise runs every world in the page's main world, where the page sees globals and DOM changes from scripts, can replace functions they call later, and can see values scripts send and receive, but cannot reach the channel.
/// In an isolated world the page sees only the script's DOM changes.
public struct EnginePageScript: Hashable, Sendable {
    public var world: String
    /// A JavaScript function expression, such as `(channel) => { … }`, that the engine calls with the world's channel:
    /// - `channel.send(value)` passes `value` as JSON to the page script delegate and returns a promise of the reply, or of `undefined` without one. It rejects a value JSON cannot hold.
    /// - `channel.onMessage(listener)` calls `listener` with each value that `postPageScriptMessage(_:toWorld:)` delivers to the main frame's document.
    public var source: String
    public var injectionTime: EnginePageScriptInjectionTime
    /// Whether the script skips the documents of frames inside the page.
    public var mainFrameOnly: Bool

    public init(world: String, source: String, injectionTime: EnginePageScriptInjectionTime, mainFrameOnly: Bool) {
        self.world = world
        self.source = source
        self.injectionTime = injectionTime
        self.mainFrameOnly = mainFrameOnly
    }
}

/// A value a page script sent through its world's channel.
public struct EnginePageScriptMessage: Sendable {
    public var world: String
    /// The address of the sending frame's document, or nil when the engine reported none it could read.
    public var frameURL: URL?
    public var isMainFrame: Bool
    /// The value as JSON text. It is page input: on Chromium, a page that a script hands its channel can send through it.
    public var json: String

    public init(world: String, frameURL: URL?, isMainFrame: Bool, json: String) {
        self.world = world
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
        self.json = json
    }
}

/// Receives the values page scripts send.
public protocol EnginePageScriptDelegate: AnyObject {
    /// Call `reply` with the reply as JSON text, or with nil for none. The first call settles the script's promise; a reply dropped without a call counts as nil.
    func webContents(_ webContents: any EngineWebContents, didReceive message: EnginePageScriptMessage, reply: @escaping (String?) -> Void)
}

/// A page script's reply as both adapters hand it to the delegate: the first call sends it, later calls do nothing, and dropping it without a call sends nil, so the script's promise always settles.
public final class EnginePageScriptReply {
    private var deliver: ((String?) -> Void)?

    /// `deliver` passes the reply to the page.
    public init(_ deliver: @escaping (String?) -> Void) {
        self.deliver = deliver
    }

    public func send(_ json: String?) {
        let deliver = self.deliver
        self.deliver = nil
        deliver?(json)
    }

    deinit {
        deliver?(nil)
    }
}

/// Why `executeJavaScriptWithoutUserGesture(_:inWorld:completion:)` ran nothing: the engine could have run the function only with the user's gesture.
public struct EngineUserGestureError: Error, Equatable, Sendable {
    public init() {}
}
