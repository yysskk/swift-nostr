import Foundation

/// An encrypted file shared in a NIP-17 kind-15 file message: where it is hosted and what the
/// recipient needs to decrypt and verify it.
///
/// Senders build one from the ``EncryptedFile`` they uploaded with
/// ``init(url:mimeType:encryption:size:dimensions:blurhash:)``; receivers read it from
/// ``DirectMessageFile/attachment`` and decrypt the downloaded blob with ``decrypt(_:)``.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct FileAttachment: Sendable, Hashable {
    /// URL of the encrypted file (the kind-15 content).
    public var url: URL

    /// MIME type of the file before encryption (`file-type`), e.g. "image/jpeg".
    public var mimeType: String?

    /// The AES-256 key (`decryption-key`, base64 on the wire).
    public var decryptionKey: Data

    /// The GCM nonce (`decryption-nonce`, base64 on the wire).
    public var decryptionNonce: Data

    /// Lowercase hex SHA-256 of the encrypted file (`x`), for integrity verification.
    public var encryptedSHA256: String?

    /// Lowercase hex SHA-256 of the original file before encryption (`ox`).
    public var originalSHA256: String?

    /// Size of the encrypted file in bytes (`size`).
    public var size: Int?

    /// Dimensions in pixels as "<width>x<height>" (`dim`).
    public var dimensions: String?

    /// Blurhash placeholder for progressive display (`blurhash`).
    public var blurhash: String?

    /// Creates an attachment from its individual fields.
    public init(
        url: URL,
        mimeType: String? = nil,
        decryptionKey: Data,
        decryptionNonce: Data,
        encryptedSHA256: String? = nil,
        originalSHA256: String? = nil,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil
    ) {
        self.url = url
        self.mimeType = mimeType
        self.decryptionKey = decryptionKey
        self.decryptionNonce = decryptionNonce
        self.encryptedSHA256 = encryptedSHA256
        self.originalSHA256 = originalSHA256
        self.size = size
        self.dimensions = dimensions
        self.blurhash = blurhash
    }

    /// Creates an attachment for a file encrypted with ``EncryptedFile/encrypt(_:)`` and uploaded
    /// to `url`, taking the key, nonce, and both hashes from `encryption`.
    /// - Parameters:
    ///   - url: The URL of the uploaded encrypted file.
    ///   - mimeType: The file's MIME type before encryption.
    ///   - encryption: The encryption result whose key, nonce, and hashes describe the file.
    ///   - size: The encrypted file's size in bytes.
    ///   - dimensions: Pixel dimensions as "<width>x<height>".
    ///   - blurhash: A blurhash placeholder for progressive display.
    public init(
        url: URL,
        mimeType: String,
        encryption: EncryptedFile,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil
    ) {
        self.init(
            url: url,
            mimeType: mimeType,
            decryptionKey: encryption.key,
            decryptionNonce: encryption.nonce,
            encryptedSHA256: encryption.encryptedSHA256,
            originalSHA256: encryption.originalSHA256,
            size: size,
            dimensions: dimensions,
            blurhash: blurhash
        )
    }

    /// Decrypts the blob downloaded from ``url`` with this attachment's key and nonce, via
    /// ``EncryptedFile/decrypt(_:key:nonce:)``.
    /// - Parameter ciphertext: The downloaded encrypted blob.
    /// - Returns: The decrypted plaintext file contents.
    /// - Throws: The errors of ``EncryptedFile/decrypt(_:key:nonce:)``.
    public func decrypt(_ ciphertext: Data) throws(EncryptedFile.Error) -> Data {
        try EncryptedFile.decrypt(ciphertext, key: decryptionKey, nonce: decryptionNonce)
    }
}
