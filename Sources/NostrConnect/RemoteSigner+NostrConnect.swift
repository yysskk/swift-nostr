import Foundation
public import NostrCore

/// Client-initiated `nostrconnect://` sessions.
///
/// In this flow the client — not the signer — starts the handshake. The client generates a
/// ``NostrConnectURI`` invitation (shown to the user as a QR code or deep link), the signer scans it
/// and replies, and the client discovers the signer's public key from that reply *after* validating the
/// invitation secret the signer echoes back. ``connect()`` waits for that reply; once it returns, the
/// typed commands (``sign(_:)-(UnsignedEvent)``, ``userPublicKey()``, …) work exactly as they do for
/// a `bunker://` session. A command issued before then waits for the reply itself.
///
/// https://github.com/nostr-protocol/nips/blob/master/46.md
extension RemoteSigner {
    /// Creates a client-initiated session from a `nostrconnect://` invitation you generated and
    /// showed to the signer (QR/link). The signer's public key is discovered from its first valid
    /// response — call ``connect()`` to wait for it.
    ///
    /// - Parameters:
    ///   - invitation: The invitation you built with ``NostrConnectURI/invitation(clientKeyPair:relays:permissions:name:url:image:)``
    ///     and displayed to the signer. Its `secret` is retained and matched against the signer's
    ///     reply.
    ///   - clientKeyPair: The client identity whose public key originates the invitation. Must match
    ///     ``NostrConnectURI/clientPublicKey``.
    ///   - transport: The relay transport. Defaults to a `RelayConnectionTransport` over the
    ///     invitation's relays; inject a custom one (e.g. for tests).
    ///   - config: Session behavior.
    /// - Throws: ``RemoteSignerError/invalidURI(reason:)`` if `clientKeyPair` does not match the
    ///   invitation's `clientPublicKey`.
    public init(
        invitation: NostrConnectURI,
        clientKeyPair: KeyPair,
        transport: (any RelayTransport)? = nil,
        config: Config = Config()
    ) throws(RemoteSignerError) {
        guard clientKeyPair.publicKey == invitation.clientPublicKey else {
            throw RemoteSignerError.invalidURI(reason: "client keypair does not match the invitation public key")
        }
        self.init(
            clientKeyPair: clientKeyPair,
            expectedInvitationSecret: invitation.secret,
            transport: transport ?? RelayConnectionTransport(relayURLs: invitation.relays),
            config: config)
    }
}
