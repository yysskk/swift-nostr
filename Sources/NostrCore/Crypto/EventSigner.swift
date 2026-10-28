import Crypto
import Foundation
import P256K

/// Handles signing and verification of Nostr events
///
/// A local ``NostrSigning`` source: it signs and encrypts synchronously with the key it holds, so
/// its methods are called without `await` — in async code too — unless it is used as a
/// `NostrSigning`.
public struct EventSigner: Sendable {
    /// The signer's key pair. `private`: nothing outside this type reads the private key —
    /// callers that need one go through ``NostrSigning``, whose signing and NIP-44 requirements
    /// this type satisfies with the key it holds.
    private let keyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.keyPair = keyPair
    }

    /// Creates a signer for a private key.
    public init(privateKey: PrivateKey) {
        self.keyPair = KeyPair(privateKey: privateKey)
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

    /// Signs an unsigned event and returns a complete signed event.
    /// - Parameter unsignedEvent: The event to sign. Its `publicKey` must be this signer's
    ///   ``publicKey``.
    /// - Returns: The signed ``Event``.
    /// - Throws: ``EventSigner/Error/publicKeyMismatch`` if `unsignedEvent` is keyed to another
    ///   public key.
    public func sign(_ unsignedEvent: UnsignedEvent) throws(EventSigner.Error) -> Event {
        // The id commits to the public key, so signing another key's event would produce one whose
        // signature cannot verify.
        guard unsignedEvent.publicKey == publicKey else {
            throw .publicKeyMismatch
        }
        return signed(unsignedEvent)
    }

    /// Signs `template` as this signer's ``publicKey``, returning the complete signed event.
    ///
    /// This method satisfies ``NostrSigning/sign(_:)-(EventTemplate)`` synchronously and without
    /// throwing, so an ``EventSigner`` signs a template without `try` or `await`, in synchronous and
    /// async code alike:
    ///
    /// ```swift
    /// let note = signer.sign(.textNote("gm"))
    /// ```
    /// - Parameter template: The event to sign.
    /// - Returns: The signed ``Event``.
    public func sign(_ template: EventTemplate) -> Event {
        signed(UnsignedEvent(template, publicKey: publicKey))
    }

    /// Signs `unsignedEvent`, which the caller guarantees is keyed to this signer's ``publicKey``.
    private func signed(_ unsignedEvent: UnsignedEvent) -> Event {
        let hash = SHA256.hash(data: unsignedEvent.serializedForHashing())

        // A KeyPair only ever holds a valid scalar, and libsecp256k1 rejects nothing else: signing
        // with one fails only on a zero nonce, which is cryptographically unreachable.
        let signature: P256K.Schnorr.SchnorrSignature
        do {
            signature = try P256K.Schnorr.PrivateKey(dataRepresentation: keyPair.privateKey.data).signature(for: hash)
        } catch {
            preconditionFailure("Schnorr signing failed with a valid secp256k1 scalar: \(error)")
        }

        return Event(
            id: EventID(validatedData: Data(hash)),
            publicKey: unsignedEvent.publicKey,
            createdAt: unsignedEvent.createdAt,
            kind: unsignedEvent.kind,
            tags: unsignedEvent.tags,
            content: unsignedEvent.content,
            signature: Signature(validatedData: signature.dataRepresentation)
        )
    }

    /// Encrypts `plaintext` to `recipientPublicKey` with NIP-44 v2, as this signer's identity.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPublicKey: The recipient's public key.
    /// - Returns: The base64-encoded NIP-44 payload.
    /// - Throws: What ``NIP44Payload/encrypt(_:for:using:)`` throws.
    public func nip44Encrypt(
        _ plaintext: String, to recipientPublicKey: PublicKey
    ) throws(NIP44Payload.Error) -> String {
        try NIP44Payload.encrypt(plaintext, for: recipientPublicKey, using: keyPair).base64
    }

    /// Decrypts a NIP-44 v2 payload from `senderPublicKey` addressed to this signer's identity.
    /// - Parameters:
    ///   - ciphertext: The base64-encoded NIP-44 payload.
    ///   - senderPublicKey: The sender's public key.
    /// - Returns: The decrypted plaintext.
    /// - Throws: What ``NIP44Payload/decrypt(from:using:)`` throws.
    public func nip44Decrypt(
        _ ciphertext: String, from senderPublicKey: PublicKey
    ) throws(NIP44Payload.Error) -> String {
        try NIP44Payload(base64: ciphertext).decrypt(from: senderPublicKey, using: keyPair)
    }

    /// Why ``EventSigner`` refused to sign an event.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The event's `publicKey` is not this signer's ``EventSigner/publicKey``.
        case publicKeyMismatch

        public var errorDescription: String? {
            switch self {
            case .publicKeyMismatch:
                return "The event's public key does not match the signer's"
            }
        }
    }
}

// MARK: - Event Verification
extension Event {
    /// Verifies the event's id and signature, throwing if either does not check out.
    /// - Throws: ``Event/VerificationError/idMismatch`` if ``id`` is not the hash of the event's
    ///   other fields; ``Event/VerificationError/missingSignature`` if the event is an unsigned
    ///   rumor (``signature`` is `nil`); ``Event/VerificationError/invalidSignature`` if
    ///   ``signature`` is not a valid Schnorr signature by ``publicKey`` over ``id``.
    public func verify() throws(Event.VerificationError) {
        // Reconstruct the unsigned event
        let unsigned = UnsignedEvent(
            publicKey: publicKey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )

        let hash = SHA256.hash(data: unsigned.serializedForHashing())

        // Verify the event ID
        guard Data(hash) == id.data else {
            throw .idMismatch
        }

        guard let signature else {
            throw .missingSignature
        }

        // libsecp256k1 parses these as fixed-width buffers: `XonlyKey` forwards the bytes to
        // `secp256k1_xonly_pubkey_parse`, which reads 32 bytes unconditionally and neither checks
        // nor reports the length. `PublicKey` and `Signature` only ever hold 32 and 64 bytes, so
        // the lengths are guaranteed by the types rather than checked here — and `SchnorrSignature`
        // rejects nothing but a buffer that is not 64 bytes, so its parse cannot fail either.
        let xonlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: publicKey.data, keyParity: 0)
        guard let schnorrSignature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature.data),
            xonlyKey.isValidSignature(schnorrSignature, for: hash)
        else {
            throw .invalidSignature
        }
    }

    /// Whether the event's id and signature verify.
    ///
    /// The convenience for when the reason does not matter; ``verify()`` throws it as an error.
    public var isValid: Bool {
        (try? verify()) != nil
    }

    /// Why an event failed ``Event/verify()``.
    public enum VerificationError: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The event's ``Event/id`` is not the hash of its other fields.
        case idMismatch
        /// The event is an unsigned rumor: its ``Event/signature`` is `nil`.
        case missingSignature
        /// The event's ``Event/signature`` is not a valid Schnorr signature by its
        /// ``Event/publicKey`` over its ``Event/id``.
        case invalidSignature

        public var errorDescription: String? {
            switch self {
            case .idMismatch:
                return "The event id does not match the hash of its contents"
            case .missingSignature:
                return "The event has no signature"
            case .invalidSignature:
                return "The event signature is not valid"
            }
        }
    }
}
