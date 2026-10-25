// Hooks: features subscribe to browser events through the AI interface and answer them with actions. `Browsing` posts the events and, as the center's host, checks and applies the actions. The hooks for one event run one at a time in priority order, a newer event for the same subject replaces an older one, and a hook runs only for an automatic feature that is on, has a model of its own, and is within its budgets.
import Combine
import Foundation

// MARK: - Events

public enum AIHookEventKind: Hashable, Sendable {
    case pageLoaded
    case tabOpened
    case downloadFinished
}

/// A browser event that hooks can act on.
public enum AIHookEvent: Sendable {
    /// A tab's main frame finished loading a document.
    case pageLoaded(AIPageLoad)
    /// A tab opened, other than one restored from the saved session.
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

    /// The address the event comes from, to which site exclusions apply: the page, or the download's page or source.
    public var url: URL? {
        switch self {
        case .pageLoaded(let load): return load.url
        case .tabOpened(let open): return open.url
        case .downloadFinished(let download): return download.info.pageURL ?? download.info.sourceURL
        }
    }
}

public struct AIPageLoad: Sendable {
    public var tabID: UUID
    public var url: URL
    /// The first load of a tab restored from the saved session.
    public var isRestore: Bool

    public init(tabID: UUID, url: URL, isRestore: Bool) {
        self.tabID = tabID
        self.url = url
        self.isRestore = isRestore
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
    /// The center stops the hook when it runs longer.
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

/// Ends a subscription. A hook of the subscription that is running stops, and its actions are dropped.
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

/// Runs the hooks for each event the host posts. Hook errors never show a sheet: each feature's last one stays here for its row in Settings ▸ AI.
@MainActor
public final class AIHookCenter: ObservableObject {
    /// Each feature's error from its last hook that did not succeed, until one succeeds or the user changes the feature's route.
    @Published public private(set) var lastErrors: [AIFeatureID: any Error] = [:]
    /// Features whose hooks paused after consecutive authentication or provider errors, until the user resumes them or changes their route.
    @Published public private(set) var pausedFeatures: Set<AIFeatureID> = []
    /// Set by `Browsing`. Without a host, posted events reach no hook.
    public weak var host: (any AIHookHost)?

    /// The consecutive authentication or provider errors that pause a feature's hooks.
    public static let failuresBeforePause = 3

    private unowned let service: AIService
    private var registrations: [UUID: AIHookRegistration] = [:]
    /// The hooks running or waiting for each event, by the event's kind and subject.
    private var chains: [ChainKey: Chain] = [:]
    /// Each feature's consecutive authentication and provider errors.
    private var failureCounts: [AIFeatureID: Int] = [:]
    /// The routes as last seen, to notice which features' routes the user changed.
    private var routes: [String: AIRoute]
    private var cancellables: Set<AnyCancellable> = []

    init(service: AIService) {
        self.service = service
        routes = service.settings.routes
        service.settings.$routes
            .sink { [weak self] routes in MainActor.assumeIsolated { self?.routesWillChange(to: routes) } }
            .store(in: &cancellables)
        // The AI module does not link AppKit, so it names the notification. Quitting drops every hook's actions.
        NotificationCenter.default.publisher(for: Notification.Name("NSApplicationWillTerminateNotification"))
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.cancelAll() } }
            .store(in: &cancellables)
    }

    @discardableResult
    public func subscribe(_ registration: AIHookRegistration) -> AIHookSubscription {
        let id = UUID()
        registrations[id] = registration
        return AIHookSubscription(center: self, id: id)
    }

    fileprivate func unsubscribe(_ id: UUID) {
        registrations[id] = nil
        stopRunningHooks { $0.registration == id }
    }

    /// Runs the hooks that listen for the event's kind, after the hooks of an older event for the same subject have stopped. An event from a site where AI is off reaches no hook.
    public func post(_ event: AIHookEvent) {
        guard host != nil, reachesHooks(event) else { return }
        let order = registrations.filter { $0.value.events.contains(event.kind) }
            .sorted { ($0.value.priority, $0.value.feature.rawValue) < ($1.value.priority, $1.value.feature.rawValue) }
            .map(\.key)
        guard !order.isEmpty else { return }
        let key = ChainKey(kind: event.kind, subject: event.subject)
        let previous = chains[key]
        previous?.task?.cancel()
        let chain = Chain()
        chains[key] = chain
        let postedAt = ContinuousClock.now
        chain.task = Task { [weak self] in
            await previous?.task?.value
            await self?.run(order, for: event, postedAt: postedAt, in: chain)
            if self?.chains[key] === chain { self?.chains[key] = nil }
        }
    }

    /// Stops the hooks for a tab that closed or a download the user removed, and drops their actions.
    public func cancel(subject: UUID) {
        for (key, chain) in chains where key.subject == subject {
            chain.task?.cancel()
            chains[key] = nil
        }
    }

    /// Runs the feature's paused hooks again from the next event.
    public func resume(_ feature: AIFeatureID) {
        pausedFeatures.remove(feature)
        failureCounts[feature] = nil
    }

    // MARK: Running

    private struct ChainKey: Hashable {
        var kind: AIHookEventKind
        var subject: UUID
    }

