// A script plugin panel shows a package HTML file in a sandboxed web view.
// Its own bridge acts through the plugin instance's context. A sidebar popover holds it while open.
// Closing the popover ends the document's AI requests. An open panel keeps the instance active; stopping the instance closes the popover.
// The panel stays on its page, so its requests belong only to that document.
import AppKit
import WebKit

/// A script plugin's panel in a sidebar popover.
@MainActor
final class ScriptPluginPanel: NSViewController, PluginEndingPanel, WKNavigationDelegate {
    /// The panel's size, the width of the address pill's site settings popover by a height that leaves a page room.
    static let size = NSSize(width: 300, height: 400)

    private let page: URL
    private let panelSize: NSSize
    private let configuration: WKWebViewConfiguration
    private let bridge: ScriptPluginBridge
    /// Told true as the panel starts to show and false once it has closed or its instance has stopped.
    var onShow: ((Bool) -> Void)?
    var onEnd: (@MainActor () -> Void)?
    private(set) var isShown = false
    private var hasEnded = false
    /// Set as the main frame starts to load the page, after which it moves only within the page's document.
    private var hasStartedPage = false

    /// The page at `page`, in a web view of `configuration`, whose message handler is `bridge`.
    init(title: String, page: URL, configuration: WKWebViewConfiguration, bridge: ScriptPluginBridge, size: NSSize) {
        self.page = page
        panelSize = size
        self.configuration = configuration
        self.bridge = bridge
        super.init(nibName: nil, bundle: nil)
        self.title = title
        preferredContentSize = size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func loadView() {
        let webView = WKWebView(frame: NSRect(origin: .zero, size: panelSize), configuration: configuration)
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (view as? WKWebView)?.load(URLRequest(url: page))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard !isShown, !hasEnded else { return }
        isShown = true
        onShow?(true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        end()
    }

    /// Stops the document's AI requests and fails its later calls, as the panel closes or, with `closesPopover`, as the instance stops, when the popover closes too. A panel does not show again; the next opening makes a new one.
    func end(closesPopover: Bool = false) {
        guard !hasEnded else { return }
        hasEnded = true
        bridge.end()
        if closesPopover { onEnd?() }
        guard isShown else { return }
        isShown = false
        onShow?(false)
    }

    // MARK: WKNavigationDelegate

    /// The main frame loads the page once and then moves only within its document, so neither a reload nor a link to another document starts a document while the requests of the one before it still run. A frame inside the page keeps to the sandbox's rules, and a new window opens nowhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let frame = navigationAction.targetFrame else { return decisionHandler(.cancel) }
        guard frame.isMainFrame else { return decisionHandler(.allow) }
        guard hasStartedPage else {
            hasStartedPage = true
            return decisionHandler(.allow)
        }
        decisionHandler(Self.movesWithinDocument(navigationAction, at: webView.url) ? .allow : .cancel)
    }

    /// Whether the navigation only moves to a fragment of the document at `current`: not a reload or a form's post, to the same address with a fragment.
    private static func movesWithinDocument(_ action: WKNavigationAction, at current: URL?) -> Bool {
        guard action.navigationType != .reload, action.request.httpMethod == "GET", let target = action.request.url, target.fragment != nil, let current else { return false }
        return withoutFragment(target) == withoutFragment(current)
    }

    private static func withoutFragment(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }
}
