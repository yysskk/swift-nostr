import NostrCore

/// An async sequence backed by one live relay subscription (REQ).
///
/// ``SubscriptionSequence``, its ``SubscriptionSequence/events`` view, ``DirectMessagePayloadSequence``,
/// and ``DirectMessageSequence`` all conform, so code that tracks or tears down subscriptions can
/// treat them alike:
///
/// ```swift
/// var subscriptions: [any RelaySubscription] = []
/// subscriptions.append(try await client.subscriptions.subscribe(filters: [filter]))
/// subscriptions.append(try await client.messages.subscribe())
///
/// for subscription in subscriptions {
///     await subscription.close()
/// }
/// ```
///
/// A conforming sequence sends CLOSE to the relays when iteration stops, the consuming task is
/// cancelled, ``close()`` is called, or the sequence is discarded without being consumed.
///
/// - Important: Every conforming sequence is single-consumer: create one iterator per
///   subscription, on the sequence or on one of its views, not more. Multiple iterators race for
///   elements.
public protocol RelaySubscription: AsyncSequence, Sendable {
    /// The id the pool generated for the subscription, usable with
    /// ``NostrSubscriptionsAPI/unsubscribe(id:)``.
    var id: SubscriptionID { get }

    /// The relays that accepted the REQ. EOSE completion is measured against this set (see
    /// ``NostrEventFetching/fetch(filters:route:timeout:)``).
    var expectedRelays: Set<RelayURL> { get }

    /// Closes the subscription: sends CLOSE to the relays and ends iteration.
    ///
    /// Calling it more than once is harmless.
    func close() async
}
