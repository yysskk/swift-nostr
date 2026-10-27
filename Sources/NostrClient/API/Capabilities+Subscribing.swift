import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrSubscribing {
    /// Opens a subscription along `route` with unbounded buffering, as an async sequence of
    /// relay-aware events. See ``NostrSubscribing/subscribe(filters:route:bufferingPolicy:)``.
    ///
    /// Iteration termination (breaking out of the loop, task cancellation, or discarding the
    /// sequence) sends CLOSE to the relays.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - route: The relays to subscribe on (default: the whole pool).
    /// - Returns: The subscription.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty,
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of a ``RelayRoute/relays(_:)`` route's URLs
    ///   are in the pool, or ``RelayPool/Error/subscriptionFailed`` when every relay fails to subscribe.
    public func subscribe(
        filters: [Filter],
        route: RelayRoute = .pool
    ) async throws(RelayPool.Error) -> SubscriptionSequence {
        try await subscribe(filters: filters, route: route, bufferingPolicy: .unbounded)
    }
}
