import Foundation

/// NIP-17 Private Direct Message
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct DirectMessage: Sendable, Identifiable, Hashable {
    /// Unique identifier (from the rumor event id)
    public var id: String { rumorId }

    /// The rumor event ID
    public let rumorId: String

    /// The sender's public key (hex)
    public let senderPubkey: String

    /// The recipient's public key (hex)
    public let recipientPubkey: String

    /// The message content
    public let content: String

    /// The timestamp when the message was created
    public let createdAt: Date

    /// Optional subject/title for the conversation
    public let subject: String?

    /// Optional reply reference (event ID being replied to)
    public let replyTo: String?

    /// Optional NIP-40 expiration carried on the gift wrap. After this time the relay
    /// stops serving the message; clients can hide it to honor a disappearing message.
    public let expiresAt: Date?

    public init(
        rumorId: String,
        senderPubkey: String,
        recipientPubkey: String,
        content: String,
        createdAt: Date,
        subject: String? = nil,
        replyTo: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.rumorId = rumorId
        self.senderPubkey = senderPubkey
        self.recipientPubkey = recipientPubkey
        self.content = content
        self.createdAt = createdAt
        self.subject = subject
        self.replyTo = replyTo
        self.expiresAt = expiresAt
    }
}
