import Crypto
import Foundation
import P256K

/// Handles signing and verification of Nostr events
public struct EventSigner: Sendable {
    /// The signer's key pair. `private`: nothing outside this type reads the private key —
    /// callers that need one go through ``NostrSigning``, whose signing and NIP-44 requirements
    /// this type satisfies with the key it holds.
    private let keyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.keyPair = keyPair
    }

    /// Creates a signer from a hex-encoded private key.
    /// - Throws: What ``KeyPair/init(privateKeyHex:)`` throws for a malformed key.
    public init(privateKeyHex: String) throws(KeyPair.Error) {
        self.keyPair = try KeyPair(privateKeyHex: privateKeyHex)
    }

    /// Creates a signer from a NIP-19 `nsec`.
    /// - Throws: What ``KeyPair/init(nsec:)`` throws for a malformed `nsec`.
    public init(nsec: String) throws(KeyPair.Error) {
        self.keyPair = try KeyPair(nsec: nsec)
    }

    /// The public key associated with this signer
    public var publicKey: PublicKey {
        keyPair.publicKey
    }

    /// The public key as npub
    public var npub: String {
        keyPair.publicKey.npub
    }

    /// Signs an unsigned event and returns a complete signed event
    public func sign(_ unsignedEvent: UnsignedEvent) throws -> Event {
        // Serialize the event for hashing
        let serialized = try unsignedEvent.serializedForHashing()

        // Calculate the event ID (SHA256 hash of serialized event)
        let hash = SHA256.hash(data: serialized)

        // Sign the hash with the private key using Schnorr
        let privateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: keyPair.privateKey)
        let signature = try privateKey.signature(for: hash)

        return Event(
            id: try EventID(data: Data(hash)),
            publicKey: unsignedEvent.publicKey,
            createdAt: unsignedEvent.createdAt,
            kind: unsignedEvent.kind,
            tags: unsignedEvent.tags,
            content: unsignedEvent.content,
            signature: try Signature(data: Data(signature.dataRepresentation))
        )
    }

    /// Signs `template` as this signer's ``publicKey``, returning the complete signed event.
    ///
    /// The synchronous counterpart of ``NostrSigning/sign(_:)-(EventTemplate)``:
    ///
    /// ```swift
    /// let note = try signer.sign(.textNote("gm"))
    /// ```
    /// - Parameter template: The event to sign.
    /// - Returns: The signed ``Event``.
    /// - Throws: An error if the event cannot be serialized for hashing or signed.
    public func sign(_ template: EventTemplate) throws -> Event {
        try sign(UnsignedEvent(template, publicKey: publicKey))
    }

    /// Encrypts `plaintext` to `recipientPublicKey` with NIP-44 v2, as this signer's identity.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPublicKey: The recipient's public key.
    /// - Returns: The base64-encoded NIP-44 payload.
    public func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) throws -> String {
        try SealedMessage.seal(plaintext, for: recipientPublicKey, using: keyPair).payload
    }

    /// Decrypts a NIP-44 v2 payload from `senderPublicKey` addressed to this signer's identity.
    /// - Parameters:
    ///   - ciphertext: The base64-encoded NIP-44 payload.
    ///   - senderPublicKey: The sender's public key.
    /// - Returns: The decrypted plaintext.
    public func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) throws -> String {
        try SealedMessage(payload: ciphertext).open(from: senderPublicKey, using: keyPair)
    }
}

// MARK: - Event Verification
extension Event {
    /// Verifies the event's id and signature.
    /// - Returns: Whether ``signature`` is a valid Schnorr signature by ``publicKey`` over ``id``.
    /// - Throws: ``NostrError/invalidEventID`` if ``id`` is not the hash of the event's other
    ///   fields; ``NostrError/invalidSignature`` if the event is an unsigned rumor (``signature``
    ///   is `nil`) or the signature bytes cannot be parsed.
    public func verify() throws -> Bool {
        // Reconstruct the unsigned event
        let unsigned = UnsignedEvent(
            publicKey: publicKey,
            createdAt: createdAt,
            kind: kind,
            rawTags: tags,
            content: content
        )

        // Serialize and hash
        let serialized = try unsigned.serializedForHashing()
        let hash = SHA256.hash(data: serialized)

        // Verify the event ID
        guard Data(hash) == id.data else {
            throw NostrError.invalidEventID
        }

        guard let signature else {
            throw NostrError.invalidSignature
        }

        // libsecp256k1 parses these as fixed-width buffers: `XonlyKey` forwards the bytes to
        // `secp256k1_xonly_pubkey_parse`, which reads 32 bytes unconditionally and neither checks
        // nor reports the length. `PublicKey` and `Signature` only ever hold 32 and 64 bytes, so
        // the lengths are guaranteed by the types rather than checked here.
        let xonlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: publicKey.data, keyParity: 0)
        let schnorrSignature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: signature.data)

        return xonlyKey.isValidSignature(schnorrSignature, for: hash)
    }
}
