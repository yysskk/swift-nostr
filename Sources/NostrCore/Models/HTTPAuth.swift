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
/// Without a `URLRequest`, sign
/// ``EventTemplate/httpAuthorization(url:method:payload:)`` and encode the
/// event with ``authorizationHeaderValue(for:)``:
///
/// ```swift
/// let event = try await signer.sign(.httpAuthorization(url: uploadURL, method: "POST", payload: body))
/// let header = try HTTPAuth.authorizationHeaderValue(for: event)
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/98.md
public enum HTTPAuth {
    /// The HTTP header field a NIP-98 event travels in: "Authorization".
    public static let headerField = "Authorization"

    /// The `Authorization` scheme identifying a NIP-98 credential: "Nostr".
    public static let scheme = "Nostr"

    /// Encodes a signed kind-27235 event as an `Authorization` header value:
    /// the scheme "Nostr", a space, and the base64-encoded event JSON.
    ///
    /// - Parameter event: A signed NIP-98 event, e.g. signed from
    ///   ``EventTemplate/httpAuthorization(url:method:payload:)``.
    /// - Returns: The header value, e.g. `"Nostr eyJpZCI6…"`.
    /// - Throws: ``HTTPAuth/AuthorizationError/invalidEventKind(_:)`` when `event` is not
    ///   kind 27235.
    public static func authorizationHeaderValue(for event: Event) throws -> String {
        guard event.kind == .httpAuth else { throw AuthorizationError.invalidEventKind(event.kind) }
        let json = try JSONEncoder().encode(event)
        return "\(scheme) \(json.base64EncodedString())"
    }

    /// Why a request could not be given a NIP-98 `Authorization` header.
    public enum AuthorizationError: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The event is not kind 27235 (payload: the kind it has).
        case invalidEventKind(Event.Kind)
        /// The request has no URL for the event to commit to.
        case missingURL

        public var errorDescription: String? {
            switch self {
            case .invalidEventKind(let kind):
                return "Expected a kind-27235 authorization event, got kind \(kind)"
            case .missingURL:
                return "The request has no URL to authorize"
            }
        }
    }
}

// MARK: - Validation
extension HTTPAuth {
    /// Why an `Authorization` header failed NIP-98 validation.
    public enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        /// The header value does not start with the "Nostr" scheme.
        case invalidAuthorizationScheme
        /// The credential is not valid base64.
        case invalidBase64
        /// The base64 payload is not a NIP-01 event JSON object.
        case malformedEvent
        /// The event is not kind 27235.
        case invalidEventKind(Event.Kind)
        /// The event id or signature does not verify.
        case invalidSignature
        /// The event timestamp is outside the accepted window around the
        /// server's clock.
        case timestampOutOfTolerance(createdAt: Timestamp)
        /// The "u" tag does not match the request URL.
        case urlMismatch(expected: String, actual: String?)
        /// The "method" tag does not match the request method.
        case methodMismatch(expected: String, actual: String?)
        /// The "payload" tag does not match the request body's SHA-256.
        case payloadHashMismatch(expected: String, actual: String?)

