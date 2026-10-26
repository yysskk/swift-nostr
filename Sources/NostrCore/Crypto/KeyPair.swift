import Foundation
import P256K

/// Represents a Nostr keypair (private and public keys)
public struct KeyPair: Sendable {
    /// The private key (32 bytes)
    public let privateKey: Data

    /// The public key derived from ``privateKey``.
    public let publicKey: PublicKey

    /// The private key as a hex string
    public var privateKeyHex: String {
        privateKey.hexEncodedString()
    }

    /// Creates a new random keypair
    public init() throws {
        let secpPrivateKey = try P256K.Schnorr.PrivateKey()
        self.privateKey = Data(secpPrivateKey.dataRepresentation)
        self.publicKey = PublicKey(validatedData: Data(secpPrivateKey.xonly.bytes))
    }

    /// Creates a keypair from an existing private key
    /// - Throws: ``KeyPair/Error/invalidLength(_:)`` if `privateKey` is not 32 bytes, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if it is not a valid secp256k1 scalar.
    public init(privateKey: Data) throws(KeyPair.Error) {
        guard privateKey.count == 32 else {
            throw .invalidLength(privateKey.count)
        }

        let secpPrivateKey: P256K.Schnorr.PrivateKey
        do {
            secpPrivateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        } catch {
            throw .invalidPrivateKey
        }
        self.privateKey = privateKey
        self.publicKey = PublicKey(validatedData: Data(secpPrivateKey.xonly.bytes))
    }

    /// Creates a keypair from a hex-encoded private key
    /// - Throws: ``KeyPair/Error/invalidHex`` if `privateKeyHex` is not 64 hexadecimal digits, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if it is not a valid secp256k1 scalar.
    public init(privateKeyHex: String) throws(KeyPair.Error) {
        guard let privateKeyData = Data(hexString: privateKeyHex), privateKeyData.count == 32 else {
            throw .invalidHex
        }
        try self.init(privateKey: privateKeyData)
    }

    /// Creates a keypair from a nsec bech32-encoded private key
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
        try self.init(privateKey: decoded.data)
    }

    /// Creates a keypair from a BIP-39 mnemonic phrase (NIP-06)
    /// Uses derivation path: m/44'/1237'/<account>'/0/0
    /// - Parameters:
    ///   - mnemonic: The BIP-39 mnemonic phrase
    ///   - passphrase: Optional passphrase for additional security
    ///   - account: The account index (default 0)
    /// - Throws: ``KeyPair/Error/invalidPrivateKey`` in the vanishingly rare case that derivation
    ///   produces an invalid secp256k1 scalar.
    public init(mnemonic: Mnemonic, passphrase: String = "", account: UInt32 = 0) throws(KeyPair.Error) {
        let seed = mnemonic.seed(passphrase: passphrase)
        let privateKey = try KeyDerivation.deriveNostrKey(seed: seed, account: account)
        try self.init(privateKey: privateKey)
    }

    /// Creates a keypair from a mnemonic phrase string (NIP-06)
    /// Uses derivation path: m/44'/1237'/<account>'/0/0
    /// - Parameters:
    ///   - mnemonicPhrase: The BIP-39 mnemonic phrase as a space-separated string
    ///   - passphrase: Optional passphrase for additional security
    ///   - account: The account index (default 0)
    /// - Throws: A ``Mnemonic/Error`` if the phrase is not a valid mnemonic, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if derivation produces an invalid scalar.
    public init(mnemonicPhrase: String, passphrase: String = "", account: UInt32 = 0) throws {
        let mnemonic = try Mnemonic(phrase: mnemonicPhrase)
        try self.init(mnemonic: mnemonic, passphrase: passphrase, account: account)
    }

    /// Generates a new keypair with a random mnemonic (NIP-06)
    /// - Parameters:
    ///   - wordCount: Number of words in the mnemonic (12, 15, 18, 21, or 24)
    ///   - passphrase: Optional passphrase for additional security
    /// - Returns: A tuple containing the generated mnemonic and keypair
    /// - Throws: ``Mnemonic/Error/invalidWordCount(_:)`` for an unsupported `wordCount`, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if derivation produces an invalid scalar.
    public static func generate(
        wordCount: Int = 12, passphrase: String = ""
    ) throws -> (mnemonic: Mnemonic, keyPair: KeyPair) {
        let mnemonic = try Mnemonic.generate(wordCount: wordCount)
        let keyPair = try KeyPair(mnemonic: mnemonic, passphrase: passphrase)
        return (mnemonic, keyPair)
    }

    /// Returns the private key as nsec (bech32 encoded)
    public var nsec: String {
        Bech32.encode(validatedHRP: "nsec", data: privateKey)
    }
}

extension KeyPair {
    /// Why a value could not be used as a ``KeyPair``'s private key.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The string is not 64 hexadecimal digits.
        case invalidHex
        /// The data is not 32 bytes (payload: its byte count).
        case invalidLength(Int)
        /// The `nsec` string is not valid bech32.
        case invalidBech32(Bech32.Error)
        /// The bech32 string carries a prefix other than `nsec` (payload: the prefix found).
        case unexpectedPrefix(String)
        /// The 32 bytes are not a valid secp256k1 private key: zero, or not below the curve order.
        case invalidPrivateKey

        public var errorDescription: String? {
            switch self {
            case .invalidHex:
                return "A private key must be 64 hexadecimal digits"
            case .invalidLength(let count):
                return "A private key must be 32 bytes, got \(count)"
            case .invalidBech32(let error):
                return "Invalid nsec: \(error.errorDescription ?? "invalid bech32")"
            case .unexpectedPrefix(let prefix):
                return "Expected an nsec, got bech32 prefix \(prefix)"
            case .invalidPrivateKey:
                return "Invalid private key"
            }
        }
    }
}

// MARK: - Equatable & Hashable
extension KeyPair: Equatable, Hashable {
    /// Two keypairs are equal when they represent the same Nostr identity — the same
    /// x-only public key. The public key is derived deterministically from the private
    /// key, so comparing public keys compares identities while keeping private-key
    /// bytes out of equality checks.
    public static func == (lhs: KeyPair, rhs: KeyPair) -> Bool {
        lhs.publicKey == rhs.publicKey
    }

    /// Hashes the public key only, keeping private-key bytes out of hash values.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
    }
}
