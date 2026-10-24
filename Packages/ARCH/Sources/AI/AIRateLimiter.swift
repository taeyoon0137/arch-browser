// One rate limiter per provider: a number of concurrent slots, an optional requests-per-minute bucket, and a cool-down after the provider answers 429. Requests the user starts take free slots before automatic ones.
import Foundation

actor AIRateLimiter {
    private struct Waiter {
        var id: UUID
        var isUser: Bool
        var continuation: CheckedContinuation<Void, any Error>
    }

    let provider: AIProviderID
    private var limits: AIProviderLimits
    /// An automatic request gives up after waiting this long.
    private let automaticWaitLimit: Duration
    private let initialBackoff: Duration
    private let maximumBackoff: Duration

    private var slotsInUse = 0
    private var waiters: [Waiter] = []
    private var recentStarts: [ContinuousClock.Instant] = []
    private(set) var coolDownUntil: Date?
    private var backoff: Duration

    init(provider: AIProviderID, limits: AIProviderLimits, automaticWaitLimit: Duration = .seconds(30), initialBackoff: Duration = .seconds(20), maximumBackoff: Duration = .seconds(300)) {
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

    /// Waits for a slot, then for any cool-down and the per-minute bucket, reporting each wait through `onWait`. Every successful call must be balanced by `release()`. A user request waits until it is cancelled; an automatic one throws `rateLimited` after the wait limit.
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
            recentStarts.append(.now)
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

    /// Starts a cool-down after a 429: until `retryAfter`, or for 20 seconds doubling up to 5 minutes when the provider sent no time. Returns the end of the cool-down.
    @discardableResult
    func coolDown(retryAfter: Date?) -> Date {
        let until: Date
        if let retryAfter {
            until = retryAfter
        } else {
            until = Date() + backoff.timeInterval
            backoff = min(backoff * 2, maximumBackoff)
        }
        coolDownUntil = max(coolDownUntil ?? until, until)
        return coolDownUntil ?? until
    }

    /// A request the provider answered resets the doubling.
    func recordSuccess() {
        backoff = initialBackoff
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

    private func expireWaiter(_ id: UUID) {
        removeWaiter(id, throwing: AIError.rateLimited(provider, until: coolDownUntil))
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