    /// The hooks one event runs, one at a time.
    @MainActor
    private final class Chain {
        var task: Task<Void, Never>?
        /// The hook that runs now, which its subscription's end or a change to its feature's route stops on its own.
        var running: RunningHook?
    }

    private struct RunningHook {
        var registration: UUID
        var feature: AIFeatureID
        var task: Task<AIHookResult, any Error>
    }

    private enum Outcome {
        case finished(AIHookResult)
        case failed(any Error)
        /// The hook was cancelled before it finished: its subscription ended, its feature's route changed, or its chain was cancelled.
        case stopped
        case timedOut
    }

    /// Runs each hook after its delay, applying its allowed actions before the next one starts. A cancelled chain drops the actions of the hook that was running.
    private func run(_ order: [UUID], for event: AIHookEvent, postedAt: ContinuousClock.Instant, in chain: Chain) async {
        var applied: [AIHookAction] = []
        for id in order {
            guard let registration = registrations[id] else { continue }
            do {
                try await Task.sleep(until: postedAt + registration.delay, clock: .continuous)
            } catch {
                return
            }
            // The subscription, the feature's route, or the site's exclusion may have changed during the wait.
            guard registrations[id] != nil, reachesHooks(event), mayRun(registration.feature), let host else { continue }
            let context = AIHookContext(client: AIHookClient(feature: registration.feature, base: service), pages: host.pages, appliedActions: applied)
            let task = Task { try await registration.handler(event, context) }
            chain.running = RunningHook(registration: id, feature: registration.feature, task: task)
            let outcome = await outcome(of: task, timeout: registration.timeout)
            chain.running = nil
            if Task.isCancelled { return }
            switch outcome {
            case .finished(let result):
                recordSuccess(of: registration.feature)
                guard case .actions(let actions, let stop) = result else { continue }
                for action in actions where registration.allowedActions.contains(action.kind) && host.apply(action, for: event) {
                    applied.append(action)
                }
                if stop { return }
            case .failed(let error):
                record(error, of: registration.feature)
            case .timedOut:
                record(AIHookError.timedOut, of: registration.feature)
            case .stopped:
                continue
            }
        }
    }

    /// Waits for the hook, cancelling it when its timeout passes or the chain is cancelled. A cancelled hook's result counts for nothing, even when the hook returned one.
    private func outcome(of task: Task<AIHookResult, any Error>, timeout: Duration) async -> Outcome {
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            task.cancel()
        }
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        watchdog.cancel()
        // The watchdog's sleep throws when it is cancelled before the timeout passed.
        if (try? await watchdog.value) != nil { return .timedOut }
        if task.isCancelled { return .stopped }
        switch result {
        case .success(let value): return .finished(value)
        case .failure(let error): return .failed(error)
        }
    }

    /// Whether the event's address, if any, may reach hooks.
    private func reachesHooks(_ event: AIHookEvent) -> Bool {
        event.url.map(service.settings.allowsAI(on:)) ?? true
    }

    /// Whether the feature's hooks may run now. Hooks of a feature that is paused, not automatic, off, or without a usable model of its own skip quietly; hooks of one over a budget skip with that budget as their error, so that its row says so.
    private func mayRun(_ id: AIFeatureID) -> Bool {
        guard !pausedFeatures.contains(id), let feature = service.features.first(where: { $0.id == id }), feature.trigger == .automatic, service.isAvailable(id) else { return false }
        if let budget = service.reachedBudget(for: feature) {
            lastErrors[id] = AIError.budgetReached(budget)
            return false
        }
        return true
    }

    private func recordSuccess(of feature: AIFeatureID) {
        if lastErrors[feature] != nil { lastErrors[feature] = nil }
        failureCounts[feature] = nil
    }

    /// Keeps the error for the feature's row. Consecutive authentication and provider errors pause the feature's hooks, since every further request would fail the same way.
    private func record(_ error: any Error, of feature: AIFeatureID) {
        lastErrors[feature] = error
        switch error as? AIError {
        case .authentication?, .providerUnavailable?:
            let count = (failureCounts[feature] ?? 0) + 1
            failureCounts[feature] = count
            if count >= Self.failuresBeforePause { pausedFeatures.insert(feature) }
        default:
            failureCounts[feature] = nil
        }
    }

    /// Switching a feature off or changing its models stops its running hooks, resumes its paused ones, and clears its last error, which was about the old route.
    private func routesWillChange(to newRoutes: [String: AIRoute]) {
        let changed = Set(registrations.values.map(\.feature)).filter { routes[$0.rawValue] != newRoutes[$0.rawValue] }
        routes = newRoutes
        guard !changed.isEmpty else { return }
        stopRunningHooks { changed.contains($0.feature) }
        for feature in changed {
            resume(feature)
            lastErrors[feature] = nil
        }
    }

    private func stopRunningHooks(where matches: (RunningHook) -> Bool) {
        for chain in chains.values {
            if let running = chain.running, matches(running) { running.task.cancel() }
        }
    }

    private func cancelAll() {
        chains.values.forEach { $0.task?.cancel() }
        chains = [:]
    }
}

/// The client a hook gets: each request goes out under the hook's feature, so a hook uses its own route, data scope, and daily limit.
private struct AIHookClient: AIClient {
    let feature: AIFeatureID
    let base: any AIClient

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        var request = request
        request.feature = feature
        return base.stream(request)
    }
}
