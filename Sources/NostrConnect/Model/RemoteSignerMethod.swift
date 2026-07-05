/// A NIP-46 remote-signing method name; the raw value is the wire token.
///
/// The token is the `method` string carried in a request envelope.
/// https://github.com/nostr-protocol/nips/blob/master/46.md
public enum RemoteSignerMethod: String, Sendable, Hashable, CaseIterable {
    /// Establish a session with the remote signer, optionally passing a secret and requested
    /// permissions.
    case connect
    /// Sign an event supplied as a JSON string; the signer returns the signed event.
    case signEvent = "sign_event"
    /// Check that the remote signer is reachable; the signer replies with `pong`.
    case ping
    /// Ask the remote signer for the user public key it signs with.
    case getPublicKey = "get_public_key"
    /// Encrypt a message to a recipient using NIP-04.
    case nip04Encrypt = "nip04_encrypt"
    /// Decrypt a NIP-04 message from a sender.
    case nip04Decrypt = "nip04_decrypt"
    /// Encrypt a message to a recipient using NIP-44.
    case nip44Encrypt = "nip44_encrypt"
    /// Decrypt a NIP-44 message from a sender.
    case nip44Decrypt = "nip44_decrypt"
    /// Ask the remote signer to move the session to a new set of relays.
    case switchRelays = "switch_relays"
    /// End the session; the remote signer discards it.
    case logout
}
