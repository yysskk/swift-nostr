import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrSubscriptionsAPI`` that implements only the ``NostrSubscribing``
/// primitives: it records every call and answers each subscribe with a finished sequence of canned
/// items, so the protocol extension can be exercised without a relay pool.
///
/// Targeting mimics a pool holding `pooledRelays`: a `.relays` subscribe none of whose relays
/// is pooled (an empty set included) throws ``RelayPool/Error/noMatchingRelays(_:)`` after it is recorded.
actor RecordingSubscriptionCapabilities: NostrSubscribing {
    struct Subscribe: Sendable {
        let filters: [Filter]
        let route: RelayRoute
        let bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy
    }

    /// The relays a `.relays` subscribe may reach; nil accepts any non-empty target set.
    let pooledRelays: Set<RelayURL>?
    /// What every subscription yields before it finishes.
    let cannedItems: [SubscriptionEvent]

    private(set) var subscribes: [Subscribe] = []
    private(set) var unsubscribedIDs: [SubscriptionID] = []
    private(set) var unsubscribeAllCount = 0

    init(pooledRelays: Set<RelayURL>? = nil, cannedItems: [SubscriptionEvent] = []) {
        self.pooledRelays = pooledRelays
        self.cannedItems = cannedItems
    }

    // MARK: - NostrSubscribing

    func subscribe(
        filters: [Filter],
        route: RelayRoute,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy
    ) async throws(RelayPool.Error) -> SubscriptionSequence {
        subscribes.append(Subscribe(filters: filters, route: route, bufferingPolicy: bufferingPolicy))
        try checkTargets(route)

        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        for item in cannedItems {
            continuation.yield(item)
        }
        continuation.finish()
        return SubscriptionSequence(
            id: SubscriptionID(rawValue: "stub_\(subscribes.count)"),
            expectedRelays: expectedRelays(for: route),
            stream: stream,
            onClose: {}
        )
    }

    func unsubscribe(id: SubscriptionID) async {
        unsubscribedIDs.append(id)
    }

    func unsubscribeAll() async {
        unsubscribeAllCount += 1
    }

    // MARK: - Private

    private func expectedRelays(for route: RelayRoute) -> Set<RelayURL> {
        if case .relays(let relayURLs) = route { return relayURLs }
        return pooledRelays ?? []
    }

    private func checkTargets(_ route: RelayRoute) throws(RelayPool.Error) {
        guard case .relays(let relayURLs) = route else { return }
        let reachable = pooledRelays.map { relayURLs.intersection($0) } ?? relayURLs
        guard !reachable.isEmpty else {
            throw .noMatchingRelays(relayURLs.sorted { $0.description < $1.description })
        }
    }
}
