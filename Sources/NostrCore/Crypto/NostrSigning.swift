/// A source of Nostr signatures and NIP-44 encryption — a local key (``EventSigner``) or a remote
/// NIP-46 signer.
///
/// The abstraction lets callers accept either a private key held in-process or a remote signer (a
/// "bunker") that holds the key on the user's behalf, without knowing which. All requirements are
/// `async throws` so a conformance is free to perform relay round-trips; a local ``EventSigner``
/// satisfies them synchronously.
///
/// NIP-04 is deliberately absent: it is legacy encryption whose only implementation lives in the
/// NostrWalletConnect layer, and pulling it into this abstraction would force every signer to
/// support it.
public protocol NostrSigning: Sendable {
    /// The public key events are authored under.
    ///
    /// For a remote signer this is the *user* key it signs on behalf of, which may differ from the
    /// signer's own session identity.
    var publicKey: PublicKey { get async throws }

    /// Signs `event`, returning the complete signed event.
    /// - Parameter event: The unsigned event to sign. Its `publicKey` should be this signer's
    ///   ``publicKey``.
    /// - Returns: The signed ``Event``.
    func sign(_ event: UnsignedEvent) async throws -> Event

    /// Encrypts `plaintext` to `recipientPublicKey` with NIP-44 as this signer's identity.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPublicKey: The recipient's public key.
    /// - Returns: The NIP-44 payload.
    func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String

    /// Decrypts a NIP-44 payload from `senderPublicKey` addressed to this signer's identity.
    /// - Parameters:
    ///   - ciphertext: The NIP-44 payload.
    ///   - senderPublicKey: The sender's public key.
    /// - Returns: The decrypted plaintext.
    func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String
}

extension EventSigner: NostrSigning {}
