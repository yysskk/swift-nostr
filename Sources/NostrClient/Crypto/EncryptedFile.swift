import Crypto
import Foundation
import NostrCore

/// AES-256-GCM file encryption for NIP-17 kind-15 file messages.
///
/// A file is encrypted with a fresh random key and nonce. The resulting ``ciphertext`` (the
/// encrypted bytes followed by the 16-byte GCM authentication tag) is what you upload to your
/// host; the ``key`` and ``nonce`` travel inside the gift-wrapped message so only the recipient
/// can decrypt. Per NIP-17 the nonce is carried in the message's `decryption-nonce` tag and is
/// **not** embedded in the uploaded blob.
///
/// ```swift
/// let encrypted = EncryptedFile.encrypt(imageData)
/// let url = try await upload(encrypted.ciphertext)            // your host, out of scope here
/// try await client.messages.sendFile(
///     url: url, mimeType: "image/jpeg", encryption: encrypted, to: publicKey)
///
/// // On the receiving side, after downloading the blob at `file.url`:
/// let decrypted = try EncryptedFile.decrypt(blob, key: file.decryptionKey, nonce: file.decryptionNonce)
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

    /// The AES-256 key length, in bytes.
    private static let keyLength = 32

    /// The GCM nonce length NIP-17 uses, in bytes.
    private static let nonceLength = 12

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
    /// - Precondition: `data` is under the 64 GiB a single AES-GCM message can hold.
    public static func encrypt(_ data: Data) -> EncryptedFile {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        // AES-GCM rejects only a key of the wrong size, a nonce of the wrong length, or a message
        // past its length limit, and the first two are fixed here.
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        } catch {
            preconditionFailure("AES-GCM rejected a 256-bit key and a 12-byte nonce: \(error)")
        }

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
    /// - Throws: ``EncryptedFile/Error/invalidKeyLength(_:)`` if `key` is not 32 bytes,
    ///   ``EncryptedFile/Error/invalidNonceLength(_:)`` if `nonce` is not 12 bytes,
    ///   ``EncryptedFile/Error/truncated`` if the blob is shorter than the GCM tag, or
    ///   ``EncryptedFile/Error/authenticationFailed`` if the blob does not authenticate under `key`
    ///   and `nonce`.
    public static func decrypt(_ ciphertext: Data, key: Data, nonce: Data) throws(EncryptedFile.Error) -> Data {
        guard key.count == keyLength else {
            throw .invalidKeyLength(key.count)
        }
        guard nonce.count == nonceLength else {
            throw .invalidNonceLength(nonce.count)
        }
        guard ciphertext.count >= tagLength else {
            throw .truncated
        }
        let body = ciphertext.prefix(ciphertext.count - tagLength)
        let tag = ciphertext.suffix(tagLength)

        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce), ciphertext: body, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            // The key, nonce, and tag lengths are checked above, so what is left is a blob that
            // does not authenticate.
            throw .authenticationFailed
        }
    }

    /// An error decrypting a NIP-17 file blob.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The key is not 32 bytes (payload: its byte count).
        case invalidKeyLength(Int)
        /// The nonce is not 12 bytes (payload: its byte count).
        case invalidNonceLength(Int)
        /// The blob is shorter than the 16-byte GCM authentication tag it must end with.
        case truncated
        /// The blob does not authenticate under the key and nonce: it was altered, or they are not
        /// the ones it was encrypted with.
        case authenticationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidKeyLength(let count):
                return "A file decryption key must be 32 bytes, got \(count)"
            case .invalidNonceLength(let count):
                return "A file decryption nonce must be 12 bytes, got \(count)"
            case .truncated:
                return "An encrypted file must end with a 16-byte authentication tag"
            case .authenticationFailed:
                return "The encrypted file does not authenticate with this key and nonce"
            }
        }
    }
}
