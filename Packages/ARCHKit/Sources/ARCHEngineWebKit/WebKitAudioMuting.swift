// Page output muting keeps the site's own media settings and capture state unchanged.
import ARCHPrivateAPI
import Foundation
import WebKit

enum WebKitAudioMutingAPI {
    static let stateAPI = "webkit.mediaMutedState"
    static let setterAPI = "webkit.setPageMuted"
    static let featureID = "webkit.audioMuting"
    private static let getter = NSSelectorFromString("_mediaMutedState")
    private static let setter = NSSelectorFromString("_setPageMuted:")
    /// `_WKMediaMutedState` is an NSUInteger bitmask; audio is bit zero.
    private static let audioBit: UInt = 1

    @MainActor static func register() {
        let flags = PrivateAPIFlags.shared
        flags.register(PrivateAPI(id: stateAPI, name: "WKWebView._mediaMutedState", framework: "WebKit") {
            WKWebView.instancesRespond(to: getter)
        })
        flags.register(PrivateAPI(id: setterAPI, name: "WKWebView._setPageMuted:", framework: "WebKit") {
            WKWebView.instancesRespond(to: setter)
        })
        flags.register(PrivateAPIFeature(id: featureID, name: "Tab audio muting on WebKit", apiIDs: [stateAPI, setterAPI]))
    }

    static func isAllowed(in webView: WKWebView) -> Bool {
        MainActor.assumeIsolated { PrivateAPIFlags.shared.allows(featureID) }
            && webView.responds(to: getter) && webView.responds(to: setter)
    }

    static func isMuted(in webView: WKWebView) -> Bool? {
        guard isAllowed(in: webView) else { return nil }
        return state(in: webView) & audioBit != 0
    }

    static func setMuted(_ muted: Bool, in webView: WKWebView) -> Bool {
        guard isAllowed(in: webView) else { return false }
        let current = state(in: webView)
        let updated = muted ? current | audioBit : current & ~audioBit
        if current != updated {
            typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
            let set = unsafeBitCast(webView.method(for: setter), to: Setter.self)
            set(webView, setter, updated)
        }
        return (state(in: webView) & audioBit != 0) == muted
    }

    /// Called only after both flags and selectors have been checked.
    private static func state(in webView: WKWebView) -> UInt {
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        let get = unsafeBitCast(webView.method(for: getter), to: Getter.self)
        return get(webView, getter)
    }
}
