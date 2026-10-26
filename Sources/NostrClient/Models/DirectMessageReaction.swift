import Foundation
import NostrCore

/// A NIP-25 reaction to a NIP-17 private direct message.
///
/// Reactions travel the same way as messages — an unsigned kind-7 rumor, gift-wrapped
/// (NIP-59) for privacy and sender anonymity — but reference the message they react to via
/// its rumor id.
/// https://github.com/nostr-protocol/nips/blob/master/25.md
public struct DirectMessageReaction: Sendable, Identifiable, Hashable {
    /// Unique identifier (the reaction rumor's event id).
    public var id: EventID { rumorID }

    /// The reaction rumor's event id.
    public let rumorID: EventID

    /// The reactor's public key.
    public let senderPubkey: PublicKey

    /// The rumor id of the message being reacted to (the reaction's "e" tag).
    public let messageID: EventID

    /// The public key of the reacted-to message's author (the reaction's "p" tag).
    public let messageAuthorPubkey: PublicKey

    /// The reaction content — typically "+" (like), "-" (dislike), or an emoji.
    public let content: String

    /// When the reaction was created.
    public let createdAt: Date

    /// Optional NIP-40 expiration carried on the gift wrap.
    public let expiresAt: Date?

    /// Creates a reaction from its parsed parts.
    public init(
        rumorID: EventID,
        senderPubkey: PublicKey,
        messageID: EventID,
        messageAuthorPubkey: PublicKey,
        content: String,
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        self.rumorID = rumorID
        self.senderPubkey = senderPubkey
        self.messageID = messageID
        self.messageAuthorPubkey = messageAuthorPubkey
        self.content = content
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
