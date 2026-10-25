// A running script plugin. Its background script runs in a hidden web view of its own, in the plugin sandbox, from the activation that the plugin's first command or page script value starts. A call the background script leaves unanswered past the hang limit, or the end of its web content process, fails the instance; an instance without calls for the idle limit stops. Either way it releases its web view and tells the manager, which starts a new instance at the next use.
import WebKit

/// How long, in seconds, a background script may leave a call unanswered before it counts as hung, and an instance may go without calls before it stops.
struct ScriptPluginLimits {
    var hang: TimeInterval
    var idle: TimeInterval

    /// The starting values of `docs/plugins.md`.
    static let standard = ScriptPluginLimits(hang: 10, idle: 30)
}

/// Why a script plugin's instance stopped on its own.
enum ScriptPluginStop: Equatable {
    /// It went without calls for the idle limit.
    case idle
    /// Its background script hung, or its web content process ended, as the sentence says.
    case failed(String)
}

@MainActor
final class ScriptPlugin: NSObject, Plugin, WKNavigationDelegate {
    private let package: PluginPackage
    private let limits: ScriptPluginLimits
    /// Tells the manager that the instance stopped on its own, so that it drops the instance.
    var onStop: ((ScriptPluginStop) -> Void)?
    /// The background script's web view, from the activation until the instance stops. A plugin without a background script has none.
    private var webView: WKWebView?
    /// The calls that wait for the background script, by number: the load of its document, commands, and page script values.
    private var waitingCalls: [Int: CheckedContinuation<Any?, any Error>] = [:]
    private var nextCallNumber = 0
    /// Settles the call that waits for the background document to load.
    private var settleLoad: (@MainActor (Result<Any?, any Error>) -> Void)?
    private var idleStop: Task<Void, Never>?

    init(package: PluginPackage, limits: ScriptPluginLimits) {
        self.package = package
        self.limits = limits
    }

    /// Loads the background document in a new web view and waits, at most for the hang limit, until the background script has run and set its listeners.
    func activate(in context: any PluginContext) async throws {
        guard package.background != nil else { return }
        let webView = WKWebView(frame: .zero, configuration: try await PluginSandbox.configuration(for: package, bridge: ScriptPluginBridge(context: context)))
        webView.navigationDelegate = self
        self.webView = webView
        do {
            _ = try await call { settle in
                self.settleLoad = settle
                webView.load(URLRequest(url: PluginSandbox.backgroundURL(of: package.manifest.id)))
            }
        } catch {
            end(failing: .stopped)
            throw error
        }
    }

    func deactivate() async {
        end(failing: .stopped)
    }

    /// Runs the listener that the background script set with `arch.commands.onRun(id, listener)`, and fails when there is none or it throws.
    func run(_ command: String, _ invocation: PluginInvocation) async throws {
        _ = try await deliver("command", CommandDelivery(command: command, invocation: ScriptInvocation(invocation)))
    }

    /// Passes the value to the listener that the background script set with `arch.pages.onMessage(listener)` and returns what it returns. Nil when the plugin has no background script, or the script no listener.
    func receive(_ message: PluginPageMessage) async throws -> PluginValue? {
        guard package.background != nil, let reply = try await deliver("message", PageMessageDelivery(message)) as? String else { return nil }
        return try JSONDecoder().decode(PluginValue.self, from: Data(reply.utf8))
    }

    /// Hands the payload to the bridge script's delivery function and returns what it returns.
    private func deliver(_ kind: String, _ payload: some Encodable) async throws -> Any? {
        guard let webView else { throw PluginError.stopped }
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        return try await call { settle in
            webView.callAsyncJavaScript(ScriptPluginBridge.deliveryCall, arguments: ["kind": kind, "payload": json], in: nil, in: .page) { result in
                settle(result.map { $0 })
            }
        }
    }

    /// Starts a call that settles through the closure `start` receives, and waits for it at most for the hang limit. A call still unsettled then means that the background script hangs: the instance fails, and every waiting call throws `timedOut`.
    private func call(_ start: (@escaping @MainActor (Result<Any?, any Error>) -> Void) -> Void) async throws -> Any? {
        let number = nextCallNumber
        nextCallNumber += 1
        idleStop?.cancel()
        defer { stopWhenIdle() }
        return try await withCheckedThrowingContinuation { continuation in
            waitingCalls[number] = continuation
            start { [weak self] result in
                self?.waitingCalls.removeValue(forKey: number)?.resume(with: result)
            }
            Task { [weak self, hang = limits.hang] in
                try? await Task.sleep(for: .seconds(hang))
                guard let self, waitingCalls[number] != nil else { return }
                fail("The background script left a call unanswered for \(String(format: "%g", hang)) seconds.", throwing: .timedOut)
            }
        }
    }

    /// Stops the instance once it has gone without calls for the idle limit.
    private func stopWhenIdle() {
        idleStop?.cancel()
        guard waitingCalls.isEmpty, webView != nil else { return }
        idleStop = Task { [weak self, idle = limits.idle] in
            try? await Task.sleep(for: .seconds(idle))
            guard let self, !Task.isCancelled else { return }
            end(failing: .stopped)
            onStop?(.idle)
        }
    }

    /// Ends the instance after its background script hung or its process ended, and tells the manager why.
    private func fail(_ reason: String, throwing error: PluginError) {
        end(failing: error)
        onStop?(.failed(reason))
    }

    /// Releases the web view, which ends its web content process, and fails the calls that wait for it with `error`.
    private func end(failing error: PluginError) {
        idleStop?.cancel()
        idleStop = nil
        settleLoad = nil
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        let calls = waitingCalls
        waitingCalls = [:]
        for call in calls.values {
            call.resume(throwing: error)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settleLoad?(.success(nil))
        settleLoad = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settleLoad?(.failure(error))
        settleLoad = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        settleLoad?(.failure(error))
        settleLoad = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("The background script's process ended unexpectedly.", throwing: .stopped)
    }
}

/// A command as the delivery function receives it.
private struct CommandDelivery: Encodable {
    let command: String
    let invocation: ScriptInvocation
}

/// What a listener of `arch.commands.onRun` receives. Absent values are left out.
private struct ScriptInvocation: Encodable {
    let tab: ScriptTab?
    let spaceId: String?
    let linkUrl: String?
    let imageUrl: String?
    let selection: String?

    init(_ invocation: PluginInvocation) {
        tab = invocation.tab.map(ScriptTab.init)
        spaceId = invocation.spaceID?.uuidString
        linkUrl = invocation.linkURL?.absoluteString
        imageUrl = invocation.imageURL?.absoluteString
        selection = invocation.selection
    }
}

/// What a listener of `arch.pages.onMessage` receives.
private struct PageMessageDelivery: Encodable {
    let tab: ScriptTab
    let frameUrl: String
    let isMainFrame: Bool
    let body: PluginValue

    init(_ message: PluginPageMessage) {
        tab = ScriptTab(message.tab)
        frameUrl = message.frameURL.absoluteString
        isMainFrame = message.isMainFrame
        body = message.body
    }
}

/// A tab as script plugins see it, with its identifiers as text and its engine as `webKit` or `chromium`. Absent values are left out.
private struct ScriptTab: Encodable {
    let id: String
    let spaceId: String?
    let title: String?
    let url: String?
    let engine: String
    let isPinned: Bool
    let isSelected: Bool

    init(_ tab: PluginTab) {
        id = tab.id.uuidString
        spaceId = tab.spaceID?.uuidString
        title = tab.title
        url = tab.url?.absoluteString
        engine = tab.engine.rawValue
        isPinned = tab.isPinned
        isSelected = tab.isSelected
    }
}
