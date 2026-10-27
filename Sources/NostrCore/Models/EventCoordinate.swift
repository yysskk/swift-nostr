import Foundation

/// The coordinate of a replaceable or addressable event: its kind, author, and `d`-tag identifier.
///
/// The textual form is NIP-01's `<kind>:<pubkey>:<identifier>`, as carried by "a" tags — the kind in
/// decimal, the public key as canonical hex, and the identifier verbatim (empty for a replaceable
/// event). An identifier may itself contain `:`, so parsing splits only at the first two. The value
/// encodes to and from JSON as that string. ``Tag/address(_:relayURL:)`` builds an "a" tag from it.
/// https://github.com/nostr-protocol/nips/blob/master/01.md
public struct EventCoordinate: Sendable, Hashable {
    /// The event kind.
    public var kind: Event.Kind

    /// The author's public key.
    public var publicKey: PublicKey

    /// The event's `d` tag value. May be empty.
    public var identifier: String

    /// Creates a coordinate from its parts.
    public init(kind: Event.Kind, publicKey: PublicKey, identifier: String) {
        self.kind = kind
        self.publicKey = publicKey
        self.identifier = identifier
    }
}

extension EventCoordinate: CustomStringConvertible, LosslessStringConvertible {
    /// The coordinate as `<kind>:<pubkey>:<identifier>`.
    public var description: String {
        "\(kind.rawValue):\(publicKey.hex):\(identifier)"
    }

    /// Parses a `<kind>:<pubkey>:<identifier>` string, or returns `nil` if it has fewer than three
    /// parts, the kind is not a non-negative decimal integer without leading zeros, or the public
    /// key is not 64 lowercase hexadecimal digits.
    public init?(_ description: String) {
        let parts = description.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
            let kind = Int(parts[0]), kind >= 0, String(kind) == parts[0],
            let publicKey = PublicKey(String(parts[1]))
        else {
            return nil
        }
        self.init(kind: Event.Kind(rawValue: kind), publicKey: publicKey, identifier: String(parts[2]))
    }
}

extension EventCoordinate: Codable {
    /// Decodes a coordinate from its `<kind>:<pubkey>:<identifier>` string.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not a valid coordinate.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = EventCoordinate(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "An event coordinate must be <kind>:<pubkey>:<identifier>")
        }
        self = value
    }

    /// Encodes the coordinate as its `<kind>:<pubkey>:<identifier>` string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Event {
    /// This event's coordinate, or nil unless its kind is replaceable or addressable.
    ///
    /// An addressable event's identifier is its first `d` tag value (empty when absent, as NIP-01
    /// treats it); a replaceable event's is always empty.
    public var coordinate: EventCoordinate? {
        let identifier: String
        if kind.isAddressable {
            identifier = firstTagValue(named: .identifier) ?? ""
        } else if kind.isReplaceable {
            identifier = ""
        } else {
            return nil
        }
        return EventCoordinate(kind: kind, publicKey: publicKey, identifier: identifier)
    }
}
