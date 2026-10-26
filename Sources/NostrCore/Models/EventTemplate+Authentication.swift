import Crypto
import Foundation

// MARK: - Relay Authentication (NIP-42)
extension EventTemplate {
    /// A client authentication event (kind 22242) answering a relay's AUTH challenge.
    ///
    /// The event carries the relay URL and the challenge as tags and an empty content. It is
    /// ephemeral: relays validate it during the AUTH handshake and neither store nor broadcast it.
    /// https://github.com/nostr-protocol/nips/blob/master/42.md
    /// - Parameters:
    ///   - relayURL: The URL of the relay being authenticated to.
    ///   - challenge: The challenge string received in the relay's AUTH message.
    /// - Returns: The template for the authentication event.
    public static func clientAuthentication(relayURL: RelayURL, challenge: String) -> EventTemplate {
        EventTemplate(kind: .clientAuthentication, tags: [.relay(relayURL), .challenge(challenge)])
    }
}

// MARK: - HTTP Authorization (NIP-98)
extension EventTemplate {
    /// An HTTP authorization event (kind 27235) for a request to `url`, sent in the request's
    /// `Authorization` header via ``HTTPAuth/authorizationHeaderValue(for:)``.
    ///
    /// The "u" tag is the exact absolute URL — servers compare it including query parameters — and
    /// the "method" tag is `method` uppercased. When `payload` is given, a "payload" tag carries its
    /// lowercase hex SHA-256; include the body of POST/PUT/PATCH requests so servers can bind the
    /// authorization to it. The content is empty. Servers reject events outside a small window
    /// around their clock (the NIP suggests 60 seconds), and the template's ``createdAt`` is set
    /// when it is built, so build and sign it immediately before sending.
    /// https://github.com/nostr-protocol/nips/blob/master/98.md
    /// - Parameters:
    ///   - url: The absolute request URL, including any query parameters.
    ///   - method: The HTTP request method, e.g. "GET" or "POST".
    ///   - payload: The request body to commit to in a "payload" tag, if any.
    /// - Returns: The template for the authorization event.
    public static func httpAuthorization(url: URL, method: String, payload: Data? = nil) -> EventTemplate {
        var tags: [Tag] = [.url(url.absoluteString), .method(method.uppercased())]
        if let payload {
            tags.append(.payload(sha256: Data(SHA256.hash(data: payload)).hexEncodedString()))
        }
        return EventTemplate(kind: .httpAuth, tags: tags)
    }
}
