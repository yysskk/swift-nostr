import Foundation

/// A Nostr event signature: a 64-byte BIP-340 Schnorr signature over the event id.
///
/// The canonical textual form is 128 lowercase hexadecimal digits — the spelling NIP-01 puts on
/// the wire — and it is the only one ``init(hex:)`` accepts. The value encodes to and from JSON as
/// its hex string.
public struct Signature: Sendable, Hashable {
    /// The signature as 128 lowercase hexadecimal digits.
    public let hex: String

    /// The signature's 64 bytes.
    public var data: Data {
        Data(canonicalHex: hex)
    }

    /// Creates a signature from its canonical hex form.
    /// - Parameter hex: Exactly 128 lowercase hexadecimal digits.
    /// - Throws: ``NostrError/invalidSignature`` if `hex` has the wrong length, contains anything
    ///   but `0`–`9` and `a`–`f`, or uses uppercase digits.
    public init(hex: String) throws {
        guard hex.isCanonicalHex(byteCount: 64) else {
            throw NostrError.invalidSignature
        }
        self.hex = hex
    }

    /// Creates a signature from its 64 bytes.
    /// - Throws: ``NostrError/invalidSignature`` if `data` is not exactly 64 bytes.
    public init(data: Data) throws {
        guard data.count == 64 else {
            throw NostrError.invalidSignature
        }
        self.hex = data.hexEncodedString()
    }
}

extension Signature: CustomStringConvertible, LosslessStringConvertible {
    /// The signature's canonical hex form, ``hex``.
    public var description: String {
        hex
    }

    /// Creates a signature from its canonical hex form, or returns `nil` if `description` is not
    /// exactly 128 lowercase hexadecimal digits.
    public init?(_ description: String) {
        guard description.isCanonicalHex(byteCount: 64) else {
            return nil
        }
        self.hex = description
    }
}

extension Signature: Codable {
    /// Decodes a signature from a canonical hex string.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not 128 lowercase hexadecimal
    ///   digits.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Signature(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "A signature must be 128 lowercase hexadecimal digits")
        }
        self = value
    }

    /// Encodes the signature as its canonical hex string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
