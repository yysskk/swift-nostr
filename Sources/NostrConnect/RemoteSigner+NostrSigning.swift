public import NostrCore

/// ``RemoteSigner`` is a ``NostrSigning`` source: a remote NIP-46 signer usable anywhere a local
/// ``EventSigner`` is.
///
/// ``sign(_:)-(UnsignedEvent)``, ``nip44Encrypt(_:to:)``, and ``nip44Decrypt(_:from:)`` already satisfy the protocol
/// as declared on ``RemoteSigner``; ``publicKey``, mapping to the user's key, and
/// ``sign(_:)-(EventTemplate)`` are added here.
extension RemoteSigner: NostrSigning {
    /// The user's public key (via `get_public_key`).
    ///
    /// This is the user key the signer authors events under, not the client/session key. The value
    /// is cached after the first fetch, shared with ``userPublicKey()``.
    /// - Throws: ``RemoteSignerError/responseValidationFailed`` if the signer replies with anything
    ///   but a canonical hex public key.
    public var publicKey: PublicKey {
        get async throws { try await userPublicKey() }
    }

    /// Signs `template` as the user's public key (via `sign_event`).
    /// - Parameter template: The event to sign.
    /// - Returns: The signed ``Event``.
    /// - Throws: What ``publicKey`` or ``sign(_:)-(UnsignedEvent)`` throws.
    public func sign(_ template: EventTemplate) async throws -> Event {
        try await sign(UnsignedEvent(template, publicKey: publicKey))
    }
}
