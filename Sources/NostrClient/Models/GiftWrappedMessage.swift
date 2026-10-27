import Foundation
import NostrCore

/// A NIP-17 payload gift-wrapped for both parties, built but not published.
///
/// NIP-17 sends the same payload twice: one gift wrap addressed to the recipient and one addressed
/// to the sender (the self-copy that provides sent history and multi-device sync). Both wraps carry
/// the identical unsigned rumor. Returned by ``DirectMessageBuilder``, and carried by
/// ``SendDirectMessageResult`` once published.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct GiftWrappedMessage: Sendable {
    /// The unsigned rumor shared by both gift wraps — kind 14 for a message, kind 15 for a file,
    /// kind 7 for a reaction, or the caller's kind for ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)``
    /// (``Event/signature`` is `nil`; NIP-17 rumors must never be signed). Its `id` is the stable
    /// key for matching the payload when it echoes back from a relay.
    public let rumor: Event

    /// The gift wrap addressed to the recipient.
    public let recipientGiftWrap: Event

    /// The gift wrap addressed to the sender (self-copy).
    public let selfGiftWrap: Event

    /// Creates a gift-wrapped message from its rumor and both wraps.
    public init(rumor: Event, recipientGiftWrap: Event, selfGiftWrap: Event) {
        self.rumor = rumor
        self.recipientGiftWrap = recipientGiftWrap
        self.selfGiftWrap = selfGiftWrap
    }
}
