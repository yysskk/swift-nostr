import Foundation

/// A signed event together with the per-relay outcome of its publish.
///
/// Returned by the convenience publish methods on ``NostrClient`` (for example
/// ``NostrClient/publishTextNote(content:tags:strategy:)``) so callers get both
/// the event that was sent and the ``PublishResult`` describing which relays
/// accepted it.
///
/// `Event` properties are forwarded via dynamic member lookup, so existing
/// call sites such as `published.id` or `published.content` keep working.
/// Use ``event`` where an `Event` value itself is required.
@dynamicMemberLookup
public struct PublishedEvent: Sendable {
    /// The signed event that was sent.
    public let event: Event

    /// Per-relay outcome of the publish (accepted / failed / pending).
    public let result: PublishResult

    public init(event: Event, result: PublishResult) {
        self.event = event
        self.result = result
    }

    /// Forwards `Event` properties: `published.id`, `published.kind`, `published.content`, ...
    public subscript<T>(dynamicMember keyPath: KeyPath<Event, T>) -> T {
        event[keyPath: keyPath]
    }
}
