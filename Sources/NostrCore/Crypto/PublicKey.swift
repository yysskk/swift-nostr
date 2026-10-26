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
    /// - Throws: ``PublicKey/Error/invalidHex`` if `hex` has the wrong length, contains anything
    ///   but `0`–`9` and `a`–`f`, or uses uppercase digits.
    public init(hex: String) throws(PublicKey.Error) {
        guard hex.isCanonicalHex(byteCount: 32) else {
            throw .invalidHex
        }
        self.hex = hex
    }

    /// Creates a public key from its 32 bytes.
    /// - Throws: ``PublicKey/Error/invalidLength(_:)`` if `data` is not exactly 32 bytes.
    public init(data: Data) throws(PublicKey.Error) {
        guard data.count == 32 else {
            throw .invalidLength(data.count)
        }
        self.hex = data.hexEncodedString()
    }

    /// Creates a public key from a NIP-19 `npub` bech32 string.
    /// - Throws: ``PublicKey/Error/invalidBech32(_:)`` if `npub` is not valid bech32,
    ///   ``PublicKey/Error/unexpectedPrefix(_:)`` if it carries a prefix other than `npub`, or
    ///   ``PublicKey/Error/invalidLength(_:)`` if it does not hold exactly 32 bytes.
    public init(npub: String) throws(PublicKey.Error) {
        let decoded: (hrp: String, data: Data)
        do throws(Bech32.Error) {
            decoded = try Bech32.decode(npub)
        } catch {
            throw .invalidBech32(error)
        }
        guard decoded.hrp == "npub" else {
            throw .unexpectedPrefix(decoded.hrp)
        }
        try self.init(data: decoded.data)
    }

    /// Creates a public key from bytes the caller guarantees are 32 long, such as the x-only key
    /// of a secp256k1 private key.
    init(validatedData data: Data) {
        precondition(data.count == 32, "A public key is 32 bytes")
        self.hex = data.hexEncodedString()
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

extension PublicKey {
    /// Why a value could not be parsed as a ``PublicKey``.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The string is not 64 lowercase hexadecimal digits.
        case invalidHex
        /// The data is not 32 bytes (payload: its byte count).
        case invalidLength(Int)
        /// The `npub` string is not valid bech32.
        case invalidBech32(Bech32.Error)
        /// The bech32 string carries a prefix other than `npub` (payload: the prefix found).
        case unexpectedPrefix(String)

        public var errorDescription: String? {
            switch self {
            case .invalidHex:
                return "A public key must be 64 lowercase hexadecimal digits"
            case .invalidLength(let count):
                return "A public key must be 32 bytes, got \(count)"
            case .invalidBech32(let error):
                return "Invalid npub: \(error.errorDescription ?? "invalid bech32")"
            case .unexpectedPrefix(let prefix):
                return "Expected an npub, got bech32 prefix \(prefix)"
            }
        }
    }
}
