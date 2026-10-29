import Foundation
import NostrCore

/// Result of sending a gift-wrapped NIP-17 payload — a private direct message, a NIP-25
/// reaction to one, a file message, or a rumor of any kind sent with
/// ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)``.
///
/// Pairs the published ``GiftWrappedMessage`` with the per-relay outcome of each wrap.
/// `message.rumor.id` is the key for matching the payload when it echoes back from a relay.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct SendDirectMessageResult: Sendable, Hashable {
    /// The shared rumor and both gift wraps that were published.
    public let message: GiftWrappedMessage

    /// Per-relay outcome of publishing the recipient gift wrap.
    public let recipientPublishResult: PublishResult

    /// Per-relay outcome of the best-effort self-copy publish.
    /// `nil` when the publish failed outright.
    public let selfCopyPublishResult: PublishResult?

    /// Creates a send result from the published message and its publish outcomes.
    public init(
        message: GiftWrappedMessage,
        recipientPublishResult: PublishResult,
        selfCopyPublishResult: PublishResult?
    ) {
        self.message = message
        self.recipientPublishResult = recipientPublishResult
        self.selfCopyPublishResult = selfCopyPublishResult
    }
}
