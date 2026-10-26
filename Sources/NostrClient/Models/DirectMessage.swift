import Foundation
import NostrCore

/// NIP-17 Private Direct Message
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct DirectMessage: Sendable, Identifiable, Hashable {
    /// Unique identifier (the rumor's event id).
    public var id: EventID { rumorID }

    /// The rumor's event id.
    public let rumorID: EventID

    /// The sender's public key.
    public let senderPubkey: PublicKey

    /// The recipient's public key.
    public let recipientPubkey: PublicKey

    /// The message content
    public let content: String

    /// The timestamp when the message was created
    public let createdAt: Date

    /// Optional subject/title for the conversation
    public let subject: String?

    /// The id of the event this message replies to, if any.
    public let replyTo: EventID?

    /// Optional NIP-40 expiration carried on the gift wrap. After this time the relay
    /// stops serving the message; clients can hide it to honor a disappearing message.
    public let expiresAt: Date?

    /// Creates a direct message from its parsed parts.
    public init(
        rumorID: EventID,
        senderPubkey: PublicKey,
        recipientPubkey: PublicKey,
        content: String,
        createdAt: Date,
        subject: String? = nil,
        replyTo: EventID? = nil,
        expiresAt: Date? = nil
    ) {
        self.rumorID = rumorID
        self.senderPubkey = senderPubkey
        self.recipientPubkey = recipientPubkey
        self.content = content
        self.createdAt = createdAt
        self.subject = subject
        self.replyTo = replyTo
        self.expiresAt = expiresAt
    }
}
