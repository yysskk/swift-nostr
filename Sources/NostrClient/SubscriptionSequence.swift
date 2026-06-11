import Foundation

/// A live relay subscription delivered as an async sequence of relay-aware events.
///
/// Returned by ``NostrClient/subscribe(filters:to:bufferingPolicy:)`` and the
/// convenience subscription methods. Iterate it with `for await`:
///
/// ```swift
/// let subscription = try await client.subscribe(filters: [filter])
/// for await item in subscription {
///     switch item {
///     case .event(_, let event): print(event.content)
///     case .eose(let relayURL): print("EOSE from \(relayURL)")
///     default: break
///     }
/// }
/// ```
///
/// Use ``events`` to iterate only event payloads, skipping eose/closed/notice/auth.
///
/// The underlying REQ is closed (CLOSE is sent to the relays) when iteration
/// stops, the consuming task is cancelled, ``close()`` is called, or the
/// sequence is discarded without being consumed.
///
/// - Important: The sequence is single-consumer: create one iterator — either
///   on this sequence or on ``events``, not both. Multiple iterators race for
///   elements.
public struct SubscriptionSequence: AsyncSequence, Sendable {
    public typealias Element = SubscriptionEvent

    /// The subscription ID, usable with ``NostrClient/unsubscribe(subscriptionId:)``.
    public let id: String

    /// The relays that accepted the REQ. EOSE completion is measured against
    /// this set (see ``NostrClient/fetch(filters:timeout:)``).
    public let expectedRelays: Set<URL>

    let stream: AsyncStream<SubscriptionEvent>
    let onClose: @Sendable () async -> Void

    /// Closes the subscription: sends CLOSE to the relays and ends iteration.
    /// Calling it more than once is harmless.
    public func close() async {
        await onClose()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: stream.makeAsyncIterator())
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncStream<SubscriptionEvent>.AsyncIterator

        public mutating func next() async -> SubscriptionEvent? {
            await base.next()
        }
    }

    /// A view of this subscription that yields only event payloads,
    /// skipping eose, closed, notice, and auth items.
    public var events: Events {
        Events(base: self)
    }

    /// An event-payload-only view of a ``SubscriptionSequence``.
    public struct Events: AsyncSequence, Sendable {
        public typealias Element = Event

        let base: SubscriptionSequence

        /// The subscription ID, usable with ``NostrClient/unsubscribe(subscriptionId:)``.
        public var id: String { base.id }

        /// The relays that accepted the REQ.
        public var expectedRelays: Set<URL> { base.expectedRelays }

        /// Closes the subscription: sends CLOSE to the relays and ends iteration.
        public func close() async {
            await base.close()
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: base.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            var base: SubscriptionSequence.AsyncIterator

            public mutating func next() async -> Event? {
                while let item = await base.next() {
                    if case .event(_, let event) = item {
                        return event
                    }
                }
                return nil
            }
        }
    }
}
