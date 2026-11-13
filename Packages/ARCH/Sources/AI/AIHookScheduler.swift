// The shared hook scheduler (`docs/hooks.md`, The shared scheduler; hook decision 15): the AI hook center, plugin hooks, and the hook registry post their steps for an event here, and the steps of one event run one at a time, in ascending order, in one chain per kind and subject. A newer event of the same kind and subject replaces the chain and starts once the old chain has stopped, never later than its running step's timeout. For steps with an AI feature, the scheduler applies the feature's checks and pauses an owner after consecutive authentication or provider errors. Each owner keeps its other rules.
import Combine
import Foundation

/// One owner's work for one event.
public struct AIHookStep: Sendable {
    /// What failure counts and pauses apply to: the feature ID for the center's hooks, `plugin.<id>` for plugin hooks, `hook.<hook id>` for the registry's.
    public var owner: String
    /// Lower runs earlier; steps of equal order run in the order they were posted. Built-in hooks 100, plugin hooks 200, the registry's hooks 1,000 plus their place in its list.
    public var order: Int
    /// The AI feature the step's requests use, whose checks the scheduler applies; nil for a script hook without `agent`.
    public var feature: AIFeatureID?
    /// The routes in `ai.json` that the step's requests resolve through, such as `hook.tabName` or `tier.fast`. A change to one stops the step while it runs and resumes its owner.
    public var routes: Set<String>
    /// Measured from the event's first post.
    public var delay: Duration
    public var timeout: Duration
    /// The owner's own checks, run after the delay and before the scheduler's.
    public var mayRun: @MainActor @Sendable () -> Bool
    /// The step's work. It reports each AI request's end, nil for a reply, for the failure count.
    public var run: @Sendable (_ requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) async throws -> Void
    /// Gets the step's one end, before the chain's next step starts.
    public var didEnd: @MainActor @Sendable (AIHookStepOutcome) -> Void

    public init(owner: String, order: Int, feature: AIFeatureID?, routes: Set<String> = [], delay: Duration = .zero, timeout: Duration = .seconds(30),
                mayRun: @escaping @MainActor @Sendable () -> Bool = { true },
                run: @escaping @Sendable (_ requestDidEnd: @escaping @MainActor @Sendable ((any Error)?) -> Void) async throws -> Void,
                didEnd: @escaping @MainActor @Sendable (AIHookStepOutcome) -> Void = { _ in }) {
        self.owner = owner
        self.order = order
        self.feature = feature
        self.routes = routes
        self.delay = delay
        self.timeout = timeout
        self.mayRun = mayRun
        self.run = run
        self.didEnd = didEnd
    }
}

/// How a step ended. Every posted step ends exactly once.
public enum AIHookStepOutcome: Sendable {
    /// Its work returned.
    case finished
    /// Its work threw.
    case failed(any Error)
    /// It ran past its timeout, and the scheduler canceled it.
    case timedOut
    /// It was canceled while it ran: its chain was replaced or canceled, its owner was canceled, or one of its routes changed, also after its work returned but before the scheduler took its end.
    case stopped
    /// It never started.
    case skipped(AIHookSkipReason)
}

public enum AIHookSkipReason: Sendable {
    /// Its chain was replaced or canceled, or its owner was canceled, before it started.
    case canceled
    /// The owner's own checks said no.
    case declinedByOwner
    /// Its owner is paused after consecutive authentication or provider errors.
    case paused
    /// An address of its event is excluded from AI.
    case excludedSite
    /// Its feature is not a registered automatic feature that is on and has a usable model of its own.
    case unavailable
    case budgetReached(AIBudget)
}

@MainActor
public final class AIHookScheduler: ObservableObject {
    /// The consecutive authentication or provider errors that pause an owner.
    public static let failuresBeforePause = 3

    /// Owners paused after consecutive authentication or provider errors, until resumed or one of their routes changes. Their steps with a feature skip.
    @Published public private(set) var pausedOwners: Set<String> = []

    private unowned let service: AIService
    private var chains: [ChainKey: Chain] = [:]
    private var failureCounts: [String: Int] = [:]
    /// The routes of each owner's latest steps with a feature, to resume it when one of them changes.
    private var ownerRoutes: [String: Set<String>] = [:]
    /// The routes as last seen, to notice which ones the user changed.
    private var routes: [String: AIRoute]
    private var cancellables: Set<AnyCancellable> = []

