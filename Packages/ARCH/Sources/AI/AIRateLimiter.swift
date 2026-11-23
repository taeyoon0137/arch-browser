// One rate limiter per provider: a number of concurrent slots, an optional requests-per-minute bucket, and a cool-down after the provider answers 429. Requests the user starts take free slots before automatic ones.
import Foundation

/// Holds the slots, the per-minute bucket, and the cool-down of one provider, which each request waits on before it is sent.
actor AIRateLimiter {
    /// How a request that held a slot ended, for `release(after:)`.
    enum Outcome {
        /// The provider answered, which resets the doubling.
        case answered
        /// The provider answered 429, with the time its `retry-after` header gave, if any.
        case rateLimited(retryAfter: Date?)
        /// The request ended another way, such as an error or cancellation, which leaves the cool-down as it is.
        case other
    }

    /// A request waiting for a slot, and whether the user started it.
    private struct Waiter {
        var id: UUID
        var isUser: Bool
        var continuation: CheckedContinuation<Void, any Error>
    }

    let provider: AIProviderID
    private var limits: AIProviderLimits
    /// An automatic request gives up after waiting this long. The default is half of a hook's default timeout, so a hook's request that gives up still has time for the route's next model.
    private let automaticWaitLimit: Duration
    private let initialBackoff: Duration
    private let maximumBackoff: Duration

    private var slotsInUse = 0
    private var waiters: [Waiter] = []
    private var recentStarts: [ContinuousClock.Instant] = []
    private(set) var coolDownUntil: Date?
    /// Latest reset reported by the provider. The local backoff and per-minute bucket only schedule requests.
    private(set) var providerReset: Date?
    private var backoff: Duration

    init(provider: AIProviderID, limits: AIProviderLimits, automaticWaitLimit: Duration = .seconds(15), initialBackoff: Duration = .seconds(20), maximumBackoff: Duration = .seconds(300)) {
        self.provider = provider
        self.limits = limits
        self.automaticWaitLimit = automaticWaitLimit
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        backoff = initialBackoff
    }

    /// Picks up limits the user changed; slots already taken stay taken.
    func update(_ limits: AIProviderLimits) {
        self.limits = limits
        handOverFreeSlots()
    }

    /// Waits for a slot, then for any cool-down and the per-minute bucket, reporting each wait through `onWait`. Every successful call must be balanced by `release(after:)` or `release()`. A user request waits until it is cancelled; an automatic one throws `rateLimited` after the wait limit.
    func acquire(isUser: Bool, onWait: @Sendable (AIWaitReason) -> Void) async throws {
        let deadline: ContinuousClock.Instant? = isUser ? nil : .now + automaticWaitLimit
        if slotsInUse < max(limits.concurrentRequests, 1), isUser || !waiters.contains(where: \.isUser) {
            slotsInUse += 1
        } else {
            onWait(.queued)
            try await waitForSlot(isUser: isUser, deadline: deadline)
        }
        do {
            while let until = blockedUntil() {
                onWait(.rateLimited(until: until))
                let wake = ContinuousClock.now + .seconds(max(until.timeIntervalSinceNow, 0))
                if let deadline, wake > deadline {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw AIError.rateLimited(provider, until: until)
                }
                try await Task.sleep(until: wake, clock: .continuous)
            }
            // Starts are kept only for a per-minute bucket, which prunes them.
            if let perMinute = limits.requestsPerMinute, perMinute > 0 { recentStarts.append(.now) }
        } catch {
            release()
            throw error
        }
    }

    /// Frees a slot, handing it to the longest-waiting user request, or else the longest-waiting automatic one.
    func release() {
        slotsInUse -= 1
        handOverFreeSlots()
    }

    /// Frees the slot of a request that ended as `outcome`. A 429 starts its cool-down before the slot goes to a waiting request, so that request waits for the cool-down too. Returns the end of the cool-down after a 429, and nil otherwise.
    @discardableResult
    func release(after outcome: Outcome) -> Date? {
        var until: Date?
        switch outcome {
        case .answered: backoff = initialBackoff
        case .rateLimited(let retryAfter): until = coolDown(retryAfter: retryAfter)
        case .other: break
        }
        release()
        return until
    }

    /// Starts a cool-down after a 429: until `retryAfter`, or for 20 seconds doubling up to 5 minutes when the provider sent no time. A 429 without a time during a cool-down belongs to the requests that were already running when it started, so it keeps that cool-down and does not double it. Returns the end of the cool-down.
    private func coolDown(retryAfter: Date?) -> Date {
        let until: Date
        if let retryAfter {
            providerReset = max(providerReset ?? retryAfter, retryAfter)
            until = retryAfter
        } else if let current = coolDownUntil, current > Date() {
            until = current
        } else {
            until = Date() + backoff.timeInterval
            backoff = min(backoff * 2, maximumBackoff)
        }
        coolDownUntil = max(coolDownUntil ?? until, until)
        return coolDownUntil ?? until
    }

    /// When the cool-down or the per-minute bucket next lets a request start, or nil if one can start now.
    private func blockedUntil() -> Date? {
        if let until = coolDownUntil, until > Date() { return until }
        guard let perMinute = limits.requestsPerMinute, perMinute > 0 else { return nil }
        let windowStart = ContinuousClock.now - .seconds(60)
        recentStarts.removeAll { $0 < windowStart }
        guard recentStarts.count >= perMinute, let oldest = recentStarts.first else { return nil }
        return Date() + (oldest - windowStart).timeInterval
    }

    private func waitForSlot(isUser: Bool, deadline: ContinuousClock.Instant?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, isUser: isUser, continuation: continuation))
                if let deadline {
                    Task { [weak self] in
                        try? await Task.sleep(until: deadline, clock: .continuous)
                        await self?.expireWaiter(id)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.removeWaiter(id, throwing: CancellationError()) }
        }
    }

    /// Ends an automatic request's wait for a slot. It carries the cool-down only while one lasts, since one that has ended would read as a short cool-down that the same model can wait out.
    private func expireWaiter(_ id: UUID) {
        removeWaiter(id, throwing: AIError.rateLimited(provider, until: coolDownUntil.flatMap { $0 > Date() ? $0 : nil }))
    }

    private func removeWaiter(_ id: UUID, throwing error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: error)
    }

    private func handOverFreeSlots() {
        while slotsInUse < max(limits.concurrentRequests, 1), !waiters.isEmpty {
            let index = waiters.firstIndex(where: \.isUser) ?? 0
            slotsInUse += 1
            waiters.remove(at: index).continuation.resume()
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
