import Foundation
import NostrCore

/// Live subscriptions delivered as async sequences.
/// Reached as ``NostrClient/subscriptions``.
///
/// Implements the ``NostrSubscribing`` primitives; ``NostrSubscribing/events(filters:bufferingPolicy:)``,
/// the feeds (``NostrSubscribing/userTimeline(publicKey:limit:)``, …), and the short forms of
/// ``subscribe(filters:to:bufferingPolicy:)`` come from the protocol's extension.
///
/// Iteration termination — breaking out of the loop, task cancellation, or discarding the
/// sequence — sends CLOSE to the relays, so most call sites never need ``unsubscribe(subscriptionID:)``.
/// For a one-time read that ends at EOSE use
/// ``NostrEventFetching/fetch(filters:from:timeout:)-(_,Set<RelayURL>?,_)`` instead.
public struct NostrSubscriptionsAPI: NostrSubscribing {
    let client: NostrClient

    /// Opens a subscription on the whole pool (nil) or the given relays, as an async sequence of
    /// relay-aware events.
    ///
    /// Pass relay URLs to scope the subscription to a subset of relays (NIP-65 outbox routing).
    /// Targets not in the pool are skipped; an empty set always throws.
    ///
    /// Iteration termination (breaking out of the loop, task cancellation, or
    /// discarding the sequence) automatically sends CLOSE to the relays.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - relayURLs: The relays to subscribe on, or nil for the whole pool.
    ///   - bufferingPolicy: How items are buffered while the consumer is slower than the relays.
    ///     Use `.bufferingNewest(n)` for firehose subscriptions where memory matters.
    /// - Returns: The subscription.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty,
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, or ``RelayPool/Error/subscriptionFailed`` when every relay fails to subscribe.
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<RelayURL>?,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy
    ) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await client.subscribe(
            filters: filters,
            toURLs: relayURLs,
            bufferingPolicy: bufferingPolicy
        )
    }

    /// Closes one subscription.
    /// No-op for unknown IDs, so the re-entrant call triggered by ending iteration
    /// cannot send a second CLOSE.
    public func unsubscribe(subscriptionID: String) async {
        await client.closeSubscription(id: subscriptionID)
    }

    /// Closes every open subscription.
    public func unsubscribeAll() async {
        await client.closeAllSubscriptions()
    }
}
