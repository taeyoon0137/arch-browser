// Hooks: features subscribe to browser events through the AI interface and answer them with actions. `Browsing` posts the events and, as the center's host, checks and applies the actions. The hooks for one event run one at a time in priority order on the shared scheduler (`AIHookScheduler`), a newer event for the same subject replaces an older one, and a hook runs only for an automatic feature that is on, has a model of its own, and is within its budgets.
import Combine
import Foundation

// MARK: - Events

/// The raw values are the browser event bus's kinds, so the center's steps for a bus event join the chain that other owners' steps for it use.
public enum AIHookEventKind: String, Hashable, Sendable {
    case pageLoaded
    case tabOpened
    case downloadFinished
}

/// A browser event that hooks can act on.
public enum AIHookEvent: Sendable {
    /// A tab's main frame finished loading a document.
    case pageLoaded(AIPageLoad)
    /// A tab opened, other than one restored from the saved session or a pinned tab that a browser import opened.
    case tabOpened(AITabOpen)
    /// A download finished, and its file is in place.
    case downloadFinished(AIDownloadFinish)

    public var kind: AIHookEventKind {
        switch self {
        case .pageLoaded: return .pageLoaded
        case .tabOpened: return .tabOpened
        case .downloadFinished: return .downloadFinished
        }
    }

    /// The tab or download the event is about. A newer event of the same kind and subject replaces an older one.
    public var subject: UUID {
        switch self {
        case .pageLoaded(let load): return load.tabID
        case .tabOpened(let open): return open.tabID
        case .downloadFinished(let download): return download.downloadID
        }
    }

    /// The addresses the event comes from, to which site exclusions apply: the page's, or the download's source and the page it started from.
    public var urls: [URL] {
        switch self {
        case .pageLoaded(let load): return [load.url]
        case .tabOpened(let open): return open.url.map { [$0] } ?? []
        case .downloadFinished(let download): return [download.info.sourceURL, download.info.pageURL].compactMap { $0 }
        }
    }

    /// The page a page load's hooks act on, whose chain ends when the tab commits another document.
    var document: URL? {
        guard case .pageLoaded(let load) = self else { return nil }
        return load.url
    }

    var documentID: UUID? {
        guard case .pageLoaded(let load) = self else { return nil }
        return load.documentID
    }
}

public struct AIPageLoad: Sendable {
    public var tabID: UUID
    public var url: URL
    /// The first load of a tab restored from the saved session or of a pinned tab that a browser import opened.
    public var isRestore: Bool
    public var documentID: UUID?

    public init(tabID: UUID, url: URL, isRestore: Bool, documentID: UUID? = nil) {
        self.tabID = tabID
        self.url = url
        self.isRestore = isRestore
        self.documentID = documentID
    }
}

public struct AITabOpen: Sendable {
    public var tabID: UUID
    /// The address the tab opens with; nil while its engine has reported none.
    public var url: URL?

    public init(tabID: UUID, url: URL?) {
        self.tabID = tabID
        self.url = url
    }
}

public struct AIDownloadFinish: Sendable {
    public var downloadID: UUID
    public var fileURL: URL
    /// What a hook may send about the download, which never includes the file's contents.
    public var info: AIDownloadInfo
    /// Whether the user chose the file's name, in a save panel.
    public var isNamedByUser: Bool

    public init(downloadID: UUID, fileURL: URL, info: AIDownloadInfo, isNamedByUser: Bool) {
        self.downloadID = downloadID
        self.fileURL = fileURL
        self.info = info
        self.isNamedByUser = isNamedByUser
    }
}

// MARK: - Subscriptions, results, and actions

/// A feature's subscription to events. Its handler runs for each event of the listed kinds and returns the actions the host applies.
public struct AIHookRegistration: Sendable {
    public var feature: AIFeatureID
    public var events: Set<AIHookEventKind>
    /// Lower runs earlier, and hooks of equal priority run in the order of their feature IDs. Built-in hooks use 100.
    public var priority: Int
    /// How long after the event the hook runs. A newer event for the same subject during the wait replaces this one.
    public var delay: Duration
    /// The center cancels the hook when it runs longer, and waits for it no longer.
    public var timeout: Duration
    /// The kinds of action the center passes on to the host; it drops the others.
    public var allowedActions: Set<AIHookActionKind>
    public var handler: @Sendable (AIHookEvent, AIHookContext) async throws -> AIHookResult

    public init(feature: AIFeatureID, events: Set<AIHookEventKind>, priority: Int = 100, delay: Duration = .zero, timeout: Duration = .seconds(30),
                allowedActions: Set<AIHookActionKind>, handler: @escaping @Sendable (AIHookEvent, AIHookContext) async throws -> AIHookResult) {
        self.feature = feature
        self.events = events
        self.priority = priority
        self.delay = delay
        self.timeout = timeout
        self.allowedActions = allowedActions
        self.handler = handler
    }
}

