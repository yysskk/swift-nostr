import Foundation
import NostrCore

/// A NIP-17 kind-15 file message: an encrypted file shared in a private direct-message
/// conversation.
///
/// The ``attachment`` describes the file: download the blob at its ``FileAttachment/url`` and
/// decrypt it with ``FileAttachment/decrypt(_:)``, using the key and nonce that travel in the
/// gift-wrapped message.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct DirectMessageFile: Sendable, Identifiable, Hashable {
    /// Unique identifier (the rumor's event id).
    public var id: EventID { rumorID }

    /// The rumor's event id.
    public let rumorID: EventID

    /// The sender's public key.
    public let senderPublicKey: PublicKey

    /// The recipient's public key.
    public let recipientPublicKey: PublicKey

    /// The shared file: its URL, decryption key and nonce, hashes, and metadata.
    public let attachment: FileAttachment

    /// When the message was created: the rumor's `created_at`.
    public let createdAt: Timestamp

    /// The NIP-40 expiration carried on the gift wrap, if any. After this time relays stop serving
    /// the event.
    public let expiresAt: Timestamp?

    /// Creates a file message from its parsed parts.
    public init(
        rumorID: EventID,
        senderPublicKey: PublicKey,
        recipientPublicKey: PublicKey,
        attachment: FileAttachment,
        createdAt: Timestamp,
        expiresAt: Timestamp? = nil
    ) {
        self.rumorID = rumorID
        self.senderPublicKey = senderPublicKey
        self.recipientPublicKey = recipientPublicKey
        self.attachment = attachment
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
