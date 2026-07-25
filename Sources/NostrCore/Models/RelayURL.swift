import Foundation

/// Helpers for working with Nostr relay URLs.
package enum RelayURL {
    /// Normalizes a relay URL into a canonical routing key: lowercased scheme and host
    /// (the only RFC-case-insensitive parts — the key also opens the WebSocket, so path
    /// case is preserved), a root trailing slash stripped, and default ports removed.
    ///
    /// Used only for de-duplication and pool routing — never to mutate a stored
    /// URL, so relay tags round-trip exactly.
    package static func normalize(_ url: String) -> String {
        guard var components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            var normalized = url.lowercased()  // unparseable: legacy whole-string rule
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
        return components.string ?? url
    }

    /// Parses `string` into a URL under its canonical routing key (see ``normalize(_:)``).
    package static func normalizedURL(_ string: String) -> URL? { URL(string: normalize(string)) }

    /// Rebuilds `url` under its canonical routing key, falling back to `url` itself
    /// when the normalized form does not re-parse.
    package static func normalizedURL(_ url: URL) -> URL { normalizedURL(url.absoluteString) ?? url }

    /// Parses a relay URL string into its canonical routing key, enforcing that it is
    /// usable as a WebSocket relay endpoint.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` when the string does not parse, the
    ///   scheme is not `ws`/`wss`, the host is empty, or a fragment or user/password is present.
    package static func requireTarget(_ string: String) throws -> URL {
        guard let components = URLComponents(string: string),
            let scheme = components.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
            let host = components.host, !host.isEmpty,
            components.fragment == nil,
            components.user == nil, components.password == nil,
            let url = normalizedURL(string)
        else {
            throw NostrError.invalidRelayURL(string)
        }
        return url
    }

    /// Parses each string via ``requireTarget(_:)`` into a de-duplicated target set,
    /// throwing on the first invalid entry.
    package static func requireTargets(_ strings: [String]) throws -> Set<URL> {
        Set(try strings.map(requireTarget))
    }

    /// Parses relay URL strings into a de-duplicated `Set<URL>`, skipping entries that
    /// are not valid WebSocket relay URLs (see ``requireTarget(_:)``). Lenient by
    /// design: it ingests third-party relay-list tag content (NIP-65 / NIP-17), where
    /// one garbage entry must not discard the rest.
    package static func urlSet(_ strings: [String]) -> Set<URL> {
        Set(strings.compactMap { try? requireTarget($0) })
    }
}