/// What a hook's handler gets besides the event.
public struct AIHookContext: Sendable {
    /// Sends each request under the hook's feature, whatever feature the request names.
    public let client: any AIClient
    public let pages: any AIPageSource
    /// The actions that earlier hooks applied for this event.
    public let appliedActions: [AIHookAction]
}

public enum AIHookResult: Sendable {
    case none
    /// `stop` keeps later hooks from running for this event.
    case actions([AIHookAction], stop: Bool)
}

public enum AIHookActionKind: Hashable, Sendable {
    case renameTab
    case renameDownload
}

/// A change a hook asks for. The host applies it only while it still fits the event, so a hook never needs a tool that changes state.
public enum AIHookAction: Sendable {
    /// Names the tab of a page load while the user has not named the tab and it still shows that page.
    case renameTab(UUID, title: String)
    /// Renames the finished download's file while the user has not chosen its name and it is still where the event found it. The file keeps its extension.
    case renameDownload(UUID, filename: String)

    public var kind: AIHookActionKind {
        switch self {
        case .renameTab: return .renameTab
        case .renameDownload: return .renameDownload
        }
    }
}

/// The browser side of the hooks, which `Browsing` provides: the pages hooks read, and the actions they return.
@MainActor
public protocol AIHookHost: AnyObject {
    var pages: any AIPageSource { get }
    /// Applies the action when it still fits the event, and reports whether it did.
    func apply(_ action: AIHookAction, for event: AIHookEvent) -> Bool
}

/// Why the center stopped a hook on its own.
public enum AIHookError: Error, Sendable {
    case timedOut
}

extension AIHookError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timedOut: return "The hook took too long and was stopped."
        }
    }
}

/// Ends a subscription. A running hook of the subscription's feature stops, and its actions are dropped.
@MainActor
public final class AIHookSubscription {
    private weak var center: AIHookCenter?
    private let id: UUID

    fileprivate init(center: AIHookCenter, id: UUID) {
        self.center = center
        self.id = id
    }

    public func cancel() {
        center?.unsubscribe(id)
    }
}

// MARK: - Center

/// Runs the hooks for each event the host posts, as steps of the shared scheduler under each hook's feature. Hook errors never show a sheet: each feature's last one stays here for its row in Settings ▸ AI.
@MainActor
public final class AIHookCenter: ObservableObject {
    /// Each feature's last error: from its hooks' last request that failed, a hook that failed on its own or timed out, or a reached budget. A request that succeeds or a change to the feature's route clears it, and a hook that sends no request leaves it.
    @Published public private(set) var lastErrors: [AIFeatureID: any Error] = [:]
    /// Features whose hooks paused after consecutive authentication or provider errors, until the user resumes them or changes their route: the scheduler's paused owners.
    @Published public private(set) var pausedFeatures: Set<AIFeatureID> = []
    /// Set by `Browsing`. Without a host, posted events reach no hook.
    public weak var host: (any AIHookHost)?
    /// The scheduler that runs the center's hooks, which plugin hooks and the hook registry share, so one event's hooks from every owner run in one chain (`docs/hooks.md`, The shared scheduler).
    public let scheduler: AIHookScheduler

    /// The consecutive authentication or provider errors that pause a feature's hooks.
    public static let failuresBeforePause = AIHookScheduler.failuresBeforePause

    private unowned let service: AIService
    private var registrations: [UUID: AIHookRegistration] = [:]
    /// The routes as last seen, to notice which features' routes the user changed.
    private var routes: [String: AIRoute]
    private var cancellables: Set<AnyCancellable> = []

    init(service: AIService) {
        self.service = service
        scheduler = AIHookScheduler(service: service)
        routes = service.settings.routes
        scheduler.$pausedOwners
            .sink { [weak self] owners in MainActor.assumeIsolated { self?.pausedFeatures = Set(owners.map(AIFeatureID.init(rawValue:))) } }
            .store(in: &cancellables)
        service.settings.$routes
            .sink { [weak self] routes in MainActor.assumeIsolated { self?.routesWillChange(to: routes) } }
            .store(in: &cancellables)
    }

    @discardableResult
    public func subscribe(_ registration: AIHookRegistration) -> AIHookSubscription {
        let id = UUID()
        registrations[id] = registration
        return AIHookSubscription(center: self, id: id)
    }