    init(service: AIService) {
        self.service = service
        routes = service.settings.routes
        service.settings.$routes
            .sink { [weak self] routes in MainActor.assumeIsolated { self?.routesWillChange(to: routes) } }
            .store(in: &cancellables)
        // The AI module does not link AppKit, so it names the notification. Quitting cancels every chain.
        NotificationCenter.default.publisher(for: Notification.Name("NSApplicationWillTerminateNotification"))
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.cancelAll() } }
            .store(in: &cancellables)
    }

    /// Adds steps to the chain of `kind` and `subject`. Steps posted with the same `event` join one chain in ascending order, whoever posts them; a post with another event replaces the chain, which starts after the old one stops. `document` is the event's address for page events, and `urls` are the addresses that site exclusions apply to. A step with a feature whose event has an excluded address skips at once, and a post left without steps changes no chain.
    public func post(_ steps: [AIHookStep], kind: String, subject: UUID, event: UUID, document: URL?, urls: [URL] = []) {
        let reachesAI = urls.allSatisfy(service.settings.allowsAI(on:))
        var accepted: [AIHookStep] = []
        for step in steps {
            // Only steps with a feature can pause their owner.
            if step.feature != nil { ownerRoutes[step.owner] = step.routes }
            if step.feature != nil && !reachesAI {
                step.didEnd(.skipped(.excludedSite))
            } else {
                accepted.append(step)
            }
        }
        guard !accepted.isEmpty else { return }
        let key = ChainKey(kind: kind, subject: subject)
        if let chain = chains[key], chain.event == event, !chain.isCanceled, !chain.isFinished {
            chain.add(accepted)
            return
        }
        let previous = chains[key]
        previous?.cancel()
        let chain = Chain(event: event, document: document, urls: urls)
        chain.add(accepted)
        chains[key] = chain
        chain.task = Task { [weak self] in
            await previous?.task?.value
            await self?.run(chain)
            chain.isFinished = true
            if self?.chains[key] === chain { self?.chains[key] = nil }
        }
    }

    /// The subject went away: cancels its chains, except the chain of `event`, the close's own.
    public func cancel(subject: UUID, except event: UUID? = nil) {
        for (key, chain) in chains where key.subject == subject && chain.event != event {
            chain.cancel()
        }
    }

    /// The tab committed another document: cancels its chains that have a document other than this one, ignoring the fragment. Chains without a document stay.
    public func cancel(subject: UUID, otherThan document: URL?) {
        let shown = document.map(Self.withoutFragment)
        for (key, chain) in chains where key.subject == subject {
            guard let chainDocument = chain.document, Self.withoutFragment(chainDocument) != shown else { continue }
            chain.cancel()
        }
    }

    /// The owner's hooks went away: its waiting steps skip, and its running steps stop.
    public func cancel(owner: String) {
        for chain in chains.values {
            chain.dropWaiting { $0.owner == owner }
            if let running = chain.running, running.step.owner == owner { running.stop() }
        }
    }

    /// Runs the owner's paused steps again from the next event.
    public func resume(owner: String) {
        pausedOwners.remove(owner)
        failureCounts[owner] = nil
    }

    // MARK: Chains

    private struct ChainKey: Hashable {
        var kind: String
        var subject: UUID
    }

    /// The steps one event runs, one at a time.
    @MainActor
    private final class Chain {
        let event: UUID
        let document: URL?
        let urls: [URL]
        let postedAt = ContinuousClock.now
        /// The steps that have not started, in order.
        private(set) var waiting: [AIHookStep] = []
        var running: RunningStep?
        var task: Task<Void, Never>?
        private(set) var isCanceled = false
        /// Set once the chain has run its last step; a later post for its event starts a new chain.
        var isFinished = false

        init(event: UUID, document: URL?, urls: [URL]) {
            self.event = event
            self.document = document
            self.urls = urls
        }

        /// Inserts each step after the waiting steps of the same or a lower order.
        func add(_ steps: [AIHookStep]) {
            for step in steps {
                let index = waiting.firstIndex { $0.order > step.order } ?? waiting.endIndex
                waiting.insert(step, at: index)
            }
        }

        func takeFirst() -> AIHookStep? {
            waiting.isEmpty ? nil : waiting.removeFirst()
        }

        func dropWaiting(where matches: (AIHookStep) -> Bool) {
            let dropped = waiting.filter(matches)
            waiting.removeAll(where: matches)
            dropped.forEach { $0.didEnd(.skipped(.canceled)) }
        }

        /// Its waiting steps skip, and its running step stops; the chain's task ends once that step has.
        func cancel() {
            guard !isCanceled else { return }
            isCanceled = true
            dropWaiting { _ in true }
            running?.stop()
            task?.cancel()
        }
    }

    /// The step a chain runs, and whether the scheduler stopped it.
    @MainActor
    private final class RunningStep {
        let step: AIHookStep
        let task: Task<Void, any Error>
        /// Set when its chain is canceled or replaced, its owner is canceled, or one of its routes changes, also after its work returned.
        private(set) var isStopped = false

        init(step: AIHookStep, task: Task<Void, any Error>) {
            self.step = step
            self.task = task
        }

        func stop() {
            isStopped = true
            task.cancel()
        }
    }

    /// Runs each step after its delay, once the owner's and the scheduler's checks pass.
    private func run(_ chain: Chain) async {
        while let first = chain.waiting.first {
            do {
                try await Task.sleep(until: chain.postedAt + first.delay, clock: .continuous)
            } catch {
                return
            }
            // A step with an earlier order may have joined during the wait, and waits for its own delay.
            guard let step = chain.waiting.first, ContinuousClock.now >= chain.postedAt + step.delay else { continue }
            _ = chain.takeFirst()
            if let reason = skipReason(for: step, in: chain) {
                step.didEnd(.skipped(reason))
                continue
            }
            let owner = step.owner
            let requestDidEnd: @MainActor @Sendable ((any Error)?) -> Void = { [weak self] error in self?.recordRequest(endingWith: error, of: owner) }
            let task = Task { try await step.run(requestDidEnd) }
            let running = RunningStep(step: step, task: task)
            chain.running = running
            let outcome = await outcome(of: task, timeout: step.timeout)
            chain.running = nil
            step.didEnd(Self.end(outcome, isStopped: running.isStopped))
            if Task.isCancelled { return }
        }
    }

    /// Why the step may not start now, or nil when it may. The owner's checks come first; a step with a feature then needs its owner unpaused, the event's addresses open to AI, a registered automatic feature that is on with a usable model of its own, and room in the daily limit for automatic requests and the monthly spending limit.
    private func skipReason(for step: AIHookStep, in chain: Chain) -> AIHookSkipReason? {
        guard step.mayRun() else { return .declinedByOwner }
        guard let id = step.feature else { return nil }
        if pausedOwners.contains(step.owner) { return .paused }
        guard chain.urls.allSatisfy(service.settings.allowsAI(on:)) else { return .excludedSite }
        guard let feature = service.features.first(where: { $0.id == id }), feature.trigger == .automatic, service.isAvailable(id) else { return .unavailable }
        if let budget = service.reachedBudget(for: feature) { return .budgetReached(budget) }
        return nil
    }

    /// Waits for the step until it returns or its timeout passes, canceling it at the timeout or when the chain is canceled. A canceled chain still waits for its step to stop, so the next event's chain starts after it, but never past the timeout: a step that does not stop when canceled, such as one waiting for a page that does not answer, holds its chain no longer than that. A canceled step's end counts as stopped, even when its work returned, and so does an end that comes after the timeout.
    private func outcome(of task: Task<Void, any Error>, timeout: Duration) async -> AIHookStepOutcome {
        let wait = StepWait()
        // Neither task inherits the chain's cancellation, so both keep watching the step after it.
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            let wasStopped = task.isCancelled
            task.cancel()
            wait.end(wasStopped ? .stopped : .timedOut)
        }
        Task {
            let result = await task.result
            watchdog.cancel()
            if task.isCancelled {
                wait.end(.stopped)
                return
            }
            switch result {
            case .success: wait.end(.finished)
            case .failure(let error): wait.end(.failed(error))
            }
        }
        return await withTaskCancellationHandler { await wait.outcome() } onCancel: { task.cancel() }
    }

    /// A step stopped after its work returned or threw, but before its chain took the end, as when a close or a new document comes in between, counts as stopped.
    private static func end(_ outcome: AIHookStepOutcome, isStopped: Bool) -> AIHookStepOutcome {
        switch outcome {
        case .finished, .failed: return isStopped ? .stopped : outcome
        case .timedOut, .stopped, .skipped: return outcome
        }
    }

    /// The first end of a step that the scheduler takes: its return or its timeout.
    @MainActor
    private final class StepWait {
        private var ended: AIHookStepOutcome?
        private var continuation: CheckedContinuation<AIHookStepOutcome, Never>?

        func end(_ outcome: AIHookStepOutcome) {
            guard ended == nil else { return }
            ended = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        func outcome() async -> AIHookStepOutcome {
            if let ended { return ended }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    // MARK: Failures and routes

    /// Consecutive authentication and provider errors pause the owner, since every further request would fail the same way; any other end of a request starts the count again.
    private func recordRequest(endingWith error: (any Error)?, of owner: String) {
        switch error as? AIError {
        case .authentication?, .providerUnavailable?:
            let count = (failureCounts[owner] ?? 0) + 1
            failureCounts[owner] = count
            if count >= Self.failuresBeforePause { pausedOwners.insert(owner) }
        default:
            failureCounts[owner] = nil
        }
    }

    /// A changed route stops the running steps that use it and resumes the owners whose steps use it.
    private func routesWillChange(to newRoutes: [String: AIRoute]) {
        let changed = Set(routes.keys).union(newRoutes.keys).filter { routes[$0] != newRoutes[$0] }
        routes = newRoutes
        guard !changed.isEmpty else { return }
        for chain in chains.values {
            if let running = chain.running, !running.step.routes.isDisjoint(with: changed) { running.stop() }
        }
        for (owner, used) in ownerRoutes where !used.isDisjoint(with: changed) {
            resume(owner: owner)
        }
    }

    private func cancelAll() {
        chains.values.forEach { $0.cancel() }
        chains = [:]
    }

    private static func withoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.fragment != nil else { return url }
        components.fragment = nil
        return components.url ?? url
    }
}
