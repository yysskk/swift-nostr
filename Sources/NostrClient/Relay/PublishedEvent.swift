import Foundation
import NostrCore

/// A signed event together with the per-relay outcome of its publish.
///
/// Returned by the convenience publish methods of ``NostrEventPublishing`` (for example
/// ``NostrEventPublishing/publishTextNote(content:tags:strategy:)``). ``event`` is the
/// signed event that was sent, and ``result`` is the ``PublishResult`` describing which
/// relays accepted it.
public struct PublishedEvent: Sendable, Hashable {
    /// The signed event that was sent.
    public let event: Event

    /// Per-relay outcome of the publish (accepted / failed / pending).
    public let result: PublishResult

    /// Creates a published event from the signed event and its publish result.
    public init(event: Event, result: PublishResult) {
        self.event = event
        self.result = result
    }
}
