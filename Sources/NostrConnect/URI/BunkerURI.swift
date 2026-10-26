import Foundation
public import NostrCore

/// A parsed NIP-46 `bunker://` connection token issued by a remote signer:
///
/// ```text
/// bunker://<remote-signer-public-key>?relay=<wss url>&relay=...&secret=<optional>
/// ```
///
/// - The host is the remote signer's public key in canonical lowercase hex, which is not
///   necessarily the user's key.
/// - `relay` is a relay the remote signer listens on; it may appear more than once.
/// - `secret` is an optional, single-use connection secret the client echoes back in its `connect`
///   request. Unlike the NIP-47 wallet secret it is an opaque string, not a 32-byte key.
///
/// https://github.com/nostr-protocol/nips/blob/master/46.md
public struct BunkerURI: Sendable, Hashable {
    /// The remote signer's public key — not necessarily the user's key.
    public let remoteSignerPublicKey: PublicKey

    /// The relays the remote signer listens on. Always at least one.
    public let relays: [RelayURL]

    /// The optional one-time connection secret to present in the `connect` request.
    public let secret: String?

    /// The URI scheme, without the `://` separator.
    public static let scheme = "bunker"

    /// Creates a token from its components.
    ///
    /// - Parameters:
    ///   - remoteSignerPublicKey: The remote signer's public key.
    ///   - relays: The relays the remote signer listens on (must contain at least one).
    ///   - secret: An optional one-time connection secret.
    /// - Throws: ``RemoteSignerError/invalidURI(reason:)`` if the relay list is empty.
    public init(remoteSignerPublicKey: PublicKey, relays: [RelayURL], secret: String? = nil) throws {
        guard !relays.isEmpty else {
            throw RemoteSignerError.invalidURI(reason: "at least one relay is required")
        }

        self.remoteSignerPublicKey = remoteSignerPublicKey
        self.relays = relays
        self.secret = secret
    }

    /// Parses a `bunker://` token.
    ///
    /// - Parameter string: The connection token issued by the remote signer.
    /// - Throws: ``RemoteSignerError/invalidURI(reason:)`` if the string is malformed or missing
    ///   required fields, including a host that is not a canonical lowercase hex public key or a
    ///   `relay` value that is not a valid relay URL.
    public init(string: String) throws {
        guard let components = URLComponents(string: string),
            components.scheme?.lowercased() == Self.scheme
        else {
            throw RemoteSignerError.invalidURI(reason: "scheme must be \(Self.scheme)://")
        }

        guard let host = components.host, !host.isEmpty else {
            throw RemoteSignerError.invalidURI(reason: "missing remote signer public key")
        }
        guard let remoteSignerPublicKey = PublicKey(host) else {
            throw RemoteSignerError.invalidURI(reason: "remote signer public key must be lowercase 32-byte hex")
        }

        let queryItems = components.queryItems ?? []

        // Every relay must parse: dropping a malformed one would make the token look like it
        // lists fewer relays than it does.
        let relayValues = queryItems.filter { $0.name == "relay" }.compactMap { $0.value }
        let relays = relayValues.compactMap(RelayURL.init)
        guard !relayValues.isEmpty, relays.count == relayValues.count else {
            throw RemoteSignerError.invalidURI(reason: "missing or malformed relay")
        }

        let secret = queryItems.first(where: { $0.name == "secret" })?.value

        try self.init(remoteSignerPublicKey: remoteSignerPublicKey, relays: relays, secret: secret)
    }

    /// The canonical connection string, with each relay and the secret percent-encoded.
    public var stringValue: String {
        var items = relays.map { URLQueryItem(name: "relay", value: $0.description) }
        if let secret {
            items.append(URLQueryItem(name: "secret", value: secret))
        }
        return "\(Self.scheme)://\(remoteSignerPublicKey)?\(URIQuery.encode(items))"
    }
}
