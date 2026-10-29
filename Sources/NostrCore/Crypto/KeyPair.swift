import Foundation
import P256K

/// Represents a Nostr keypair (private and public keys)
public struct KeyPair: Sendable {
    /// The private key.
    public let privateKey: PrivateKey

    /// The public key derived from ``privateKey``.
    public let publicKey: PublicKey

    /// Creates a new random keypair
    public init() {
        // Random bytes miss the valid scalar range (zero, or not below the curve order) with
        // probability under 2^-127; draw again rather than report it.
        while true {
            if let privateKey = try? PrivateKey(data: SecureRandom.generateBytes(count: 32)) {
                self.init(privateKey: privateKey)
                return
            }
        }
    }

    /// Creates the keypair for an existing private key, deriving its public key.
    public init(privateKey: PrivateKey) {
        // `PrivateKey` validated the scalar when it was created.
        guard let secpPrivateKey = try? P256K.Schnorr.PrivateKey(dataRepresentation: privateKey.data) else {
            preconditionFailure("A PrivateKey is a valid secp256k1 scalar")
        }
        self.privateKey = privateKey
        self.publicKey = PublicKey(validatedData: Data(secpPrivateKey.xonly.bytes))
    }

    /// Creates a keypair from a NIP-19 `nsec`.
    /// - Throws: What ``PrivateKey/init(nsec:)`` throws for a malformed `nsec`.
    public init(nsec: String) throws(KeyPair.Error) {
        self.init(privateKey: try PrivateKey(nsec: nsec))
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
        self.init(privateKey: try KeyDerivation.deriveNostrKey(seed: seed, account: account))
    }

    /// Creates a keypair from a mnemonic phrase string (NIP-06)
    /// Uses derivation path: m/44'/1237'/<account>'/0/0
    /// - Parameters:
    ///   - mnemonicPhrase: The BIP-39 mnemonic phrase as a space-separated string
    ///   - passphrase: Optional passphrase for additional security
    ///   - account: The account index (default 0)
    /// - Throws: ``KeyPair/Error/invalidMnemonic(_:)`` if the phrase is not a valid mnemonic, or
    ///   ``KeyPair/Error/invalidPrivateKey`` if derivation produces an invalid scalar.
    public init(mnemonicPhrase: String, passphrase: String = "", account: UInt32 = 0) throws(KeyPair.Error) {
        let mnemonic: Mnemonic
        do throws(Mnemonic.Error) {
            mnemonic = try Mnemonic(phrase: mnemonicPhrase)
        } catch {
            throw .invalidMnemonic(error)
        }
        try self.init(mnemonic: mnemonic, passphrase: passphrase, account: account)
    }

    /// Generates a new keypair with a random mnemonic (NIP-06)
    /// - Parameters:
    ///   - wordCount: Number of words in the mnemonic
    ///   - passphrase: Optional passphrase for additional security
    /// - Returns: A tuple containing the generated mnemonic and keypair
    /// - Throws: ``KeyPair/Error/invalidPrivateKey`` if derivation produces an invalid scalar.
    public static func generate(
        wordCount: Mnemonic.WordCount = .twelve, passphrase: String = ""
    ) throws(KeyPair.Error) -> (mnemonic: Mnemonic, keyPair: KeyPair) {
        let mnemonic = Mnemonic.generate(wordCount: wordCount)
        let keyPair = try KeyPair(mnemonic: mnemonic, passphrase: passphrase)
        return (mnemonic, keyPair)
    }
}

extension KeyPair {
    /// Why a value could not be used as a private key — by ``PrivateKey`` or by a ``KeyPair``
    /// initializer.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The string is not 64 hexadecimal digits.
        case invalidHex
        /// The data is not 32 bytes (payload: its byte count).
        case invalidLength(Int)
        /// The `nsec` string is not valid bech32.
        case invalidBech32(Bech32Error)
        /// The bech32 string carries a prefix other than `nsec` (payload: the prefix found).
        case unexpectedPrefix(String)
        /// The 32 bytes are not a valid secp256k1 private key: zero, or not below the curve order.
        case invalidPrivateKey
        /// The NIP-06 mnemonic is not valid BIP-39 (payload: why).
        case invalidMnemonic(Mnemonic.Error)

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
            case .invalidMnemonic(let error):
                return "Invalid mnemonic: \(error.errorDescription ?? "invalid BIP-39 phrase")"
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
