// A script plugin's panel: one of its package's HTML files in a web view of the plugin sandbox, with a bridge of its own that acts through the instance's context. The popover beside the sidebar item holds it while it shows and lets it go when it closes, which ends its document's AI requests; while it shows, the instance does not stop for being idle.
import AppKit
import WebKit

@MainActor
final class ScriptPluginPanel: NSViewController {
    /// The panel's size, the width of the address pill's site settings popover by a height that leaves a page room.
    static let size = NSSize(width: 300, height: 400)

    private let page: URL
    private let configuration: WKWebViewConfiguration
    private let bridge: ScriptPluginBridge
    /// Told true as the panel starts to show and false once it has closed or its instance has stopped.
    var onShow: ((Bool) -> Void)?
    private(set) var isShown = false
    private var hasEnded = false

    /// The page at `page`, in a web view of `configuration`, whose message handler is `bridge`.
    init(title: String, page: URL, configuration: WKWebViewConfiguration, bridge: ScriptPluginBridge) {
        self.page = page
        self.configuration = configuration
        self.bridge = bridge
        super.init(nibName: nil, bundle: nil)
        self.title = title
        preferredContentSize = Self.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("A panel is made in code.")
    }

    override func loadView() {
        view = WKWebView(frame: NSRect(origin: .zero, size: Self.size), configuration: configuration)
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

    /// Stops the document's AI requests and fails its later calls, as the panel closes or the instance stops. A panel does not show again; the next opening makes a new one.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        bridge.end()
        guard isShown else { return }
        isShown = false
        onShow?(false)
    }
}
