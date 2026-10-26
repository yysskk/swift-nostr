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

extension NostrSigning {
    /// Signs `template` as this signer's ``publicKey``, returning the complete signed event.
    ///
    /// Works with any signer, local or remote:
    ///
    /// ```swift
    /// let zap = try await bunker.sign(.zapRequest(to: alice, relays: [relay]))
    /// ```
    /// - Parameter template: The event to sign.
    /// - Returns: The signed ``Event``.
    /// - Throws: Anything resolving ``publicKey`` or signing throws.
    public func sign(_ template: EventTemplate) async throws -> Event {
        try await sign(UnsignedEvent(template, publicKey: publicKey))
    }

    /// Mines `template` to the given NIP-13 difficulty (leading zero bits) as this signer's
    /// ``publicKey``, then signs it.
    ///
    /// Mining runs locally whatever the signer; it is cooperative and cancellable — see
    /// ``ProofOfWork/mine(event:difficulty:)``.
    /// https://github.com/nostr-protocol/nips/blob/master/13.md
    /// - Parameters:
    ///   - template: The event to mine and sign. Any existing `nonce` tags are replaced.
    ///   - difficulty: The target number of leading zero bits, in `0...256`.
    /// - Returns: The signed ``Event``, whose id meets `difficulty`.
    /// - Throws: `CancellationError` if cancelled; ``ProofOfWork/Error/invalidDifficulty(_:)`` if
    ///   `difficulty` is outside `0...256`; anything resolving ``publicKey`` or signing throws.
    public func sign(_ template: EventTemplate, proofOfWork difficulty: Int) async throws -> Event {
        let unsigned = UnsignedEvent(template, publicKey: try await publicKey)
        return try await sign(ProofOfWork.mine(event: unsigned, difficulty: difficulty))
    }
}

extension EventSigner: NostrSigning {}
