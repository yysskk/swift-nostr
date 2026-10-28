import Crypto
import Foundation
import P256K

/// A NIP-44 conversation key: the 32 bytes of secret material that every per-message key is
/// expanded from.
///
/// Two parties derive the same key from their own private key and the other's public key with
/// ``init(privateKey:publicKey:)``. A key shared by a group comes from ``random()`` and is
/// distributed out of band, so that one ``NIP44Payload`` can be read by all of its members.
///
/// A `ConversationKey` always holds exactly 32 bytes, so ``NIP44Payload/encrypt(_:with:)`` and
/// ``NIP44Payload/decrypt(with:)`` never reject it. Like ``PrivateKey``, its `description`,
/// `debugDescription`, and reflection are redacted, and equality compares every byte; read
/// ``data`` to export it deliberately.
public struct ConversationKey: Sendable {
    /// The key's 32 bytes.
    public let data: Data

    /// The length of a conversation key, the HKDF-Extract output the message keys expand from.
    static let byteCount = 32

    /// Creates a conversation key from its 32 bytes.
    ///
    /// The bytes must be uniformly random secret material: either a key derived by NIP-44, or 32
    /// bytes from a CSPRNG.
    /// - Throws: ``NIP44Payload/Error/invalidConversationKey`` if `data` is not 32 bytes.
    public init(data: Data) throws(NIP44Payload.Error) {
        guard data.count == Self.byteCount else {
            throw .invalidConversationKey
        }
        self.data = Data(data)
    }

    /// Derives the conversation key between `privateKey` and `publicKey` with ECDH and
    /// HKDF-Extract, as NIP-44 v2 specifies.
    ///
    /// The derivation is symmetric: Alice's private key with Bob's public key yields the same key
    /// as Bob's private key with Alice's public key.
    /// - Parameters:
    ///   - privateKey: The caller's private key.
    ///   - publicKey: The peer's public key.
    /// - Throws: ``NIP44Payload/Error/invalidPublicKey`` if `publicKey` is not a point on
    ///   secp256k1.
    public init(privateKey: PrivateKey, publicKey: PublicKey) throws(NIP44Payload.Error) {
        // A PrivateKey only ever holds a valid scalar, so this cannot fail. KeyAgreement, not
        // Signing, is the key type that performs ECDH.
        let agreementKey: P256K.KeyAgreement.PrivateKey
        do {
            agreementKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey.data)
        } catch {
            preconditionFailure("A PrivateKey holds a valid secp256k1 scalar: \(error)")
        }

        // Lift the x-only public key to a full point. Either parity yields the same shared x, so
        // the even one (0x02) is tried first and the odd one (0x03) only if that fails.
        let peerKey: P256K.KeyAgreement.PublicKey
        if let evenKey = try? P256K.KeyAgreement.PublicKey(
            dataRepresentation: Data([0x02]) + publicKey.data, format: .compressed)
        {
            peerKey = evenKey
        } else if let oddKey = try? P256K.KeyAgreement.PublicKey(
            dataRepresentation: Data([0x03]) + publicKey.data, format: .compressed)
        {
            peerKey = oddKey
        } else {
            throw .invalidPublicKey
        }

        // The compressed shared point is a parity byte followed by the x-coordinate; NIP-44 needs
        // only the x-coordinate.
        let sharedSecret = agreementKey.sharedSecretFromKeyAgreement(with: peerKey, format: .compressed)
        var sharedX = sharedSecret.withUnsafeBytes { bytes in
            Data(bytes.dropFirst())
        }
        // The conversation key is derived from this; nothing needs the shared point afterwards.
        defer { sharedX.secureScrub() }

        // HKDF-Extract with the NIP-44 salt.
        let salt = SymmetricKey(data: Data("nip44-v2".utf8))
        let extracted = HMAC<Crypto.SHA256>.authenticationCode(for: sharedX, using: salt)
        self.data = Data(extracted)
    }

    /// Generates a conversation key from 32 bytes of the system CSPRNG, e.g. for a group whose
    /// members all hold the same key.
    public static func random() -> ConversationKey {
        ConversationKey(validatedData: SecureRandom.generateBytes(count: byteCount))
    }

    /// Creates a conversation key from bytes the caller guarantees are 32 long.
    private init(validatedData data: Data) {
        precondition(data.count == Self.byteCount, "A conversation key is 32 bytes")
        self.data = data
    }
}

// MARK: - Equatable & Hashable
extension ConversationKey: Hashable {
    /// Compares every byte regardless of where the keys first differ, so the comparison's duration
    /// does not reveal how much of a key matched.
    public static func == (lhs: ConversationKey, rhs: ConversationKey) -> Bool {
        zip(lhs.data, rhs.data).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(data)
    }
}

// MARK: - Redaction
extension ConversationKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A placeholder that never contains the key.
    public var description: String {
        "ConversationKey(<redacted>)"
    }

    /// A placeholder that never contains the key.
    public var debugDescription: String {
        description
    }

    /// A mirror with no children, so `dump` and other reflection show only ``description``.
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}
