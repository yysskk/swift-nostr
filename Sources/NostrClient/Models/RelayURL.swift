import Foundation

/// Helpers for working with Nostr relay URLs.
enum RelayURL {
    /// Normalizes a relay URL into a comparison/routing key: lowercased, with a
    /// single trailing slash removed.
    ///
    /// Used only for de-duplication and pool routing — never to mutate a stored
    /// URL, so relay tags round-trip exactly.
    static func normalize(_ url: String) -> String {
        var normalized = url.lowercased()
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Parses relay URL strings into a de-duplicated `Set<URL>`, normalizing each
    /// (see ``normalize(_:)``) and dropping any that don't parse as a URL.
    static func urlSet(_ strings: [String]) -> Set<URL> {
        Set(strings.compactMap { URL(string: normalize($0)) })
    }
}
