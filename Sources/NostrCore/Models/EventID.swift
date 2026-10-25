import Foundation

/// A Nostr event id: the 32-byte SHA-256 of an event's NIP-01 serialization.
///
/// The canonical textual form is 64 lowercase hexadecimal digits — the spelling NIP-01 puts on the
/// wire — and it is the only one ``init(hex:)`` accepts, so every id has exactly one string form
/// to compare, hash, or key a dictionary by. ``note`` gives the NIP-19 bech32 form for display.
/// The value encodes to and from JSON as its hex string.
public struct EventID: Sendable, Hashable {
    /// The id as 64 lowercase hexadecimal digits.
    public let hex: String

    /// The id's 32 bytes.
    public var data: Data {
        Data(canonicalHex: hex)
    }

    /// The id as a NIP-19 `note` bech32 string.
    public var note: String {
        Bech32.encode(validatedHRP: "note", data: data)
    }

    /// Creates an event id from its canonical hex form.
    /// - Parameter hex: Exactly 64 lowercase hexadecimal digits.
    /// - Throws: ``NostrError/invalidEventID`` if `hex` has the wrong length, contains anything
    ///   but `0`–`9` and `a`–`f`, or uses uppercase digits.
    public init(hex: String) throws {
        guard hex.isCanonicalHex(byteCount: 32) else {
            throw NostrError.invalidEventID
        }
        self.hex = hex
    }

    /// Creates an event id from its 32 bytes.
    /// - Throws: ``NostrError/invalidEventID`` if `data` is not exactly 32 bytes.
    public init(data: Data) throws {
        guard data.count == 32 else {
            throw NostrError.invalidEventID
        }
        self.hex = data.hexEncodedString()
    }

    /// Creates an event id from a NIP-19 `note` bech32 string.
    /// - Throws: ``NostrError/invalidEventID`` if `note` is not valid bech32, carries a prefix
    ///   other than `note`, or does not hold exactly 32 bytes.
    public init(note: String) throws {
        guard let (prefix, data) = try? Bech32.decode(note), prefix == "note" else {
            throw NostrError.invalidEventID
        }
        try self.init(data: data)
    }
}

extension EventID: Comparable {
    /// Orders ids by their bytes — equivalently, by their canonical hex — which is the order NIP-01
    /// breaks `created_at` ties by: of two replaceable events with the same timestamp, the one with
    /// the lower id wins.
    public static func < (lhs: EventID, rhs: EventID) -> Bool {
        lhs.hex < rhs.hex
    }
}

extension EventID: CustomStringConvertible, LosslessStringConvertible {
    /// The id's canonical hex form, ``hex``.
    public var description: String {
        hex
    }

    /// Creates an event id from its canonical hex form, or returns `nil` if `description` is not
    /// exactly 64 lowercase hexadecimal digits.
    public init?(_ description: String) {
        guard description.isCanonicalHex(byteCount: 32) else {
            return nil
        }
        self.hex = description
    }
}

extension EventID: Codable {
    /// Decodes an event id from a canonical hex string.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not 64 lowercase hexadecimal digits.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = EventID(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "An event id must be 64 lowercase hexadecimal digits")
        }
        self = value
    }

    /// Encodes the event id as its canonical hex string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
