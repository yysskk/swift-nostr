import Foundation

/// Result of sending a NIP-17 private direct message.
///
/// NIP-17 sends the same message twice: one gift wrap addressed to the recipient
/// and one addressed to the sender (the self-copy that provides sent history and
/// multi-device sync). Both wraps carry the identical unsigned kind-14 rumor.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct SendDirectMessageResult: Sendable {
    /// The unsigned kind-14 rumor shared by both gift wraps (`sig` is empty —
    /// NIP-17 rumors must never be signed). Its `id` is the stable key for
    /// matching the message when it echoes back from a relay.
    public let rumor: Event

    /// The gift wrap addressed to the recipient.
    public let recipientGiftWrap: Event

    /// The gift wrap addressed to the sender (self-copy).
    public let selfGiftWrap: Event

    public init(rumor: Event, recipientGiftWrap: Event, selfGiftWrap: Event) {
        self.rumor = rumor
        self.recipientGiftWrap = recipientGiftWrap
        self.selfGiftWrap = selfGiftWrap
    }
}
