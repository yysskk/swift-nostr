import Foundation
import NostrCore

/// How ``NostrClient`` reacts to NIP-42 AUTH challenges from relays.
/// https://github.com/nostr-protocol/nips/blob/master/42.md
public enum AuthenticationMode: Sendable, Hashable {
    /// Challenges are answered automatically with the configured signer.
    ///
    /// This is the default: relays that require authentication — typically to
    /// serve DMs or accept writes — work without further code. Note that
    /// authenticating reveals the signer's pubkey to the relay; choose
    /// ``manual`` when that link should only be made deliberately.
    case automatic

    /// Challenges are only answered when ``NostrClient/authenticate(relayURL:)``
    /// is called explicitly.
    case manual
}

// MARK: - Authentication (NIP-42)
extension NostrClient {
    /// Sets how the client reacts to AUTH challenges and rewires the relay
    /// pool accordingly.
    ///
    /// Switching to ``AuthenticationMode/automatic`` with a signer configured
    /// also answers challenges that relays have already issued.
    public func setAuthenticationMode(_ mode: AuthenticationMode) async {
        authenticationMode = mode
        await refreshAuthenticationResponder()
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
        guard let connection = await relayPool.relay(for: relayURL) else {
            throw NostrError.noMatchingRelays([RelayURL.normalize(relayURL.absoluteString)])
        }
        guard let challenge = await connection.authenticationChallenge else {
            throw NostrError.authenticationFailed("The relay has not sent an AUTH challenge")
        }
        let event = try await clientAuthenticationEvent(relayURL: connection.url, challenge: challenge)
        try await connection.authenticate(with: event)
    }

    /// Installs or clears the pool-wide AUTH responder to match the current
    /// signer and ``authenticationMode``. Called whenever either changes.
    func refreshAuthenticationResponder() async {
        guard hasSigner, authenticationMode == .automatic else {
            await relayPool.setAuthenticationResponder(nil)
            return
        }
        await relayPool.setAuthenticationResponder { [weak self] relayURL, challenge in
            await self?.signAuthenticationResponse(relayURL: relayURL, challenge: challenge)
        }
    }

    /// Signs the kind-22242 answer to a challenge, or returns `nil` when the
    /// signer is gone or the mode changed since the responder was installed.
    ///
    /// Signing goes through ``activeSign(_:)`` so a remote NIP-46 signer can answer challenges
    /// too, resolving its signature via a relay round-trip.
    private func signAuthenticationResponse(relayURL: URL, challenge: String) async -> Event? {
        guard authenticationMode == .automatic else { return nil }
        return try? await clientAuthenticationEvent(relayURL: relayURL, challenge: challenge)
    }

    /// Builds and signs a kind-22242 client-authentication event (NIP-42) via the active signer, so
    /// both the automatic responder and the manual ``authenticate(relayURL:)`` support a local or a
    /// remote signer. Throws ``NostrError/signerNotSet`` when no signer is configured.
    private func clientAuthenticationEvent(relayURL: URL, challenge: String) async throws -> Event {
        guard let cachedPublicKey = publicKey else { throw NostrError.signerNotSet }
        let unsigned = UnsignedEvent(
            pubkey: cachedPublicKey,
            kind: .clientAuthentication,
            tags: [.relay(relayURL.absoluteString), .challenge(challenge)],
            content: ""
        )
        return try await activeSign(unsigned)
    }
}
