import Foundation

/// The id a client gives a subscription in `REQ` and `COUNT` and a relay echoes back in `EVENT`,
/// `EOSE`, `CLOSED`, and `COUNT` (NIP-01).
///
/// NIP-01 makes an id an arbitrary non-empty string of at most 64 characters, chosen by the client
/// and unique per connection. ``random()`` produces one that meets both rules; ids built from a raw
/// value or a string literal are carried as given and not validated, so a frame a relay sends is
/// never dropped for its id alone. The value encodes to and from JSON as its bare string.
///
/// ```swift
/// let id = SubscriptionID.random()
/// try await relay.subscribe(id: id, filters: [Filter(kinds: [.textNote])])
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/01.md
public struct SubscriptionID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    /// The id as it appears on the wire.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A fresh id, unique for practical purposes: a random UUID, 36 characters long.
    public static func random() -> SubscriptionID {
        SubscriptionID(rawValue: UUID().uuidString)
    }

    public var description: String {
        rawValue
    }
}

// MARK: - String Literal
extension SubscriptionID: ExpressibleByStringLiteral {
    /// Builds an id from a string literal: `let id: SubscriptionID = "nwc-responses"`.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
