import Foundation

/// The URL of a Nostr relay: a validated `ws` or `wss` WebSocket URL in its canonical form.
///
/// The canonical form lowercases the scheme and host (the only parts URLs treat
/// case-insensitively — the path is preserved, since the same URL also opens the WebSocket),
/// strips a root trailing slash, and drops the scheme's default port (`443` for `wss`, `80` for
/// `ws`). A non-root trailing slash is kept: `wss://host/a/` and `wss://host/a` stay distinct.
/// Two relay URLs are equal exactly when their canonical forms are, so `wss://Relay.Example.com/`
/// and `wss://relay.example.com:443` name the same relay, which makes the value a routing key for
/// the relay pool, publish results, and relay sets.
///
/// ``description`` is the canonical string, and the value encodes to and from JSON as it.
public struct RelayURL: Sendable {
    /// The canonical URL string, ``description``.
    private let canonical: String

    /// The relay's canonical URL, used to open its WebSocket.
    public let url: URL

    /// Creates a relay URL from a string, normalizing it to its canonical form.
    /// - Throws: ``RelayURL/Error/malformed`` when `string` does not parse as a URL with a scheme,
    ///   ``RelayURL/Error/unsupportedScheme(_:)`` when its scheme is not `ws` or `wss`,
    ///   ``RelayURL/Error/missingHost`` when its host is empty, ``RelayURL/Error/containsFragment``
    ///   when it has a fragment, or ``RelayURL/Error/containsCredentials`` when it has a user or
    ///   password.
    public init(string: String) throws(RelayURL.Error) {
        guard var components = URLComponents(string: string),
            let scheme = components.scheme?.lowercased()
        else {
            throw .malformed
        }
        guard scheme == "wss" || scheme == "ws" else {
            throw .unsupportedScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw .missingHost
        }
        guard components.fragment == nil else {
            throw .containsFragment
        }
        guard components.user == nil, components.password == nil else {
            throw .containsCredentials
        }
        components.scheme = scheme
        components.host = host.lowercased()
        if components.path == "/" { components.path = "" }  // root slash only; /a/ ≠ /a
        if (scheme, components.port) == ("wss", 443) || (scheme, components.port) == ("ws", 80) {
            components.port = nil
        }
        guard let canonical = components.string, let url = URL(string: canonical) else {
            throw .malformed
        }
        self.canonical = canonical
        self.url = url
    }

    /// Creates a relay URL from a URL, normalizing it to its canonical form.
    /// - Throws: What ``init(string:)`` throws for `url.absoluteString`.
    public init(url: URL) throws(RelayURL.Error) {
        try self.init(string: url.absoluteString)
    }
}

extension RelayURL {
    /// Why a string or URL is not a valid ``RelayURL``.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The string does not parse as a URL with a scheme.
        case malformed
        /// The scheme is not `ws` or `wss` (payload: the scheme found, lowercased).
        case unsupportedScheme(String)
        /// The URL has no host, or an empty one.
        case missingHost
        /// The URL has a fragment, which a WebSocket URL must not carry.
        case containsFragment
        /// The URL has a user or password.
        case containsCredentials

        public var errorDescription: String? {
            switch self {
            case .malformed:
                return "A relay URL must be a ws:// or wss:// URL"
            case .unsupportedScheme(let scheme):
                return "A relay URL must use ws or wss, got \(scheme)"
            case .missingHost:
                return "A relay URL must have a host"
            case .containsFragment:
                return "A relay URL must not have a fragment"
            case .containsCredentials:
                return "A relay URL must not carry a user or password"
            }
        }
    }
}

extension RelayURL: Hashable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canonical == rhs.canonical
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonical)
    }
}

extension RelayURL: CustomStringConvertible, LosslessStringConvertible {
    /// The relay URL's canonical string.
    public var description: String {
        canonical
    }

    /// Creates a relay URL from a string, normalizing it to its canonical form, or returns `nil`
    /// when ``init(string:)`` would throw.
    public init?(_ description: String) {
        try? self.init(string: description)
    }
}

extension RelayURL: Codable {
    /// Decodes a relay URL from a string, normalizing it to its canonical form.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not a valid WebSocket relay URL.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = RelayURL(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "A relay URL must be a ws:// or wss:// URL with a host")
        }
        self = value
    }

    /// Encodes the relay URL as its canonical string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonical)
    }
}
