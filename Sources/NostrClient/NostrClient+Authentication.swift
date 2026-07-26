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

    /// Challenges are only answered when ``NostrIdentityAPI/authenticate(relayURL:)``
    /// is called explicitly.
    case manual
}

// MARK: - Authentication (NIP-42) — actor-isolated internals
//
// The public surface lives on ``NostrIdentityAPI``; what stays here is the state the
// responder mutates and the signing it needs, both of which require the client's isolation.
extension NostrClient {
    /// Sets how the client reacts to AUTH challenges and rewires the relay pool accordingly.
    /// Backs ``NostrIdentityAPI/setAuthenticationMode(_:)``.
    func apply(authenticationMode mode: AuthenticationMode) async {
        currentAuthenticationMode = mode
        await refreshAuthenticationResponder()
    }

    /// Installs or clears the pool-wide AUTH responder to match the current
    /// signer and ``currentAuthenticationMode``. Called whenever either changes.
    func refreshAuthenticationResponder() async {
        guard hasSigner, currentAuthenticationMode == .automatic else {
            await pool.setAuthenticationResponder(nil)
            return
        }
        await pool.setAuthenticationResponder { [weak self] relayURL, challenge in
            await self?.signAuthenticationResponse(relayURL: relayURL, challenge: challenge)
        }
    }

    /// Signs the kind-22242 answer to a challenge, or returns `nil` when the
    /// signer is gone or the mode changed since the responder was installed.
    ///
    /// Signing goes through ``activeSign(_:)`` so a remote NIP-46 signer can answer challenges
    /// too, resolving its signature via a relay round-trip.
    private func signAuthenticationResponse(relayURL: URL, challenge: String) async -> Event? {
        guard currentAuthenticationMode == .automatic else { return nil }
        return try? await clientAuthenticationEvent(relayURL: relayURL, challenge: challenge)
    }

    /// Builds and signs a kind-22242 client-authentication event (NIP-42) via the active signer, so
    /// both the automatic responder and the manual ``NostrIdentityAPI/authenticate(relayURL:)``
    /// support a local or a remote signer.
    /// - Throws: ``NostrError/signerNotSet`` when no signer is configured.
    func clientAuthenticationEvent(relayURL: URL, challenge: String) async throws -> Event {
        let unsigned = UnsignedEvent(
            pubkey: try requiredPublicKey(),
            kind: .clientAuthentication,
            tags: [.relay(relayURL.absoluteString), .challenge(challenge)],
            content: ""
        )
        return try await activeSign(unsigned)
    }
}
