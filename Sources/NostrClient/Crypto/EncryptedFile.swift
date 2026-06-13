import Crypto
import Foundation

/// AES-256-GCM file encryption for NIP-17 kind-15 file messages.
///
/// A file is encrypted with a fresh random key and nonce. The resulting ``ciphertext`` (the
/// encrypted bytes followed by the 16-byte GCM authentication tag) is what you upload to your
/// host; the ``key`` and ``nonce`` travel inside the gift-wrapped message so only the recipient
/// can decrypt. Per NIP-17 the nonce is carried in the message's `decryption-nonce` tag and is
/// **not** embedded in the uploaded blob.
///
/// ```swift
/// let encrypted = try EncryptedFile.encrypt(imageData)
/// let url = try await upload(encrypted.ciphertext)            // your host, out of scope here
/// try await client.sendFileMessage(url: url, mimeType: "image/jpeg", encryption: encrypted, to: pubkey)
///
/// // On the receiving side, after downloading the blob at `file.url`:
/// let imageData = try EncryptedFile.decrypt(blob, key: file.decryptionKey, nonce: file.decryptionNonce)
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/17.md
public struct EncryptedFile: Sendable, Hashable {
    /// The encrypted bytes to upload: ciphertext followed by the 16-byte GCM tag.
    public let ciphertext: Data

    /// The 32-byte AES-256 key. Sent base64-encoded in the `decryption-key` tag.
    public let key: Data

    /// The 12-byte GCM nonce. Sent base64-encoded in the `decryption-nonce` tag.
    public let nonce: Data

    /// Lowercase hex SHA-256 of ``ciphertext`` — the message's `x` tag.
    public let encryptedSHA256: String

    /// Lowercase hex SHA-256 of the original plaintext — the message's `ox` tag.
    public let originalSHA256: String

    /// The GCM authentication tag length, in bytes.
    private static let tagLength = 16

    public init(ciphertext: Data, key: Data, nonce: Data, encryptedSHA256: String, originalSHA256: String) {
        self.ciphertext = ciphertext
        self.key = key
        self.nonce = nonce
        self.encryptedSHA256 = encryptedSHA256
        self.originalSHA256 = originalSHA256
    }

    /// Encrypts `data` with a freshly generated AES-256-GCM key and 96-bit nonce.
    /// - Parameter data: The plaintext file contents.
    /// - Returns: The encrypted blob plus the key, nonce, and hashes needed for the message.
    public static func encrypt(_ data: Data) throws -> EncryptedFile {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)

        // Upload the ciphertext with its tag appended; the nonce travels in the message tag.
        let blob = sealedBox.ciphertext + sealedBox.tag
        return EncryptedFile(
            ciphertext: blob,
            key: key.withUnsafeBytes { Data($0) },
            nonce: Data(nonce),
            encryptedSHA256: Data(SHA256.hash(data: blob)).hexEncodedString(),
            originalSHA256: Data(SHA256.hash(data: data)).hexEncodedString()
        )
    }

    /// Decrypts a downloaded NIP-17 file blob (ciphertext followed by the GCM tag).
    /// - Parameters:
    ///   - ciphertext: The downloaded encrypted blob.
    ///   - key: The AES-256 key from the message's `decryption-key` tag.
    ///   - nonce: The GCM nonce from the message's `decryption-nonce` tag.
    /// - Returns: The decrypted plaintext file contents.
    /// - Throws: ``NostrError/decryptionFailed`` if the blob is too short or authentication fails.
    public static func decrypt(_ ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        guard ciphertext.count >= tagLength else {
            throw NostrError.decryptionFailed
        }
        let body = ciphertext.prefix(ciphertext.count - tagLength)
        let tag = ciphertext.suffix(tagLength)

        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw NostrError.decryptionFailed
        }
    }
}
