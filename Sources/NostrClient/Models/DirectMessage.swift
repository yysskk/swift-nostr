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
    public let senderPublicKey: PublicKey

    /// The recipient's public key.
    public let recipientPublicKey: PublicKey

    /// The message content
    public let content: String

    /// When the message was created: the rumor's `created_at`, which the sender sets and the gift
    /// wrap does not randomize.
    public let createdAt: Timestamp

    /// Optional subject/title for the conversation
    public let subject: String?

    /// The id of the event this message replies to, if any.
    public let replyTo: EventID?

    /// Optional NIP-40 expiration carried on the gift wrap. After this time the relay
    /// stops serving the message; clients can hide it to honor a disappearing message.
    public let expiresAt: Timestamp?

    /// Creates a direct message from its parsed parts.
    public init(
        rumorID: EventID,
        senderPublicKey: PublicKey,
        recipientPublicKey: PublicKey,
        content: String,
        createdAt: Timestamp,
        subject: String? = nil,
        replyTo: EventID? = nil,
        expiresAt: Timestamp? = nil
    ) {
        self.rumorID = rumorID
        self.senderPublicKey = senderPublicKey
        self.recipientPublicKey = recipientPublicKey
        self.content = content
        self.createdAt = createdAt
        self.subject = subject
        self.replyTo = replyTo
        self.expiresAt = expiresAt
    }
}