    /// The subscription's feature's running hook stops, and its waiting hooks skip.
    fileprivate func unsubscribe(_ id: UUID) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        scheduler.cancel(owner: registration.feature.rawValue)
    }

    /// Posts the event under a new event identifier.
    public func post(_ event: AIHookEvent) {
        post(event, event: UUID())
    }

    /// Runs the hooks that listen for the event's kind in the chain of the browser event `id`, which other owners' steps for that event join, after the hooks of an older event for the same subject have stopped. An event from a site where AI is off reaches no hook.
    public func post(_ event: AIHookEvent, event id: UUID) {
        guard host != nil else { return }
        let listening = registrations.filter { $0.value.events.contains(event.kind) }
            .sorted { ($0.value.priority, $0.value.feature.rawValue) < ($1.value.priority, $1.value.feature.rawValue) }
        guard !listening.isEmpty else { return }
        let run = EventRun()
        let steps = listening.map { step(for: $0.value, registrationID: $0.key, event: event, in: run) }
        scheduler.post(steps, kind: event.kind.rawValue, subject: event.subject, event: id, document: event.document, documentID: event.documentID, urls: event.urls)
    }

    /// Stops the hooks for a tab that closed or a download the user removed, and drops their actions.
    public func cancel(subject: UUID) {
        scheduler.cancel(subject: subject)
    }

    /// Runs the feature's paused hooks again from the next event.
    public func resume(_ feature: AIFeatureID) {
        scheduler.resume(owner: feature.rawValue)
    }

    // MARK: Running

    /// What the center's hooks for one event share: the actions applied so far and whether a hook stopped the rest.
    @MainActor
    private final class EventRun {
        var applied: [AIHookAction] = []
        var isStopped = false
    }

    /// What one hook returned, which counts only once the scheduler takes its end as finished.
    @MainActor
    private final class HookReturn {
        var result: AIHookResult?
    }

    /// The hook as a step: it runs while its subscription lasts and no earlier hook stopped the event, sees the actions applied before it, and has its allowed actions applied before the next step starts. A step whose subscription ended counts for nothing.
    private func step(for registration: AIHookRegistration, registrationID: UUID, event: AIHookEvent, in run: EventRun) -> AIHookStep {
        let feature = registration.feature
        let returned = HookReturn()
        return AIHookStep(owner: feature.rawValue, order: registration.priority, feature: feature, routes: [feature.rawValue],
                          delay: registration.delay, timeout: registration.timeout,
                          mayRun: { [weak self] in self?.registrations[registrationID] != nil && self?.host != nil && !run.isStopped },
                          run: { [weak self] requestDidEnd in
                              guard let context = await self?.context(for: feature, in: run, requestDidEnd: requestDidEnd) else { return }
                              let result = try await registration.handler(event, context)
                              await MainActor.run { returned.result = result }
                          },
                          didEnd: { [weak self] outcome in
                              guard let self, self.registrations[registrationID] != nil else { return }
                              self.hookDidEnd(outcome, registration: registration, event: event, returned: returned.result, in: run)
                          })
    }

    private func context(for feature: AIFeatureID, in run: EventRun, requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) -> AIHookContext? {
        guard let host else { return nil }
        let client = AIHookClient(feature: feature, base: service) { [weak self] error in
            requestDidEnd(error)
            self?.recordRequest(endingWith: error, of: feature)
        }
        return AIHookContext(client: client, pages: host.pages, appliedActions: run.applied)
    }

    /// A finished hook's allowed actions apply while the host takes them; a hook's own error, its timeout, or a reached budget becomes the feature's last error.
    private func hookDidEnd(_ outcome: AIHookStepOutcome, registration: AIHookRegistration, event: AIHookEvent, returned: AIHookResult?, in run: EventRun) {
        switch outcome {
        case .finished:
            guard case .actions(let actions, let stop)? = returned, let host else { return }
            for action in actions where registration.allowedActions.contains(action.kind) && host.apply(action, for: event) {
                run.applied.append(action)
            }
            if stop { run.isStopped = true }
        case .failed(let error):
            lastErrors[registration.feature] = error
        case .timedOut:
            lastErrors[registration.feature] = AIHookError.timedOut
        case .skipped(.budgetReached(let budget)):
            lastErrors[registration.feature] = AIError.budgetReached(budget)
        case .stopped, .skipped:
            break
        }
    }

    /// A hook's request that ended with a reply clears the feature's error, and one that failed keeps its error for the feature's row. The scheduler counts the consecutive authentication and provider errors that pause the feature.
    private func recordRequest(endingWith error: (any Error)?, of feature: AIFeatureID) {
        if let error {
            lastErrors[feature] = error
        } else if lastErrors[feature] != nil {
            lastErrors[feature] = nil
        }
    }

    /// Switching a feature off or changing its models clears its last error, which was about the old route; the scheduler stops its running hooks and resumes it.
    private func routesWillChange(to newRoutes: [String: AIRoute]) {
        let changed = Set(registrations.values.map(\.feature)).filter { routes[$0.rawValue] != newRoutes[$0.rawValue] }
        routes = newRoutes
        for feature in changed { lastErrors[feature] = nil }
    }
}

/// The client a hook gets: each request goes out under the hook's feature, so a hook uses its own route, data scope, and daily limit, and the center learns how each request ended.
private struct AIHookClient: AIClient {
    let feature: AIFeatureID
    let base: any AIClient
    /// Gets the end of each request: nil for a reply, or its error. A request whose reader stopped reports nothing.
    let requestDidEnd: @MainActor @Sendable ((any Error)?) -> Void

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        var request = request
        request.feature = feature
        let events = base.stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events { continuation.yield(event) }
                    // A stream read by a cancelled task ends without an error.
                    if !Task.isCancelled { await requestDidEnd(nil) }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { await requestDidEnd(error) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
