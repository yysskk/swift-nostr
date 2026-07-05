import Foundation
import NostrCore

/// A parsed NIP-46 `bunker://` connection token issued by a remote signer:
///
/// ```text
/// bunker://<remote-signer-pubkey>?relay=<wss url>&relay=...&secret=<optional>
/// ```
///
/// - The host is the remote signer's public key (hex), which is not necessarily the user's key.
/// - `relay` is a relay the remote signer listens on; it may appear more than once.
/// - `secret` is an optional, single-use connection secret the client echoes back in its `connect`
///   request. Unlike the NIP-47 wallet secret it is an opaque string, not a 32-byte key.
///
/// https://github.com/nostr-protocol/nips/blob/master/46.md
public struct BunkerURI: Sendable, Hashable {
    /// The remote signer's public key (32-byte hex) — not necessarily the user's key.
    public let remoteSignerPubkey: String

    /// The relays the remote signer listens on. Always at least one.
    public let relays: [URL]

    /// The optional one-time connection secret to present in the `connect` request.
    public let secret: String?

    /// The URI scheme, without the `://` separator.
    public static let scheme = "bunker"

    /// Creates a token from its components, validating the pubkey and relay list.
    ///
    /// - Parameters:
    ///   - remoteSignerPubkey: The remote signer's public key (must be 32-byte hex).
    ///   - relays: The relays the remote signer listens on (must contain at least one).
    ///   - secret: An optional one-time connection secret.
    /// - Throws: ``RemoteSignerError/invalidURI(reason:)`` if any field fails validation.
    public init(remoteSignerPubkey: String, relays: [URL], secret: String? = nil) throws {
        let normalizedPubkey = remoteSignerPubkey.lowercased()
        guard Data(hexString: normalizedPubkey)?.count == 32 else {
            throw RemoteSignerError.invalidURI(reason: "remote signer pubkey must be 32-byte hex")
        }
        guard !relays.isEmpty else {
            throw RemoteSignerError.invalidURI(reason: "at least one relay is required")
        }

        self.remoteSignerPubkey = normalizedPubkey
        self.relays = relays
        self.secret = secret
    }

    /// Parses a `bunker://` token.
    ///
    /// - Parameter string: The connection token issued by the remote signer.
    /// - Throws: ``RemoteSignerError/invalidURI(reason:)`` if the string is malformed or missing
    ///   required fields.
    public init(string: String) throws {
        guard let components = URLComponents(string: string),
            components.scheme?.lowercased() == Self.scheme
        else {
            throw RemoteSignerError.invalidURI(reason: "scheme must be \(Self.scheme)://")
        }

        guard let host = components.host, !host.isEmpty else {
            throw RemoteSignerError.invalidURI(reason: "missing remote signer pubkey")
        }

        let queryItems = components.queryItems ?? []

        let relayValues = queryItems.filter { $0.name == "relay" }.compactMap { $0.value }
        let relays = relayValues.compactMap { URL(string: $0) }
        guard !relayValues.isEmpty, relays.count == relayValues.count else {
            throw RemoteSignerError.invalidURI(reason: "missing or malformed relay")
        }

        let secret = queryItems.first(where: { $0.name == "secret" })?.value

        try self.init(remoteSignerPubkey: host, relays: relays, secret: secret)
    }

    /// The canonical connection string, with each relay and the secret percent-encoded.
    public var stringValue: String {
        var items = relays.map { URLQueryItem(name: "relay", value: $0.absoluteString) }
        if let secret {
            items.append(URLQueryItem(name: "secret", value: secret))
        }
        return "\(Self.scheme)://\(remoteSignerPubkey)?\(URIQuery.encode(items))"
    }
}
