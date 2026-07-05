import Foundation
public import NostrCore

/// Client-initiated `nostrconnect://` sessions.
///
/// In this flow the client — not the signer — starts the handshake. The client generates a
/// ``NostrConnectURI`` invitation (shown to the user as a QR code or deep link), the signer scans it
/// and replies, and the client discovers the signer's pubkey from that reply *after* validating the
/// invitation secret the signer echoes back. Once ``awaitConnection()`` resolves, the typed commands
/// (``sign(_:)``, ``userPublicKey()``, …) work exactly as they do for a `bunker://` session.
///
/// https://github.com/nostr-protocol/nips/blob/master/46.md
extension RemoteSigner {
    /// Creates a client-initiated session from a `nostrconnect://` invitation you generated and
    /// showed to the signer (QR/link). The signer's pubkey is discovered from its first valid
    /// response — call ``awaitConnection()`` to wait for it.
    ///
    /// - Parameters:
    ///   - invitation: The invitation you built with ``NostrConnectURI/invitation(clientKeyPair:relays:permissions:name:url:image:)``
    ///     and displayed to the signer. Its `secret` is retained and matched against the signer's
    ///     reply.
    ///   - clientKeyPair: The client identity whose public key originates the invitation. Must match
    ///     ``NostrConnectURI/clientPubkey``.
    ///   - transport: The relay transport. Defaults to a ``RelayConnectionTransport`` over the
    ///     invitation's relays; inject a custom one (e.g. for tests).
    ///   - config: Session behavior.
    /// - Throws: ``RemoteSignerError/invalidURI(reason:)`` if `clientKeyPair` does not match the
    ///   invitation's `clientPubkey`.
    public init(
        invitation: NostrConnectURI,
        clientKeyPair: KeyPair,
        transport: (any RemoteSignerTransport)? = nil,
        config: Config = Config()
    ) throws {
        guard clientKeyPair.publicKeyHex == invitation.clientPubkey else {
            throw RemoteSignerError.invalidURI(reason: "client keypair does not match the invitation pubkey")
        }
        self.init(
            clientKeyPair: clientKeyPair,
            expectedInvitationSecret: invitation.secret,
            transport: transport ?? RelayConnectionTransport(relayURLs: invitation.relays),
            config: config)
    }

    /// Waits for the signer to accept the invitation: the first kind-24133 response whose result
    /// echoes the invitation secret (per NIP-46, the client MUST validate the returned secret).
    /// Returns the discovered remote-signer pubkey and pins subsequent traffic to it.
    ///
    /// A response whose result is present but does *not* equal the secret is treated as a spoofing
    /// attempt and ignored: the method keeps waiting for the correct secret rather than failing, and
    /// gives up only when the wait times out. Once resolved, ``remoteSignerPubkey`` returns the
    /// discovered pubkey and the session is connected, so the typed commands work immediately.
    ///
    /// Calling this on a session whose signer is already known (a `bunker://` session, or a repeat
    /// call) returns the known pubkey without waiting.
    ///
    /// - Returns: The remote signer's public key (hex).
    /// - Throws: ``RemoteSignerError/timedOut`` if no valid response arrives within
    ///   ``Config/requestTimeout``, ``RemoteSignerError/notConnected`` if the session is torn down or
    ///   another wait is already in progress, or a transport error.
    @discardableResult
    public func awaitConnection() async throws -> String {
        try await discoverSigner()
    }
}
