import Foundation

/// Internal helpers for building NIP-46 connection-URI query strings.
///
/// `URLComponents.string` leaves reserved characters such as `:` and `/` unescaped inside query
/// values, so a relay like `wss://relay.example` would be emitted verbatim. NIP-46 URIs are commonly
/// pasted into contexts (QR codes, deep links) that expect those values percent-encoded, so the URI
/// types encode the query manually with ``encode(_:)``.
enum URIQuery {
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
    static func encode(_ items: [URLQueryItem]) -> String {
        items.compactMap { item in
            guard let value = item.value else { return nil }
            let encoded = value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
            return "\(item.name)=\(encoded)"
        }
        .joined(separator: "&")
    }

    /// Whether `url` is a WebSocket relay URL (`ws://` or `wss://`). Relay values in a connection
    /// URI come from an untrusted signer or QR code, so both URI types reject non-WebSocket schemes.
    static func isWebSocketURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "ws", "wss": return true
        default: return false
        }
    }

    /// Returns `count` cryptographically-seeded random bytes as a lowercase hex string.
    ///
    /// Used to mint connection secrets. `SecureRandom` in NostrCore is not visible here, so this
    /// draws from the system generator, which is seeded from the platform CSPRNG.
    static func randomHex(byteCount count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }
}
