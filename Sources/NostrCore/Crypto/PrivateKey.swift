import Foundation
import P256K

/// A Nostr private key: a 32-byte secp256k1 scalar, validated when the value is created.
///
/// A `PrivateKey` always holds a usable key — 32 bytes, non-zero, and below the curve order — so
/// ``KeyPair/init(privateKey:)`` cannot fail. Its `description`, `debugDescription`, and reflection
/// are redacted, so `print`, string interpolation, and `dump` never reveal the key; read ``hex``,
/// ``data``, or ``nsec`` to export it deliberately. It is not `Codable` for the same reason.
public struct PrivateKey: Sendable {
    /// The key's 32 bytes.
    public let data: Data

    /// The key as 64 lowercase hexadecimal digits.
    public var hex: String {
        data.hexEncodedString()
    }

    /// The key as a NIP-19 `nsec` bech32 string.
    public var nsec: String {
        Bech32.encode(validatedHRP: "nsec", data: data)
    }

    /// Creates a private key from its 32 bytes.
    /// - Throws: ``KeyPair/Error/invalidLength(_:)`` if `data` is not 32 bytes, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if it is not a valid secp256k1 scalar.
    public init(data: Data) throws(KeyPair.Error) {
        guard data.count == 32 else {
            throw .invalidLength(data.count)
        }
        guard (try? P256K.Schnorr.PrivateKey(dataRepresentation: data)) != nil else {
            throw .invalidPrivateKey
        }
        self.data = Data(data)
    }

    /// Creates a private key from its hex form.
    /// - Parameter hex: 64 hexadecimal digits, in either case.
    /// - Throws: ``KeyPair/Error/invalidHex`` if `hex` is not 64 hexadecimal digits, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if it is not a valid secp256k1 scalar.
    public init(hex: String) throws(KeyPair.Error) {
        guard let data = Data(hexString: hex), data.count == 32 else {
            throw .invalidHex
        }
        try self.init(data: data)
    }

    /// Creates a private key from a NIP-19 `nsec` bech32 string.
    /// - Throws: ``KeyPair/Error/invalidBech32(_:)`` if `nsec` is not valid bech32,
    ///   ``KeyPair/Error/unexpectedPrefix(_:)`` if it carries a prefix other than `nsec`,
    ///   ``KeyPair/Error/invalidLength(_:)`` if it does not hold 32 bytes, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if they are not a valid secp256k1 scalar.
    public init(nsec: String) throws(KeyPair.Error) {
        let decoded: (hrp: String, data: Data)
        do throws(Bech32.Error) {
            decoded = try Bech32.decode(nsec)
        } catch {
            throw .invalidBech32(error)
        }
        guard decoded.hrp == "nsec" else {
            throw .unexpectedPrefix(decoded.hrp)
        }
        try self.init(data: decoded.data)
    }
}

// MARK: - Equatable & Hashable
extension PrivateKey: Hashable {
    /// Compares every byte regardless of where the keys first differ, so the comparison's duration
    /// does not reveal how much of a key matched.
    public static func == (lhs: PrivateKey, rhs: PrivateKey) -> Bool {
        zip(lhs.data, rhs.data).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(data)
    }
}

// MARK: - Redaction
extension PrivateKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A placeholder that never contains the key.
    public var description: String {
        "PrivateKey(<redacted>)"
    }

    /// A placeholder that never contains the key.
    public var debugDescription: String {
        description
    }

    /// A mirror with no children, so `dump` and other reflection show only ``description``.
    public var customMirror: Mirror {
        Mirror(self, children: [], displayStyle: .struct)
    }
}
