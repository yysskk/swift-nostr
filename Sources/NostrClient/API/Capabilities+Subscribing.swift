import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrSubscribing {
    /// Opens a subscription on the whole pool, as an async sequence of relay-aware events.
    ///
    /// Iteration termination (breaking out of the loop, task cancellation, or discarding the
    /// sequence) sends CLOSE to the relays.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - bufferingPolicy: How items are buffered while the consumer is slower than the relays
    ///     (default: `.unbounded`). Use `.bufferingNewest(n)` for firehose subscriptions where memory
    ///     matters.
    /// - Returns: The subscription.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty, or
    ///   ``RelayPool/Error/subscriptionFailed`` when every relay fails to subscribe.
    public func subscribe(
        filters: [Filter],
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await subscribe(filters: filters, to: nil, bufferingPolicy: bufferingPolicy)
    }

    /// Opens a subscription on the given relays only — for example, an author's NIP-65 write relays —
    /// as an async sequence of relay-aware events.
    ///
    /// Targets not in the pool are skipped; an empty set always throws.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - relayURLs: The relays to subscribe on.
    ///   - bufferingPolicy: How items are buffered while the consumer is slower than the relays
    ///     (default: `.unbounded`).
    /// - Returns: The subscription.
    /// - Throws: ``RelayPool/Error/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, or ``RelayPool/Error/subscriptionFailed`` when every targeted relay fails to subscribe.
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<RelayURL>,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await subscribe(filters: filters, to: Optional(relayURLs), bufferingPolicy: bufferingPolicy)
    }
}
