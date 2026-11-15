// A running script plugin. Its background script runs in a hidden web view of its own, in the plugin sandbox, from the activation that the plugin's first command, panel, page script value, or event starts, and each panel shows one of its package's HTML files in a web view of the same sandbox while the popover holds it. A call the background script leaves unanswered past the hang limit, not counting the time it waits for the reply to an AI request that Arch accepted, or the end of its web content process, fails the instance; an instance without calls for the idle limit and without a panel that shows stops. Either way it releases its web view, ends its panels' documents and closes their popovers, and tells its owner, the plugin manager or the hook runner, which starts a new instance at the next use.
import JavaScriptCore
import WebKit

/// How long, in seconds, a background script may leave a call unanswered before it counts as hung, and an instance may go without calls before it stops.
public struct ScriptPluginLimits: Sendable {
    public var hang: TimeInterval
    public var idle: TimeInterval

    public init(hang: TimeInterval, idle: TimeInterval) {
        self.hang = hang
        self.idle = idle
    }

    /// The starting values of `docs/plugins.md`.
    public static let standard = ScriptPluginLimits(hang: 10, idle: 30)
}

/// Why a script plugin's instance stopped on its own.
public enum ScriptPluginStop: Equatable, Sendable {
    /// It went without calls for the idle limit.
    case idle
    /// Its background script hung, or its web content process ended, as the sentence says.
    case failed(String)
}

@MainActor
public final class ScriptPlugin: NSObject, Plugin, WKNavigationDelegate {
    private let package: PluginPackage
    private let limits: ScriptPluginLimits
    /// Tells the owner that the instance stopped on its own, so that it drops the instance.
    public var onStop: ((ScriptPluginStop) -> Void)?
    /// The background script's web view and bridge, from the activation until the instance stops. A plugin without a background script has none.
    private var webView: WKWebView?
    private var bridge: ScriptPluginBridge?
    /// The context that the panels' bridges act through, from the activation until the instance stops.
    private var context: (any PluginContext)?
    /// The sandbox's rule list, compiled at the activation of a plugin with a background script or a panel.
    private var rules: WKContentRuleList?
    /// The panels that the instance made and that a popover still holds.
    private let panels = NSHashTable<ScriptPluginPanel>.weakObjects()
    /// The calls that wait for the background script, by number: the load of its document, commands, page script values, and events.
    private var waitingCalls: [Int: CheckedContinuation<Any?, any Error>] = [:]
    private var nextCallNumber = 0
    /// Settles the call that waits for the background document to load.
    private var settleLoad: (@MainActor (Result<Any?, any Error>) -> Void)?
    private var idleStop: Task<Void, Never>?
    /// The background script's calls that wait for Arch's own answer, an AI request's reply; when the current stretch of such waits began; and how long the earlier stretches lasted. That time does not count toward the hang limit of the script's unanswered calls, and the instance does not stop for being idle meanwhile.
    private var archWaits = 0
    private var archWaitBegan: ContinuousClock.Instant?
    private var archWaitedBefore: Duration = .zero
    /// While true, the instance does not stop for being idle. The hook runner holds an instance from when it picks it for a run until the run ends, so the idle stop cannot end it between the pick and the event's delivery.
    public var isHeld = false {
        didSet {
            if isHeld {
                idleStop?.cancel()
                idleStop = nil
            } else if oldValue {
                stopWhenIdle()
            }
        }
    }

    /// An instance of a script plugin's package, installed or held in memory, as a hook script's is.
    public init(package: PluginPackage, limits: ScriptPluginLimits) {
        self.package = package
        self.limits = limits
    }

    /// The syntax error of `source` as a classic script, as the background document runs it, such as `SyntaxError: Unexpected end of script (line 3)`, or nil when it parses. JavaScriptCore checks it without running any of it.
    public nonisolated static func syntaxError(in source: String) -> String? {
        syntaxError(in: source, context: JSContext())
    }

