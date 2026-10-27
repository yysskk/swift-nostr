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

// MARK: - Conveniences

extension NostrSubscribing {
    /// Opens a subscription on the whole pool and returns only its event payloads as an async
    /// sequence.
    ///
    /// ```swift
    /// for await event in try await client.subscriptions.events(filters: [filter]) {
    ///     print(event.content)
    /// }
    /// ```
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - bufferingPolicy: How items are buffered while the consumer is slower than the relays
    ///     (default: `.unbounded`).
    /// - Returns: The subscription's event payloads.
    /// - Throws: ``RelayPool/Error/emptyPool`` or ``RelayPool/Error/subscriptionFailed`` — see
    ///   ``NostrSubscribing/subscribe(filters:bufferingPolicy:)``.
    public func events(
        filters: [Filter],
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws(RelayPool.Error) -> SubscriptionSequence.Events {
        try await subscribe(filters: filters, bufferingPolicy: bufferingPolicy).events
    }

    /// Opens a subscription on the given relays only and returns only its event payloads as an
    /// async sequence.
    ///
    /// Targets not in the pool are skipped; an empty set always throws.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - relayURLs: The relays to subscribe on.
    ///   - bufferingPolicy: How items are buffered while the consumer is slower than the relays
    ///     (default: `.unbounded`).
    /// - Returns: The subscription's event payloads.
    /// - Throws: ``RelayPool/Error/noMatchingRelays(_:)`` or ``RelayPool/Error/subscriptionFailed`` — see
    ///   ``NostrSubscribing/subscribe(filters:to:bufferingPolicy:)-(_,Set<RelayURL>,_)``.
    public func events(
        filters: [Filter],
        to relayURLs: Set<RelayURL>,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws(RelayPool.Error) -> SubscriptionSequence.Events {
        try await subscribe(filters: filters, to: relayURLs, bufferingPolicy: bufferingPolicy).events
    }

    /// Subscribes to a user's text notes (kind 1) on the whole pool.
    /// - Parameters:
    ///   - publicKey: The user whose notes to follow.
    ///   - limit: How many stored notes each relay sends before live ones.
    /// - Returns: The subscription.
    public func userTimeline(
        publicKey: PublicKey,
        limit: Int = 100
    ) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await subscribe(filters: [.userNotes(publicKey: publicKey, limit: limit)])
    }

    /// Subscribes to every text note (kind 1) on the whole pool.
    /// - Parameter limit: How many stored notes each relay sends before live ones.
    /// - Returns: The subscription.
    public func globalFeed(limit: Int = 100) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await subscribe(filters: [.globalFeed(limit: limit)])
    }

    /// Subscribes to text notes (kind 1) that mention a user, on the whole pool.
    /// - Parameters:
    ///   - publicKey: The user whose mentions to follow.
    ///   - limit: How many stored notes each relay sends before live ones.
    /// - Returns: The subscription.
    public func mentions(publicKey: PublicKey, limit: Int = 100) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await subscribe(filters: [.mentions(publicKey: publicKey, limit: limit)])
    }

    /// Subscribes to metadata (kind 0) updates for a list of public keys, on the whole pool.
    /// - Parameter publicKeys: The users whose profiles to follow.
    /// - Returns: The subscription.
    public func metadata(publicKeys: [PublicKey]) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await subscribe(filters: [.metadata(publicKeys: publicKeys)])
    }
}
