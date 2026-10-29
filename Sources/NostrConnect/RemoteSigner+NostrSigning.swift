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
    /// This is the user key the signer authors events under, not the client/session key, and it may
    /// differ from ``remoteSignerPublicKey`` — a signer can hold a key distinct from its own session
    /// identity. The value is cached after the first fetch, so later reads return without another
    /// round-trip, and concurrent first reads share one `get_public_key` request.
    /// - Throws: ``RemoteSignerError/responseValidationFailed`` if the signer replies with anything
    ///   but a canonical hex public key, ``RemoteSignerError/cancelled`` if the calling task is
    ///   cancelled, or what ``send(_:params:)`` throws.
    public var publicKey: PublicKey {
        get async throws(RemoteSignerError) { try await resolveUserPublicKey() }
    }

    /// Signs `template` as the user's public key (via `sign_event`).
    /// - Parameter template: The event to sign.
    /// - Returns: The signed ``Event``.
    /// - Throws: What ``publicKey`` or ``sign(_:)-(UnsignedEvent)`` throws.
    public func sign(_ template: EventTemplate) async throws(RemoteSignerError) -> Event {
        try await sign(UnsignedEvent(template, publicKey: publicKey))
    }
}
