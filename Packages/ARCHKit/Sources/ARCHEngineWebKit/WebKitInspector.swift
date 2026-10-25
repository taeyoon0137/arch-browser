// Opens WebKit's Web Inspector inside the app through WebKit's private `_inspector` object, behind the private API flags. With a flag off or a member missing, WebKit tabs offer no developer tools of their own and stay inspectable from the system's browser.
import AppKit
import ARCHEngine
import ARCHPrivateAPI
import WebKit

/// The private members the inspector uses, registered on the flags page. Each is looked up by name and checked before use.
enum WebKitInspectorAPI {
    static let inspectorAPIID = "webkit.inspector"
    static let developerExtrasAPIID = "webkit.developerExtras"
    static let featureID = "webkit.webInspector"
    /// The inspector's actions, each without arguments.
    static let actions = ["show", "close", "attach"]

    @MainActor static func register() {
        let flags = PrivateAPIFlags.shared
        flags.register(PrivateAPI(id: inspectorAPIID, name: "WKWebView._inspector", framework: "WebKit") {
            guard let inspector = NSClassFromString("_WKInspector") else { return false }
            return WKWebView.instancesRespond(to: NSSelectorFromString("_inspector"))
                && (actions + ["isVisible"]).allSatisfy { inspector.instancesRespond(to: NSSelectorFromString($0)) }
        })
        flags.register(PrivateAPI(id: developerExtrasAPIID, name: "WKPreferences._developerExtrasEnabled", framework: "WebKit") {
            WKPreferences.instancesRespond(to: NSSelectorFromString("_setDeveloperExtrasEnabled:"))
        })
        flags.register(PrivateAPIFeature(id: featureID, name: "Web Inspector inside WebKit pages, with Inspect Element in their context menu", apiIDs: [inspectorAPIID, developerExtrasAPIID]))
    }

    /// Whether the feature may run now. The flags live on the main thread, where web views are made.
    static var isAllowed: Bool { MainActor.assumeIsolated { PrivateAPIFlags.shared.allows(featureID) } }

    /// Adds Inspect Element to the page's own context menu items.
    static func enableDeveloperExtras(in preferences: WKPreferences) {
        // Key-value coding finds the `_setDeveloperExtrasEnabled:` setter the availability check looked for.
        preferences.setValue(true, forKey: "developerExtrasEnabled")
    }
}

/// WebKit's Web Inspector for one page. WebKit attaches it beside the web view inside the page's view and resizes the web view; its own toolbar docks it to another side or moves it into a window of its own.
final class WebKitDevTools: EngineDevTools {
    private unowned let webView: WKWebView
    /// The inspector stays inside the page's view, so the app has no window to place.
    var window: NSWindow? { nil }
    var didChangeWindow: (() -> Void)?
    var isPlacedByApp: Bool { false }

    init(webView: WKWebView) {
        self.webView = webView
    }

    private var inspector: NSObject? { webView.value(forKey: "_inspector") as? NSObject }

    var isOpen: Bool { inspector?.value(forKey: "visible") as? Bool ?? false }

    func open() {
        perform("show")
        perform("attach")
    }

    func close() { perform("close") }

    private func perform(_ action: String) {
        _ = inspector?.perform(NSSelectorFromString(action))
    }
}
