import Foundation
import NostrCore

// MARK: - Subscriptions — actor-isolated internals
//
// The public surface lives on ``NostrSubscriptionsAPI``. Registering and tearing down a
// subscription mutates ``subscriptionCounter`` and ``openSubscriptions``, so unlike the other
// feature areas the work itself stays on the actor and the façade only forwards.
extension NostrClient {
    /// Opens a subscription and returns it as an async sequence of relay-aware events, taking
    /// pre-validated canonical URLs; nil subscribes on the whole pool.
    ///
    /// Backs ``NostrSubscriptionsAPI/subscribe(filters:to:bufferingPolicy:)``.
    func subscribe(
        filters: [Filter],
        toURLs relayURLs: Set<URL>?,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> SubscriptionSequence {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SubscriptionEvent.self,
            bufferingPolicy: bufferingPolicy
        )

        let opened: (id: String, expectedRelays: Set<URL>)
        do {
            opened = try await openSubscription(filters: filters, toURLs: relayURLs) { subscriptionEvent in
                continuation.yield(subscriptionEvent)
            }
        } catch {
            continuation.finish()
            throw error
        }

        // The actor was free during the await above: if the subscription was
        // already torn down (e.g. closeAllSubscriptions), end the stream immediately.
        if openSubscriptions[opened.id] != nil {
            openSubscriptions[opened.id]?.continuation = continuation
        } else {
            continuation.finish()
        }

        let subscriptionId = opened.id
        continuation.onTermination = { [weak self] _ in
            Task { await self?.closeSubscription(id: subscriptionId) }
        }

        return SubscriptionSequence(
            id: subscriptionId,
            expectedRelays: opened.expectedRelays,
            stream: stream,
            onClose: { [weak self] in
                await self?.closeSubscription(id: subscriptionId)
            }
        )
    }

    /// Registers a subscription with the relay pool and routes its messages to `handler`.
    /// Backs the stream-based ``subscribe(filters:toURLs:bufferingPolicy:)``.
    func openSubscription(
        filters: [Filter],
        toURLs relayURLs: Set<URL>?,
        handler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> (id: String, expectedRelays: Set<URL>) {
        subscriptionCounter += 1
        let subscriptionId = "sub_\(subscriptionCounter)"

        openSubscriptions[subscriptionId] = SubscriptionState(
            id: subscriptionId,
            filters: filters,
            handler: handler
        )

        do {
            let expectedRelayURLs = try await pool.subscribeWithRelayContext(
                subscriptionId: subscriptionId,
                filters: filters,
                toURLs: relayURLs
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
            openSubscriptions.removeValue(forKey: subscriptionId)
            // Drop the pool-side handler and message tasks registered before the failure.
            await pool.unsubscribe(subscriptionId: subscriptionId)
            throw error
        }
    }

    /// Closes one subscription.
    /// No-op for unknown IDs, so the re-entrant call triggered by finishing the
    /// continuation (onTermination → close) cannot send a second CLOSE.
    ///
    /// Backs ``NostrSubscriptionsAPI/unsubscribe(subscriptionId:)``.
    func closeSubscription(id subscriptionId: String) async {
        guard let subscription = openSubscriptions.removeValue(forKey: subscriptionId) else { return }
        subscription.continuation?.finish()
        await pool.unsubscribe(subscriptionId: subscriptionId)
    }

    /// Closes every open subscription.
    /// Backs ``NostrSubscriptionsAPI/unsubscribeAll()``.
    func closeAllSubscriptions() async {
        let active = openSubscriptions
        openSubscriptions.removeAll()
        for (subscriptionId, subscription) in active {
            subscription.continuation?.finish()
            await pool.unsubscribe(subscriptionId: subscriptionId)
        }
    }

    /// Ends every subscription and then disconnects every relay.
    ///
    /// Disconnecting drops the pool's listener tasks, and nothing recreates them, so a subscription
    /// cannot outlive it — the sequences are finished here rather than left waiting on a delivery
    /// that can no longer arrive. Ending them is this layer's job: the pool has no reach into the
    /// client's ``SubscriptionSequence`` continuations, and reversing that would invert the
    /// dependency between them.
    ///
    /// Backs ``NostrRelaysAPI/disconnect()``.
    func disconnectAllRelays() async {
        // Finishes the client-facing sequences and sends CLOSE for each subscription while the
        // connections are still up.
        await closeAllSubscriptions()
        await pool.disconnectAll()
    }

    private func handleMessage(_ message: RelayMessage, from relayURL: URL, subscriptionId: String) {
        guard let subscription = openSubscriptions[subscriptionId] else { return }

        switch message {
        case .event(_, let event):
            // Note: Deduplication is handled at the RelayPool level, per subscription
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
        openSubscriptions.count
    }
}

/// Per-subscription state held by ``NostrClient``.
///
/// `internal` (not `private`) because ``NostrClient``'s `openSubscriptions` storage and the
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
