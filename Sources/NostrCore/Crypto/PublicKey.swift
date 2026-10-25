import Foundation

/// A Nostr public key: the 32-byte x-only secp256k1 key (BIP-340) that identifies an author.
///
/// The canonical textual form is 64 lowercase hexadecimal digits — the spelling NIP-01 puts on the
/// wire — and it is the only one ``init(hex:)`` accepts, so every key has exactly one string form
/// to compare, hash, or key a dictionary by. ``npub`` gives the NIP-19 bech32 form for display.
/// The value encodes to and from JSON as its hex string.
public struct PublicKey: Sendable, Hashable {
    /// The key as 64 lowercase hexadecimal digits.
    public let hex: String

    /// The key's 32 bytes.
    public var data: Data {
        Data(canonicalHex: hex)
    }

    /// The key as a NIP-19 `npub` bech32 string.
    public var npub: String {
        Bech32.encode(validatedHRP: "npub", data: data)
    }

    /// Creates a public key from its canonical hex form.
    /// - Parameter hex: Exactly 64 lowercase hexadecimal digits.
    /// - Throws: ``NostrError/invalidPublicKey`` if `hex` has the wrong length, contains anything
    ///   but `0`–`9` and `a`–`f`, or uses uppercase digits.
    public init(hex: String) throws {
        guard hex.isCanonicalHex(byteCount: 32) else {
            throw NostrError.invalidPublicKey
        }
        self.hex = hex
    }

    /// Creates a public key from its 32 bytes.
    /// - Throws: ``NostrError/invalidPublicKey`` if `data` is not exactly 32 bytes.
    public init(data: Data) throws {
        guard data.count == 32 else {
            throw NostrError.invalidPublicKey
        }
        self.hex = data.hexEncodedString()
    }

    /// Creates a public key from a NIP-19 `npub` bech32 string.
    /// - Throws: ``NostrError/invalidPublicKey`` if `npub` is not valid bech32, carries a prefix
    ///   other than `npub`, or does not hold exactly 32 bytes.
    public init(npub: String) throws {
        guard let (prefix, data) = try? Bech32.decode(npub), prefix == "npub" else {
            throw NostrError.invalidPublicKey
        }
        try self.init(data: data)
    }
}

extension PublicKey: CustomStringConvertible, LosslessStringConvertible {
    /// The key's canonical hex form, ``hex``.
    public var description: String {
        hex
    }

    /// Creates a public key from its canonical hex form, or returns `nil` if `description` is not
    /// exactly 64 lowercase hexadecimal digits.
    public init?(_ description: String) {
        guard description.isCanonicalHex(byteCount: 32) else {
            return nil
        }
        self.hex = description
    }
}

extension PublicKey: Codable {
    /// Decodes a public key from a canonical hex string.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not 64 lowercase hexadecimal digits.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = PublicKey(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "A public key must be 64 lowercase hexadecimal digits")
        }
        self = value
    }

    /// Encodes the public key as its canonical hex string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