    /// As `syntaxError(in:)`, in a context the caller keeps for several checks.
    nonisolated static func syntaxError(in source: String, context: JSContext?) -> String? {
        guard let context else { return "JavaScriptCore could not check it" }
        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception) else { return nil }
        guard let error = JSValue(jsValueRef: exception, in: context), let text = error.toString() else { return "SyntaxError" }
        guard let line = error.objectForKeyedSubscript("line"), line.isNumber else { return text }
        return "\(text) (line \(line.toInt32()))"
    }

    /// Compiles the sandbox's rule list for a plugin with a background script or a panel, then loads the background document in a new web view and waits, at most for the hang limit, until the background script has run and set its listeners.
    public func activate(in context: any PluginContext) async throws {
        self.context = context
        let hasPanels = package.manifest.contributions.sidebarItems.contains { Self.page(of: $0) != nil }
        guard package.background != nil || hasPanels else { return }
        let rules: WKContentRuleList
        do {
            rules = try await PluginSandbox.blockingRules()
        } catch {
            end(failing: .stopped)
            throw error
        }
        self.rules = rules
        guard package.background != nil else { return }
        let bridge = ScriptPluginBridge(context: context)
        bridge.waitsForArch = { [weak self] waits in self?.archWait(began: waits) }
        let webView = WKWebView(frame: .zero, configuration: PluginSandbox.configuration(for: package, bridge: bridge, rules: rules))
        webView.navigationDelegate = self
        self.webView = webView
        self.bridge = bridge
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

    public func deactivate() async {
        end(failing: .stopped)
    }

    /// Runs the listener that the background script set with `arch.commands.onRun(id, listener)`, and fails when there is none or it throws.
    public func run(_ command: String, _ invocation: PluginInvocation) async throws {
        _ = try await deliver("command", CommandDelivery(command: command, invocation: ScriptInvocation(invocation)))
    }

    /// A new panel for a sidebar item whose action shows a page of the package, whose bridge acts through the instance's context and whose AI requests belong to no hook step. Nil for another item, and once the instance has stopped.
    public func panel(for sidebarItemID: String) -> NSViewController? {
        guard let context, let rules, let item = package.manifest.contributions.sidebarItems.first(where: { $0.id == sidebarItemID }),
              let page = Self.page(of: item) else { return nil }
        let bridge = ScriptPluginBridge(context: context, role: .panel)
        let panel = ScriptPluginPanel(title: item.title, page: PluginSandbox.url(of: page, in: package.manifest.id),
                                      configuration: PluginSandbox.configuration(for: package, bridge: bridge, rules: rules), bridge: bridge)
        panel.onShow = { [weak self] isShown in
            guard let self else { return }
            if isShown {
                idleStop?.cancel()
                idleStop = nil
            } else {
                stopWhenIdle()
            }
        }
        panels.add(panel)
        return panel
    }

    /// The package path of the page that the item's panel shows, or nil for an item that runs a command.
    private static func page(of item: PluginSidebarItem) -> String? {
        guard case let .panel(page) = item.action else { return nil }
        return page
    }

    /// Passes the value to the listener that the background script set with `arch.pages.onMessage(listener)` and returns what it returns. Nil when the plugin has no background script, or the script no listener.
    public func receive(_ message: PluginPageMessage) async throws -> PluginValue? {
        guard package.background != nil, let reply = try await deliver("message", PageMessageDelivery(message)) as? String else { return nil }
        return try JSONDecoder().decode(PluginValue.self, from: Data(reply.utf8))
    }

    /// Runs, one after another, the listeners that the background script set with `arch.events.on(kind, listener)` for the event's kind, and returns once the last one's promise settles. Throws `PluginError.noListener` when the script set none for the kind, and `listenerFailed` with what a listener threw.
    public func handle(_ event: PluginEvent) async throws {
        guard package.background != nil,
              let reply = try await deliver("event", EventDelivery(try event.scriptValue())) as? String else { return }
        let failure = try JSONDecoder().decode(EventFailure.self, from: Data(reply.utf8))
        if failure.noListener == true { throw PluginError.noListener }
        throw PluginError.listenerFailed(failure.error ?? "")
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

    /// Starts a call that settles through the closure `start` receives, and waits for it at most for the hang limit, not counting the time the background script waits for Arch's answer to an AI request. A call still unsettled then means that the background script hangs: the instance fails, and every waiting call throws `timedOut`.
    private func call(_ start: (@escaping @MainActor (Result<Any?, any Error>) -> Void) -> Void) async throws -> Any? {
        let number = nextCallNumber
        nextCallNumber += 1
        idleStop?.cancel()
        defer { stopWhenIdle() }
        let startedAt = ContinuousClock.now
        let waitedBefore = archWaited
        return try await withCheckedThrowingContinuation { continuation in
            waitingCalls[number] = continuation
            start { [weak self] result in
                self?.waitingCalls.removeValue(forKey: number)?.resume(with: result)
            }
            Task { [weak self, hang = Duration.seconds(limits.hang)] in
                var deadline = startedAt + hang
                while true {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard let self, waitingCalls[number] != nil else { return }
                    // The time the script waited for Arch's answers is Arch's, not the call's.
                    let counted = ContinuousClock.now - startedAt - (archWaited - waitedBefore)
                    guard counted < hang else {
                        return fail("The background script left a call unanswered for \(String(format: "%g", limits.hang)) seconds.", throwing: .timedOut)
                    }
                    deadline = .now + max(hang - counted, .milliseconds(100))
                }
            }
        }
    }

    /// How long the background script has waited for Arch's answers in all.
    private var archWaited: Duration {
        archWaitedBefore + (archWaitBegan.map { ContinuousClock.now - $0 } ?? .zero)
    }

    /// Counts the background script's calls that wait for Arch's answer, and the time they cover.
    private func archWait(began: Bool) {
        if began {
            if archWaits == 0 { archWaitBegan = .now }
            archWaits += 1
            idleStop?.cancel()
            idleStop = nil
        } else {
            guard archWaits > 0 else { return }
            archWaits -= 1
            if archWaits == 0, let began = archWaitBegan {
                archWaitedBefore += .now - began
                archWaitBegan = nil
            }
            stopWhenIdle()
        }
    }

    /// Stops the instance once it has gone without calls for the idle limit, unless it is held, waits for Arch's answer to an AI request, or has a panel that shows.
    private func stopWhenIdle() {
        idleStop?.cancel()
        guard waitingCalls.isEmpty, archWaits == 0, webView != nil, !isHeld, !panels.allObjects.contains(where: \.isShown) else { return }
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

    /// Releases the web view, which ends its web content process, ends the panels' documents and closes their popovers, and fails the calls that wait for the background script with `error`.
    private func end(failing error: PluginError) {
        idleStop?.cancel()
        idleStop = nil
        settleLoad = nil
        context = nil
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        bridge?.end()
        bridge = nil
        for panel in panels.allObjects {
            panel.end(closesPopover: true)
        }
        let calls = waitingCalls
        waitingCalls = [:]
        for call in calls.values {
            call.resume(throwing: error)
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settleLoad?(.success(nil))
        settleLoad = nil
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settleLoad?(.failure(error))
        settleLoad = nil
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        settleLoad?(.failure(error))
        settleLoad = nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("The background script\u{2019}s process ended unexpectedly.", throwing: .stopped)
    }
}

/// A command as the delivery function receives it.
private struct CommandDelivery: Encodable {
    let command: String
    let invocation: ScriptInvocation
}

/// What a listener of `arch.commands.onRun` receives. Absent values are left out.
private struct ScriptInvocation: Encodable {
    let tab: PluginValue?
    let spaceId: String?
    let linkUrl: String?
    let imageUrl: String?
    let selection: String?

    init(_ invocation: PluginInvocation) {
        tab = invocation.tab?.scriptValue
        spaceId = invocation.spaceID?.uuidString
        linkUrl = invocation.linkURL?.absoluteString
        imageUrl = invocation.imageURL?.absoluteString
        selection = invocation.selection
    }
}

/// What a listener of `arch.pages.onMessage` receives.
private struct PageMessageDelivery: Encodable {
    let tab: PluginValue
    let frameUrl: String
    let isMainFrame: Bool
    let body: PluginValue

    init(_ message: PluginPageMessage) {
        tab = message.tab.scriptValue
        frameUrl = message.frameURL.absoluteString
        isMainFrame = message.isMainFrame
        body = message.body
    }
}

/// How the delivery function reports an event its listeners did not handle: `noListener` when the script set none for the kind, or `error` with what a listener threw.
private struct EventFailure: Decodable {
    let noListener: Bool?
    let error: String?
}

/// An event as the delivery function receives it: its kind, which picks the listeners, and its JSON.
private struct EventDelivery: Encodable {
    let kind: String
    let event: PluginValue

    init(_ event: (kind: String, value: PluginValue)) {
        kind = event.kind
        self.event = event.value
    }
}

extension PluginEvent {
    /// The event's kind and JSON as listeners receive it: the view's members, with its dates in ISO 8601, and the sender's.
    func scriptValue() throws -> (kind: String, value: PluginValue) {
        switch self {
        case .browser(let view, let extra):
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // A view encodes as an object.
            guard case .object(var members) = try JSONDecoder().decode(PluginValue.self, from: encoder.encode(view)) else { return (view.kind.rawValue, .object(extra)) }
            members.merge(extra) { _, added in added }
            return (view.kind.rawValue, .object(members))
        }
    }
}

extension PluginTab {
    /// The tab as scripts see it, in `arch.tabs`, a command's invocation, and a page message: its identifiers as text, its engine as `webKit` or `chromium`, and its kind as events name it. Absent values are left out.
    var scriptValue: PluginValue {
        var members: [String: PluginValue] = [
            "id": .string(id.uuidString), "engine": .string(engine.rawValue), "kind": .string(kind.rawValue),
            "isPinned": .bool(isPinned), "isSelected": .bool(isSelected),
        ]
        if let spaceID { members["spaceId"] = .string(spaceID.uuidString) }
        if let title { members["title"] = .string(title) }
        if let url { members["url"] = .string(url.absoluteString) }
        return .object(members)
    }
}
