import Foundation

/// Helpers for working with Nostr relay URLs.
enum RelayURL {
    /// Normalizes a relay URL into a canonical routing key: lowercased scheme and host
    /// (the only RFC-case-insensitive parts — the key also opens the WebSocket, so path
    /// case is preserved), a root trailing slash stripped, and default ports removed.
    ///
    /// Used only for de-duplication and pool routing — never to mutate a stored
    /// URL, so relay tags round-trip exactly.
    static func normalize(_ url: String) -> String {
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
    static func normalizedURL(_ string: String) -> URL? { URL(string: normalize(string)) }

    /// Rebuilds `url` under its canonical routing key, falling back to `url` itself
    /// when the normalized form does not re-parse.
    static func normalizedURL(_ url: URL) -> URL { normalizedURL(url.absoluteString) ?? url }

    /// Parses relay URL strings into a de-duplicated `Set<URL>`, normalizing each
    /// (see ``normalize(_:)``) and dropping any that don't parse as a URL.
    static func urlSet(_ strings: [String]) -> Set<URL> {
        Set(strings.compactMap { URL(string: normalize($0)) })
    }
}
