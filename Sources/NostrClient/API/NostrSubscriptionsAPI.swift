import Foundation
import NostrCore

/// Live subscriptions delivered as async sequences.
/// Reached as ``NostrClient/subscriptions``.
///
/// Iteration termination — breaking out of the loop, task cancellation, or discarding the
/// sequence — sends CLOSE to the relays, so most call sites never need ``unsubscribe(subscriptionID:)``.
/// For a one-time read that ends at EOSE use
/// ``NostrEventFetching/fetch(filters:from:timeout:)-(_,Set<RelayURL>?,_)`` instead.
public struct NostrSubscriptionsAPI: NostrSubscribing {
    let client: NostrClient

    /// Opens a subscription and returns it as an async sequence of relay-aware events.
    ///
    /// Pass relay URLs to scope the subscription to a subset of relays (NIP-65 outbox
    /// routing); the default `nil` subscribes on all relays in the pool. Targets not in the
    /// pool are skipped; an empty set always throws.
    ///
    /// Iteration termination (breaking out of the loop, task cancellation, or
    /// discarding the sequence) automatically sends CLOSE to the relays.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - relayURLs: The relays to subscribe on, or nil (the default) for the whole pool.
    ///   - bufferingPolicy: How items are buffered while the consumer is
    ///     slower than the relays (default: `.unbounded`). Use
    ///     `.bufferingNewest(n)` for firehose subscriptions where memory matters.
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty,
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, or ``NostrError/relayError(_:)`` when every relay fails to subscribe.
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<RelayURL>? = nil,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> SubscriptionSequence {
        try await client.subscribe(
            filters: filters,
            toURLs: relayURLs,
            bufferingPolicy: bufferingPolicy
        )
    }

    /// Opens a subscription and returns only its event payloads as an async sequence.
    ///
    /// ```swift
    /// for await event in try await client.subscriptions.events(filters: [filter]) {
    ///     print(event.content)
    /// }
    /// ```
    /// - Throws: ``NostrError/noRelaysInPool``, ``NostrError/noMatchingRelays(_:)``, or
    ///   ``NostrError/relayError(_:)`` — see
    ///   ``subscribe(filters:to:bufferingPolicy:)``.
    public func events(
        filters: [Filter],
        to relayURLs: Set<RelayURL>? = nil,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> SubscriptionSequence.Events {
        try await subscribe(filters: filters, to: relayURLs, bufferingPolicy: bufferingPolicy).events
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

    // MARK: - Convenience subscriptions

    /// Subscribes to a user's timeline.
    public func userTimeline(publicKey: PublicKey, limit: Int = 100) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.userNotes(publicKey: publicKey, limit: limit)])
    }

    /// Subscribes to the global feed.
    public func globalFeed(limit: Int = 100) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.globalFeed(limit: limit)])
    }

    /// Subscribes to mentions of a user.
    public func mentions(publicKey: PublicKey, limit: Int = 100) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.mentions(publicKey: publicKey, limit: limit)])
    }

    /// Subscribes to metadata updates for a list of public keys.
    public func metadata(publicKeys: [PublicKey]) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.metadata(publicKeys: publicKeys)])
    }
}
