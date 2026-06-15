import Foundation
import NostrCore

/// Result of sending a gift-wrapped NIP-17 payload — a private direct message or a NIP-25
/// reaction to one.
///
/// NIP-17 sends the same payload twice: one gift wrap addressed to the recipient
/// and one addressed to the sender (the self-copy that provides sent history and
/// multi-device sync). Both wraps carry the identical unsigned rumor.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct SendDirectMessageResult: Sendable {
    /// The unsigned rumor shared by both gift wraps — kind 14 for a message, kind 7 for a
    /// reaction (`sig` is empty; NIP-17 rumors must never be signed). Its `id` is the stable
    /// key for matching the payload when it echoes back from a relay.
    public let rumor: Event

    /// The gift wrap addressed to the recipient.
    public let recipientGiftWrap: Event

    /// The gift wrap addressed to the sender (self-copy).
    public let selfGiftWrap: Event

    /// Per-relay outcome of publishing the recipient gift wrap.
    /// Always present when returned from a send such as
    /// ``NostrClient/sendDirectMessage(_:to:subject:replyTo:expiration:strategy:)``;
    /// `nil` when the result was built without publishing (e.g. by ``DirectMessageBuilder``).
    public let recipientPublishResult: PublishResult?

    /// Per-relay outcome of the best-effort self-copy publish.
    /// `nil` when the publish failed outright or was never attempted.
    public let selfCopyPublishResult: PublishResult?

    public init(
        rumor: Event,
        recipientGiftWrap: Event,
        selfGiftWrap: Event,
        recipientPublishResult: PublishResult? = nil,
        selfCopyPublishResult: PublishResult? = nil
    ) {
        self.rumor = rumor
        self.recipientGiftWrap = recipientGiftWrap
        self.selfGiftWrap = selfGiftWrap
        self.recipientPublishResult = recipientPublishResult
        self.selfCopyPublishResult = selfCopyPublishResult
    }
}
