import Foundation
import NostrCore

/// The signer the client authors events with, and the NIP-42 authentication that proves it
/// to relays. Reached as ``NostrClient/identity``.
public struct NostrIdentityAPI: NostrIdentityProviding {
    let client: NostrClient

    // MARK: - Signer

    /// Sets the signer for signing events.
    ///
    /// While ``authenticationMode`` is ``AuthenticationMode/automatic`` (the
    /// default), setting a signer also starts answering NIP-42 AUTH challenges
    /// with it on every relay in the pool.
    public func setSigner(_ signer: EventSigner) async {
        await client.install(signer)
    }

    /// Sets a local or remote signer for signing events.
    ///
    /// Accepts any ``NostrSigning`` — a local ``EventSigner`` or a remote NIP-46 signer (a
    /// "bunker"). The signer's ``NostrSigning/publicKey`` is resolved once here and cached, so
    /// ``publicKey`` and ``npub`` stay a single actor hop even for a remote signer. Every feature
    /// works with either kind: signing, publishing, the convenience `publish*` helpers, NIP-17
    /// direct messages, NIP-51 private list items, and NIP-42 AUTH challenges.
    ///
    /// While ``authenticationMode`` is ``AuthenticationMode/automatic`` (the default), setting a
    /// signer also starts answering NIP-42 AUTH challenges with it on every relay in the pool.
    public func setSigner(_ signer: any NostrSigning) async throws {
        try await client.install(signer)
    }

    /// Sets the signer from a private key hex string. See ``setSigner(_:)-(EventSigner)``.
    public func setPrivateKey(_ privateKeyHex: String) async throws {
        await client.install(try EventSigner(privateKeyHex: privateKeyHex))
    }

    /// Sets the signer from an nsec. See ``setSigner(_:)-(EventSigner)``.
    public func setNsec(_ nsec: String) async throws {
        await client.install(try EventSigner(nsec: nsec))
    }

    /// The public key events are authored under, or nil when no signer is set.
    public var publicKey: String? {
        get async { await client.cachedPublicKey }
    }

    /// The signer's public key as an npub, or nil when no signer is set.
    public var npub: String? {
        get async throws { try await client.currentNpub() }
    }

    /// Signs an event with the configured signer, local or remote.
    ///
    /// Build an ``UnsignedEvent`` with ``publicKey`` as its pubkey; combine with
    /// ``NostrEventsAPI/publish(_:strategy:)`` to author and publish an event this library has
    /// no helper for.
    /// - Parameter unsignedEvent: The event to sign; its `pubkey` should be ``publicKey``.
    /// - Returns: The signed ``Event``.
    /// - Throws: ``NostrError/signerNotSet`` if no signer is set, plus anything the signer throws.
    public func sign(_ unsignedEvent: UnsignedEvent) async throws -> Event {
        try await client.activeSign(unsignedEvent)
    }

    // MARK: - Authentication (NIP-42)

    /// How the client reacts to relay AUTH challenges.
    public var authenticationMode: AuthenticationMode {
        get async { await client.currentAuthenticationMode }
    }

    /// Sets how the client reacts to AUTH challenges and rewires the relay
    /// pool accordingly.
    ///
    /// Switching to ``AuthenticationMode/automatic`` with a signer configured
    /// also answers challenges that relays have already issued.
    public func setAuthenticationMode(_ mode: AuthenticationMode) async {
        await client.apply(authenticationMode: mode)
    }

    /// Answers the pending AUTH challenge of the given relay with the
    /// configured signer and waits for the relay's OK (NIP-42).
    ///
    /// This is the explicit path for ``AuthenticationMode/manual``; with
    /// ``AuthenticationMode/automatic`` (the default) challenges are answered
    /// for you. The challenge is delivered by the relay and surfaces as
    /// ``SubscriptionEvent/auth(relayURL:challenge:)`` on active subscriptions.
    ///
    /// In the unlikely case that the relay rotates its challenge between this
    /// call reading it and the relay receiving the answer, the relay rejects
    /// the stale answer and this throws ``NostrError/authenticationFailed(_:)``
    /// — simply call it again to answer the fresh challenge.
    ///
    /// - Parameter relayURL: The relay to authenticate to; must be in the pool.
    /// - Throws: ``NostrError/noMatchingRelays(_:)`` when the relay is not in the
    ///   pool, ``NostrError/signerNotSet`` without a signer, and everything
    ///   ``RelayConnection/authenticate(with:)`` throws.
    public func authenticate(relayURL: URL) async throws {
        guard let connection = await client.pool.relay(for: relayURL) else {
            throw NostrError.noMatchingRelays([RelayURL.normalize(relayURL.absoluteString)])
        }
        guard let challenge = await connection.authenticationChallenge else {
            throw NostrError.authenticationFailed("The relay has not sent an AUTH challenge")
        }
        let event = try await client.clientAuthenticationEvent(relayURL: connection.url, challenge: challenge)
        try await connection.authenticate(with: event)
    }
}