        public var errorDescription: String? {
            switch self {
            case .invalidAuthorizationScheme:
                return "The Authorization header does not use the Nostr scheme"
            case .invalidBase64:
                return "The Nostr credential is not valid base64"
            case .malformedEvent:
                return "The Nostr credential does not decode to an event"
            case .invalidEventKind(let kind):
                return "Expected a kind-27235 authorization event, got kind \(kind)"
            case .invalidSignature:
                return "The authorization event's id or signature does not verify"
            case .timestampOutOfTolerance(let createdAt):
                return "The authorization event timestamp \(createdAt) is outside the accepted window"
            case .urlMismatch(let expected, let actual):
                return "The u tag (\(actual ?? "missing")) does not match the request URL \(expected)"
            case .methodMismatch(let expected, let actual):
                return "The method tag (\(actual ?? "missing")) does not match the request method \(expected)"
            case .payloadHashMismatch(let expected, let actual):
                return "The payload tag (\(actual ?? "missing")) does not match the request body hash \(expected)"
            }
        }
    }

    /// Validates the `Authorization` header of an incoming HTTP request and
    /// returns the verified kind-27235 event.
    ///
    /// Performs the NIP-98 server-side checks in order: the "Nostr" scheme,
    /// base64 and event decoding (unpadded base64 is accepted), the event
    /// kind, the event id and signature, the timestamp window, the exact
    /// "u"-tag match against the request URL (including query parameters), the
    /// case-insensitive "method"-tag match, and — when `payload` is given — a
    /// "payload" tag matching the body's SHA-256. On success the caller can
    /// trust ``Event/publicKey`` as the authenticated identity.
    ///
    /// > Note: NIP-98 has no nonce, so within the tolerance window a captured
    /// > header replays verbatim — validation alone cannot tell a resent
    /// > credential from a fresh one. Endpoints for which that matters should
    /// > additionally reject an ``Event/id`` they have already seen within the
    /// > window.
    ///
    /// - Parameters:
    ///   - authorization: The full header value, e.g. `"Nostr eyJpZCI6…"`.
    ///   - url: The absolute URL the server received the request on.
    ///   - method: The HTTP method of the received request, e.g. "GET".
    ///   - payload: The received request body; when non-nil the event must
    ///     commit to it with a matching "payload" tag, so a request whose body
    ///     was not signed is rejected. Pass nil to skip the payload check.
    ///   - tolerance: How far, in either direction, the event timestamp may
    ///     deviate from `now`. Defaults to the NIP-98 suggestion of 60
    ///     seconds.
    ///   - now: The server's current time; injectable for testing.
    /// - Returns: The verified authorization event.
    /// - Throws: ``ValidationError`` naming the first failed check.
    public static func validate(
        authorization: String,
        url: URL,
        method: String,
        payload: Data? = nil,
        tolerance: Duration = .seconds(60),
        now: Timestamp = .now
    ) throws(ValidationError) -> Event {
        let event = try event(fromAuthorizationHeader: authorization)

        guard event.kind == .httpAuth else {
            throw ValidationError.invalidEventKind(event.kind)
        }
        guard (try? event.verify()) == true else {
            throw ValidationError.invalidSignature
        }
        let skew = now.duration(to: event.createdAt)
        guard skew <= tolerance, skew >= .zero - tolerance else {
            throw ValidationError.timestampOutOfTolerance(createdAt: event.createdAt)
        }
        let urlTag = event.firstTagValue(named: "u")
        guard urlTag == url.absoluteString else {
            throw ValidationError.urlMismatch(expected: url.absoluteString, actual: urlTag)
        }
        let methodTag = event.firstTagValue(named: "method")
        guard methodTag?.uppercased() == method.uppercased() else {
            throw ValidationError.methodMismatch(expected: method, actual: methodTag)
        }
        if let payload {
            let expected = Data(SHA256.hash(data: payload)).hexEncodedString()
            let payloadTag = event.firstTagValue(named: "payload")
            guard payloadTag?.lowercased() == expected else {
                throw ValidationError.payloadHashMismatch(expected: expected, actual: payloadTag)
            }
        }
        return event
    }

    /// Decodes the event carried in an `Authorization` header value, without
    /// validating it against a request. Prefer
    /// ``validate(authorization:url:method:payload:tolerance:now:)`` — this is
    /// the shared decoding step, useful on its own for logging or debugging.
    ///
    /// - Parameter header: The full header value, e.g. `"Nostr eyJpZCI6…"`.
    /// - Returns: The decoded — but unverified — event.
    /// - Throws: ``ValidationError/invalidAuthorizationScheme``,
    ///   ``ValidationError/invalidBase64``, or
    ///   ``ValidationError/malformedEvent``.
    public static func event(fromAuthorizationHeader header: String) throws(ValidationError) -> Event {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == scheme.lowercased() else {
            throw ValidationError.invalidAuthorizationScheme
        }
        var base64 = String(parts[1])
        // Some producers emit unpadded base64; restore the padding.
        if base64.count % 4 != 0 {
            base64.append(String(repeating: "=", count: 4 - base64.count % 4))
        }
        guard let json = Data(base64Encoded: base64) else {
            throw ValidationError.invalidBase64
        }
        guard let event = try? JSONDecoder().decode(Event.self, from: json) else {
            throw ValidationError.malformedEvent
        }
        return event
    }
}

// MARK: - URLRequest Convenience
extension URLRequest {
    /// Signs this request's URL, method, and body into a NIP-98 event and sets
    /// the `Authorization` header to `Nostr <base64(event JSON)>`.
    ///
    /// The request must already be in its final form: the event commits to the
    /// exact URL (including query parameters), the HTTP method, and — when
    /// `httpBody` is set — the body's SHA-256. A body supplied as
    /// `httpBodyStream` cannot be read without consuming it and is not
    /// committed to. Call immediately before sending; servers reject events
    /// whose timestamp falls outside a small window around their clock.
    ///
    /// - Parameter signer: The identity to sign as.
    /// - Throws: ``HTTPAuth/AuthorizationError/missingURL`` when the request has no URL, and
    ///   whatever `signer` throws.
    public mutating func setNostrAuthorization(signer: some NostrSigning) async throws {
        guard let url else { throw HTTPAuth.AuthorizationError.missingURL }
        let event = try await signer.sign(
            .httpAuthorization(url: url, method: httpMethod ?? "GET", payload: httpBody)
        )
        setValue(try HTTPAuth.authorizationHeaderValue(for: event), forHTTPHeaderField: HTTPAuth.headerField)
    }
}
