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
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` carrying `string` when it does not parse,
    ///   its scheme is not `ws` or `wss`, its host is empty, or it has a fragment or a user or
    ///   password.
    public init(string: String) throws {
        guard let components = URLComponents(string: string),
            let scheme = components.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
            let host = components.host, !host.isEmpty,
            components.fragment == nil,
            components.user == nil, components.password == nil
        else {
            throw NostrError.invalidRelayURL(string)
        }
        let canonical = Self.normalize(string)
        guard let url = URL(string: canonical) else {
            throw NostrError.invalidRelayURL(string)
        }
        self.canonical = canonical
        self.url = url
    }

    /// Creates a relay URL from a URL, normalizing it to its canonical form.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` carrying `url.absoluteString` when its scheme
    ///   is not `ws` or `wss`, its host is empty, or it has a fragment or a user or password.
    public init(url: URL) throws {
        try self.init(string: url.absoluteString)
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

extension RelayURL {
    /// Normalizes a relay URL string into its canonical form without validating it: lowercased
    /// scheme and host, a root trailing slash stripped, and default ports removed. A string that
    /// does not parse as a URL with a host is lowercased and loses one trailing slash instead.
    ///
    /// Used to build ``RelayURL`` values and to de-duplicate relay-list entries that are stored
    /// as strings — never to rewrite those entries, so relay tags round-trip exactly.
    package static func normalize(_ string: String) -> String {
        guard var components = URLComponents(string: string), let host = components.host, !host.isEmpty else {
            var normalized = string.lowercased()  // unparseable: legacy whole-string rule
            if normalized.hasSuffix("/") { normalized.removeLast() }
            return normalized
        }
        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        if components.path == "/" { components.path = "" }  // root slash only; /a/ ≠ /a
        switch (components.scheme, components.port) {
        case ("wss", 443), ("ws", 80): components.port = nil
        default: break
        }
        return components.string ?? string
    }
}

extension Set<RelayURL> {
    /// Parses relay URL strings into a set, skipping every entry that is not a valid WebSocket
    /// relay URL. Lenient by design: it ingests third-party relay lists (NIP-65 / NIP-17 tag
    /// content), where one malformed entry must not discard the rest.
    package init(parsingValid strings: some Sequence<String>) {
        self.init(strings.compactMap(RelayURL.init))
    }
}
