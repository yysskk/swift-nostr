import Foundation

/// Helpers for building the query strings of Nostr connection URIs.
///
/// `URLComponents.string` leaves reserved characters such as `:` and `/` unescaped inside query
/// values, so a relay like `wss://relay.example` would be emitted verbatim. Connection URIs — NIP-46
/// `bunker://` and `nostrconnect://`, NIP-47 `nostr+walletconnect://` — are commonly pasted into
/// contexts (QR codes, deep links) that expect those values percent-encoded, as the NIP examples
/// show, so the URI types encode the query with ``encode(_:)`` instead.
package enum URIQuery {
    /// Query-value characters that survive percent-encoding. The joining delimiters (`&`, `=`) and
    /// the reserved characters carried inside relay URLs, permission lists and secrets are removed so
    /// they are escaped instead of taken literally.
    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+,:/?# ")
        return set
    }()

    /// Percent-encodes and joins query items into a `name=value&name=value` string.
    ///
    /// Item names are assumed to be constant, URL-safe literals and are emitted as-is; only the
    /// values are encoded. Items without a value are skipped.
    package static func encode(_ items: [URLQueryItem]) -> String {
        items.compactMap { item in
            guard let value = item.value else { return nil }
            let encoded = value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
            return "\(item.name)=\(encoded)"
        }
        .joined(separator: "&")
    }

    /// Returns `count` random bytes from the system CSPRNG as a lowercase hex string.
    ///
    /// Used to mint connection secrets.
    package static func randomHex(byteCount count: Int) -> String {
        SecureRandom.generateBytes(count: count).hexEncodedString()
    }
}
