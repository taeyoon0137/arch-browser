// The browser event bus (`docs/hooks.md`, The bus; hook decision 1): one bus per session delivers every browser event to its subscribers, in sequence order, on the main actor.
import Foundation

/// Delivers browser events in sequence on the main actor to matching subscribers.
@MainActor
public final class BrowserEventBus {
    /// A subscription: its identifier, its filter, and the handler that matching events reach.
    private struct Subscriber {
        let id: UUID
        let filter: BrowserEventFilter
        let handler: @MainActor (BrowserEvent) -> Void
    }

    private var subscribers: [Subscriber] = []
    private var lastSequence: UInt64 = 0
    /// The causes of the enclosing `withCause` blocks, innermost last.
    private var causes: [BrowserEventCause] = []
    /// Events posted during a delivery, which wait until the event being delivered has reached every subscriber.
    private var pending: [BrowserEvent] = []
    private var isDelivering = false

    public nonisolated init() {}

    /// The cause of the innermost enclosing `withCause` block, which code that starts a change finishing later, such as a navigation, keeps for its events.
    public var currentCause: BrowserEventCause? { causes.last }

    /// Gives the event its identifier, sequence, date, and the cause of the enclosing `withCause` block when it has none, then delivers it to every subscriber whose filter matches, in subscription order, before returning. A post from a handler is delivered once the current event has reached every subscriber, so every subscriber sees events in sequence order.
    public func post(_ payload: BrowserEventPayload, cause: BrowserEventCause? = nil) {
        lastSequence += 1
        pending.append(BrowserEvent(id: UUID(), sequence: lastSequence, date: Date(), payload: payload, cause: cause ?? currentCause))
        guard !isDelivering else { return }
        isDelivering = true
        defer { isDelivering = false }
        while !pending.isEmpty {
            let event = pending.removeFirst()
            for subscriber in subscribers where subscriber.filter.matches(event) {
                // A handler may end a later subscription during this delivery.
                guard subscribers.contains(where: { $0.id == subscriber.id }) else { continue }
                subscriber.handler(event)
            }
        }
    }

    /// Handlers run immediately on the main actor and must not wait: each consumer queues its own work. The subscription lasts until it is canceled.
    @discardableResult
    public func subscribe(_ filter: BrowserEventFilter, _ handler: @escaping @MainActor (BrowserEvent) -> Void) -> BrowserEventSubscription {
        let id = UUID()
        subscribers.append(Subscriber(id: id, filter: filter, handler: handler))
        return BrowserEventSubscription(bus: self, id: id)
    }

    fileprivate func unsubscribe(_ id: UUID) {
        subscribers.removeAll { $0.id == id }
    }

    /// Attaches `cause` to every event that `body`'s changes post before it returns.
    public func withCause<T>(_ cause: BrowserEventCause, _ body: () throws -> T) rethrows -> T {
        causes.append(cause)
        defer { causes.removeLast() }
        return try body()
    }
}

/// A handle that ends one browser event subscription when canceled.
@MainActor
public final class BrowserEventSubscription {
    private weak var bus: BrowserEventBus?
    private let id: UUID

    fileprivate init(bus: BrowserEventBus, id: UUID) {
        self.bus = bus
        self.id = id
    }

    public func cancel() {
        bus?.unsubscribe(id)
    }
}
