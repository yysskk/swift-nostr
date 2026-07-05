public import NostrCore

/// ``RemoteSigner`` is a ``NostrSigning`` source: a remote NIP-46 signer usable anywhere a local
/// ``EventSigner`` is.
///
/// ``sign(_:)``, ``nip44Encrypt(_:to:)``, and ``nip44Decrypt(_:from:)`` already satisfy the protocol
/// as declared on ``RemoteSigner``; only ``publicKey`` is added here, mapping to the user's key.
extension RemoteSigner: NostrSigning {
    /// The user's public key, hex-encoded (via `get_public_key`).
    ///
    /// This is the user key the signer authors events under, not the client/session key. The value
    /// is cached by ``userPublicKey()`` after the first fetch.
    public var publicKey: String {
        get async throws { try await userPublicKey() }
    }
}
