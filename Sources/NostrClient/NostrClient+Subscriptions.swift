import Foundation
import NostrCore

// MARK: - Subscriptions
extension NostrClient {
    /// Opens a subscription and returns it as an async sequence of relay-aware events.
    ///
    /// Pass `relayURLs` to scope the subscription to a subset of relays (NIP-65 outbox routing);
    /// the default `nil` subscribes on all relays in the pool.
    ///
    /// Iteration termination (breaking out of the loop, task cancellation, or
    /// discarding the sequence) automatically sends CLOSE to the relays.
    /// - Parameter bufferingPolicy: How items are buffered while the consumer is
    ///   slower than the relays (default: `.unbounded`). Use
    ///   `.bufferingNewest(n)` for firehose subscriptions where memory matters.
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> SubscriptionSequence {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SubscriptionEvent.self,
            bufferingPolicy: bufferingPolicy
        )

        let opened: (id: String, expectedRelays: Set<URL>)
        do {
            opened = try await openSubscription(filters: filters, to: relayURLs) { subscriptionEvent in
                continuation.yield(subscriptionEvent)
            }
        } catch {
            continuation.finish()
            throw error
        }

        // The actor was free during the await above: if the subscription was
        // already torn down (e.g. unsubscribeAll), end the stream immediately.
        if subscriptions[opened.id] != nil {
            subscriptions[opened.id]?.continuation = continuation
        } else {
            continuation.finish()
        }

        let subscriptionId = opened.id
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(subscriptionId: subscriptionId) }
        }

        return SubscriptionSequence(
            id: subscriptionId,
            expectedRelays: opened.expectedRelays,
            stream: stream,
            onClose: { [weak self] in
                await self?.unsubscribe(subscriptionId: subscriptionId)
            }
        )
    }

    /// Opens a subscription and returns only its event payloads as an async sequence.
    ///
    /// ```swift
    /// for await event in try await client.events(filters: [filter]) {
    ///     print(event.content)
    /// }
    /// ```
    public func events(
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> SubscriptionSequence.Events {
        try await subscribe(filters: filters, to: relayURLs, bufferingPolicy: bufferingPolicy).events
    }

    /// Registers a subscription with the relay pool and routes its messages to `handler`.
    /// Backs the stream-based ``subscribe(filters:to:bufferingPolicy:)``.
    func openSubscription(
        filters: [Filter],
        to relayURLs: Set<URL>?,
        handler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> (id: String, expectedRelays: Set<URL>) {
        subscriptionCounter += 1
        let subscriptionId = "sub_\(subscriptionCounter)"

        subscriptions[subscriptionId] = SubscriptionState(
            id: subscriptionId,
            filters: filters,
            handler: handler
        )

        do {
            let expectedRelayURLs = try await relayPool.subscribeWithRelayContext(
                subscriptionId: subscriptionId,
                filters: filters,
                to: relayURLs
            ) { [weak self] relayMessage in
                guard let self else { return }
                await self.handleMessage(
                    relayMessage.message,
                    from: relayMessage.relayURL,
                    subscriptionId: subscriptionId
                )
            }
            return (subscriptionId, expectedRelayURLs)
        } catch {
            subscriptions.removeValue(forKey: subscriptionId)
            // Drop the pool-side handler and message tasks registered before the failure.
            await relayPool.unsubscribe(subscriptionId: subscriptionId)
            throw error
        }
    }

    /// Unsubscribes from a subscription.
    /// No-op for unknown IDs, so the re-entrant call triggered by finishing the
    /// continuation (onTermination → unsubscribe) cannot send a second CLOSE.
    public func unsubscribe(subscriptionId: String) async {
        guard let subscription = subscriptions.removeValue(forKey: subscriptionId) else { return }
        subscription.continuation?.finish()
        await relayPool.unsubscribe(subscriptionId: subscriptionId)
    }

    /// Unsubscribes from all subscriptions
    public func unsubscribeAll() async {
        let active = subscriptions
        subscriptions.removeAll()
        for (subscriptionId, subscription) in active {
            subscription.continuation?.finish()
            await relayPool.unsubscribe(subscriptionId: subscriptionId)
        }
    }

    // MARK: - Convenience Subscriptions

    /// Subscribes to a user's timeline
    public func subscribeToUserTimeline(
        pubkey: String,
        limit: Int = 100
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.userNotes(pubkey: pubkey, limit: limit)])
    }

    /// Subscribes to the global feed
    public func subscribeToGlobalFeed(
        limit: Int = 100
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.globalFeed(limit: limit)])
    }

    /// Subscribes to mentions of a user
    public func subscribeToMentions(
        pubkey: String,
        limit: Int = 100
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.mentions(pubkey: pubkey, limit: limit)])
    }

    /// Subscribes to metadata updates for a list of pubkeys
    public func subscribeToMetadata(
        pubkeys: [String]
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.metadata(pubkeys: pubkeys)])
    }

    private func handleMessage(_ message: RelayMessage, from relayURL: URL, subscriptionId: String) {
        guard let subscription = subscriptions[subscriptionId] else { return }

        switch message {
        case .event(_, let event):
            // Note: Deduplication is now handled at the RelayPool level
            subscription.handler(.event(relayURL: relayURL, event: event))

        case .endOfStoredEvents:
            subscription.handler(.eose(relayURL: relayURL))

        case .closed(_, let message):
            subscription.handler(.closed(relayURL: relayURL, message: message))

        case .notice(let message):
            subscription.handler(.notice(relayURL: relayURL, message: message))

        case .auth(let challenge):
            subscription.handler(.auth(relayURL: relayURL, challenge: challenge))

        default:
            break
        }
    }

    /// The number of currently registered subscriptions (for tests).
    var activeSubscriptionCount: Int {
        subscriptions.count
    }
}

/// Per-subscription state held by ``NostrClient``.
///
/// `internal` (not `private`) because ``NostrClient``'s `subscriptions` storage and the
/// subscribe/unsubscribe logic now live in separate files. The continuation is
/// `fileprivate(set)` so only this file — where the subscribe/unsubscribe logic lives —
/// can wire or clear it; other module files can read it but not reassign it.
/// (`private(set)` would be too strict here: the assignment happens in `NostrClient`'s
/// extension, a different type scope, even though it is in this same file.)
struct SubscriptionState: Sendable {
    let id: String
    let filters: [Filter]
    let handler: @Sendable (SubscriptionEvent) -> Void

    /// Continuation of the stream backing a ``SubscriptionSequence``;
    /// finished on unsubscribe so iteration ends. Briefly `nil` between the subscription being
    /// registered and the stream being wired up.
    fileprivate(set) var continuation: AsyncStream<SubscriptionEvent>.Continuation?

    init(id: String, filters: [Filter], handler: @escaping @Sendable (SubscriptionEvent) -> Void) {
        self.id = id
        self.filters = filters
        self.handler = handler
    }
}
