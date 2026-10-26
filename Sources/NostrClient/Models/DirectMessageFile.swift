import Foundation
import NostrCore

/// A NIP-17 kind-15 file message: an encrypted file shared in a private direct-message
/// conversation.
///
/// The `content` is the URL of the encrypted file; the key and nonce needed to decrypt it travel
/// in the gift-wrapped message. Download the blob at ``url`` and decrypt it with
/// ``EncryptedFile/decrypt(_:key:nonce:)`` using ``decryptionKey`` and ``decryptionNonce``.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct DirectMessageFile: Sendable, Identifiable, Hashable {
    /// Unique identifier (the rumor's event id).
    public var id: EventID { rumorID }

    /// The rumor's event id.
    public let rumorID: EventID

    /// The sender's public key.
    public let senderPubkey: PublicKey

    /// The recipient's public key.
    public let recipientPubkey: PublicKey

    /// URL of the encrypted file (the kind-15 content).
    public let url: String

    /// MIME type of the file before encryption (`file-type`), e.g. "image/jpeg".
    public let mimeType: String?

    /// The AES-256 key, decoded from the base64 `decryption-key` tag.
    public let decryptionKey: Data

    /// The GCM nonce, decoded from the base64 `decryption-nonce` tag.
    public let decryptionNonce: Data

    /// Lowercase hex SHA-256 of the encrypted file (`x`), for integrity verification.
    public let encryptedSHA256: String?

    /// Lowercase hex SHA-256 of the original file before encryption (`ox`).
    public let originalSHA256: String?

    /// Size of the encrypted file in bytes (`size`).
    public let size: Int?

    /// Dimensions in pixels as "<width>x<height>" (`dim`).
    public let dimensions: String?

    /// Blurhash placeholder for progressive display (`blurhash`).
    public let blurhash: String?

    /// When the message was created.
    public let createdAt: Date

    /// Optional NIP-40 expiration carried on the gift wrap.
    public let expiresAt: Date?

    /// Creates a file message from its parsed parts.
    public init(
        rumorID: EventID,
        senderPubkey: PublicKey,
        recipientPubkey: PublicKey,
        url: String,
        mimeType: String?,
        decryptionKey: Data,
        decryptionNonce: Data,
        encryptedSHA256: String? = nil,
        originalSHA256: String? = nil,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil,
        createdAt: Date,
        expiresAt: Date? = nil
    ) {
        self.rumorID = rumorID
        self.senderPubkey = senderPubkey
        self.recipientPubkey = recipientPubkey
        self.url = url
        self.mimeType = mimeType
        self.decryptionKey = decryptionKey
        self.decryptionNonce = decryptionNonce
        self.encryptedSHA256 = encryptedSHA256
        self.originalSHA256 = originalSHA256
        self.size = size
        self.dimensions = dimensions
        self.blurhash = blurhash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}
