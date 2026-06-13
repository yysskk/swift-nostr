import Foundation

/// A NIP-25 reaction to a NIP-17 private direct message.
///
/// Reactions travel the same way as messages — an unsigned kind-7 rumor, gift-wrapped
/// (NIP-59) for privacy and sender anonymity — but reference the message they react to via
/// its rumor id.
/// https://github.com/nostr-protocol/nips/blob/master/25.md
public struct DirectMessageReaction: Sendable, Identifiable, Hashable {
    /// Unique identifier (from the reaction rumor's event id).
    public var id: String { rumorId }

    /// The reaction rumor's event id.
    public let rumorId: String

    /// The reactor's public key (hex).
    public let senderPubkey: String

    /// The rumor id of the message being reacted to (the reaction's "e" tag).
    public let messageId: String

    /// The public key of the reacted-to message's author (the reaction's "p" tag).
    public let messageAuthorPubkey: String

    /// The reaction content — typically "+" (like), "-" (dislike), or an emoji.
    public let content: String

    /// When the reaction was created.
    public let createdAt: Date

    /// Optional NIP-40 expiration carried on the gift wrap.
    public let expiresAt: Date?

    public init(
        rumorId: String,
        senderPubkey: String,
        messageId: String,
        messageAuthorPubkey: String,
        content: String,
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        self.rumorId = rumorId
        self.senderPubkey = senderPubkey
        self.messageId = messageId
        self.messageAuthorPubkey = messageAuthorPubkey
        self.content = content
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
