import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// NIP-98 HTTP authorization: signed kind-27235 events proving the request
/// author's identity to an HTTP server.
///
/// A NIP-98 event is never published to relays. It carries the absolute
/// request URL in a "u" tag and the HTTP method in a "method" tag (plus an
/// optional "payload" tag with the SHA-256 of the request body), and travels
/// base64-encoded in the `Authorization` header:
///
/// ```
/// Authorization: Nostr <base64(event JSON)>
/// ```
///
/// Sign a request with any ``NostrSigning`` signer — a local ``EventSigner``
/// or a remote NIP-46 signer:
///
/// ```swift
/// var request = URLRequest(url: uploadURL)
/// request.httpMethod = "POST"
/// request.httpBody = body
/// try await request.setNostrAuthorization(signer: signer)
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/98.md
public enum HTTPAuth {
    /// The HTTP header field a NIP-98 event travels in: "Authorization".
    public static let headerField = "Authorization"

    /// The `Authorization` scheme identifying a NIP-98 credential: "Nostr".
    public static let scheme = "Nostr"

    /// Builds and signs a kind-27235 authorization event for an HTTP request.
    ///
    /// The event's "u" tag is the exact absolute URL — servers compare it
    /// including query parameters — and the "method" tag is `method`
    /// uppercased. When `payload` is given, a "payload" tag carries its
    /// lowercase hex SHA-256; include the body of POST/PUT/PATCH requests so
    /// servers can bind the authorization to it.
    ///
    /// - Parameters:
    ///   - url: The absolute request URL, including any query parameters.
    ///   - method: The HTTP request method, e.g. "GET" or "POST".
    ///   - payload: The request body to commit to in a "payload" tag, if any.
    ///   - createdAt: The event timestamp; servers reject events outside a
    ///     small window around their clock (the NIP suggests 60 seconds), so
    ///     sign immediately before sending. Defaults to now.
    ///   - signer: The identity to sign as; a remote signer resolves the
    ///     signature via a relay round-trip.
    /// - Returns: The signed kind-27235 event.
    /// - Throws: Whatever `signer` throws while resolving its public key or
    ///   signing.
    public static func authorizationEvent(
        url: URL,
        method: String,
        payload: Data? = nil,
        createdAt: Date = Date(),
        signer: some NostrSigning
    ) async throws -> Event {
        var tags: [Tag] = [
            .url(url.absoluteString),
            .method(method.uppercased()),
        ]
        if let payload {
            tags.append(.payload(sha256: Data(SHA256.hash(data: payload)).hexEncodedString()))
        }
        let unsigned = UnsignedEvent(
            pubkey: try await signer.publicKey,
            createdAt: Int64(createdAt.timeIntervalSince1970),
            kind: .httpAuth,
            tags: tags,
            content: ""
        )
        return try await signer.sign(unsigned)
    }

    /// Encodes a signed kind-27235 event as an `Authorization` header value:
    /// the scheme "Nostr", a space, and the base64-encoded event JSON.
    ///
    /// - Parameter event: A signed NIP-98 event, e.g. from
    ///   ``authorizationEvent(url:method:payload:createdAt:signer:)``.
    /// - Returns: The header value, e.g. `"Nostr eyJpZCI6…"`.
    /// - Throws: ``NostrError/invalidData`` when `event` is not kind 27235.
    public static func authorizationHeaderValue(for event: Event) throws -> String {
        guard event.kind == .httpAuth else { throw NostrError.invalidData }
        let json = try JSONEncoder().encode(event)
        return "\(scheme) \(json.base64EncodedString())"
    }

    /// Builds, signs, and encodes an authorization event in one call.
    ///
    /// See ``authorizationEvent(url:method:payload:createdAt:signer:)`` for
    /// the parameters and ``authorizationHeaderValue(for:)`` for the header
    /// format.
    ///
    /// - Returns: The `Authorization` header value, e.g. `"Nostr eyJpZCI6…"`.
    public static func authorizationHeaderValue(
        url: URL,
        method: String,
        payload: Data? = nil,
        createdAt: Date = Date(),
        signer: some NostrSigning
    ) async throws -> String {
        try authorizationHeaderValue(
            for: await authorizationEvent(
                url: url, method: method, payload: payload, createdAt: createdAt, signer: signer
            )
        )
    }
}

// MARK: - URLRequest Convenience
extension URLRequest {
    /// Signs this request's URL, method, and body into a NIP-98 event and sets
    /// the `Authorization` header to `Nostr <base64(event JSON)>`.
    ///
    /// The request must already be in its final form: the event commits to the
    /// exact URL (including query parameters), the HTTP method, and — when
    /// ``httpBody`` is set — the body's SHA-256. A body supplied as
    /// ``httpBodyStream`` cannot be read without consuming it and is not
    /// committed to. Call immediately before sending; servers reject events
    /// whose timestamp falls outside a small window around their clock.
    ///
    /// - Parameter signer: The identity to sign as.
    /// - Throws: ``NostrError/invalidData`` when the request has no URL, and
    ///   whatever `signer` throws.
    public mutating func setNostrAuthorization(signer: some NostrSigning) async throws {
        guard let url else { throw NostrError.invalidData }
        let value = try await HTTPAuth.authorizationHeaderValue(
            url: url,
            method: httpMethod ?? "GET",
            payload: httpBody,
            signer: signer
        )
        setValue(value, forHTTPHeaderField: HTTPAuth.headerField)
    }
}
