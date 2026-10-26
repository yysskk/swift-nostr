/// A NIP-46 remote-signing method name; the raw value is the wire token.
///
/// The token is the `method` string carried in a request envelope, and it encodes as a bare JSON
/// string. The set is open: a NIP-46 signer may implement methods this package does not model, so
/// create those with ``init(rawValue:)`` and call them with ``RemoteSigner/send(_:params:)``.
/// https://github.com/nostr-protocol/nips/blob/master/46.md
public struct RemoteSignerMethod: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    /// The wire token for this method.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }

    /// Establish a session with the remote signer, optionally passing a secret and requested
    /// permissions.
    public static let connect = RemoteSignerMethod(rawValue: "connect")
    /// Sign an event supplied as a JSON string; the signer returns the signed event.
    public static let signEvent = RemoteSignerMethod(rawValue: "sign_event")
    /// Check that the remote signer is reachable; the signer replies with `pong`.
    public static let ping = RemoteSignerMethod(rawValue: "ping")
    /// Ask the remote signer for the user public key it signs with.
    public static let getPublicKey = RemoteSignerMethod(rawValue: "get_public_key")
    /// Encrypt a message to a recipient using NIP-04.
    public static let nip04Encrypt = RemoteSignerMethod(rawValue: "nip04_encrypt")
    /// Decrypt a NIP-04 message from a sender.
    public static let nip04Decrypt = RemoteSignerMethod(rawValue: "nip04_decrypt")
    /// Encrypt a message to a recipient using NIP-44.
    public static let nip44Encrypt = RemoteSignerMethod(rawValue: "nip44_encrypt")
    /// Decrypt a NIP-44 message from a sender.
    public static let nip44Decrypt = RemoteSignerMethod(rawValue: "nip44_decrypt")
    /// Ask the remote signer to move the session to a new set of relays.
    public static let switchRelays = RemoteSignerMethod(rawValue: "switch_relays")
    /// End the session; the remote signer discards it.
    public static let logout = RemoteSignerMethod(rawValue: "logout")
}
