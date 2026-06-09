import Foundation
import P256K

/// Represents a Nostr keypair (private and public keys)
public struct KeyPair: Sendable {
    /// The private key (32 bytes)
    public let privateKey: Data

    /// The public key (32 bytes, x-only)
    public let publicKey: Data

    /// The private key as a hex string
    public var privateKeyHex: String {
        privateKey.hexEncodedString()
    }

    /// The public key as a hex string
    public var publicKeyHex: String {
        publicKey.hexEncodedString()
    }

    /// Creates a new random keypair
    public init() throws {
        let secpPrivateKey = try P256K.Schnorr.PrivateKey()
        self.privateKey = Data(secpPrivateKey.dataRepresentation)
        self.publicKey = Data(secpPrivateKey.xonly.bytes)
    }

    /// Creates a keypair from an existing private key
    public init(privateKey: Data) throws {
        guard privateKey.count == 32 else {
            throw NostrError.invalidPrivateKey
        }

        let secpPrivateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        self.privateKey = privateKey
        self.publicKey = Data(secpPrivateKey.xonly.bytes)
    }

    /// Creates a keypair from a hex-encoded private key
    public init(privateKeyHex: String) throws {
        guard let privateKeyData = Data(hexString: privateKeyHex) else {
            throw NostrError.invalidHex
        }
        try self.init(privateKey: privateKeyData)
    }

    /// Creates a keypair from a nsec bech32-encoded private key
    public init(nsec: String) throws {
        let (hrp, data) = try Bech32.decode(nsec)
        guard hrp == "nsec" else {
            throw NostrError.unknownPrefix(hrp)
        }
        try self.init(privateKey: data)
    }

    /// Creates a keypair from a BIP-39 mnemonic phrase (NIP-06)
    /// Uses derivation path: m/44'/1237'/<account>'/0/0
    /// - Parameters:
    ///   - mnemonic: The BIP-39 mnemonic phrase
    ///   - passphrase: Optional passphrase for additional security
    ///   - account: The account index (default 0)
    public init(mnemonic: Mnemonic, passphrase: String = "", account: UInt32 = 0) throws {
        let seed = mnemonic.toSeed(passphrase: passphrase)
        let privateKey = try KeyDerivation.deriveNostrKey(seed: seed, account: account)
        try self.init(privateKey: privateKey)
    }

    /// Creates a keypair from a mnemonic phrase string (NIP-06)
    /// Uses derivation path: m/44'/1237'/<account>'/0/0
    /// - Parameters:
    ///   - mnemonicPhrase: The BIP-39 mnemonic phrase as a space-separated string
    ///   - passphrase: Optional passphrase for additional security
    ///   - account: The account index (default 0)
    public init(mnemonicPhrase: String, passphrase: String = "", account: UInt32 = 0) throws {
        let mnemonic = try Mnemonic(phrase: mnemonicPhrase)
        try self.init(mnemonic: mnemonic, passphrase: passphrase, account: account)
    }

    /// Generates a new keypair with a random mnemonic (NIP-06)
    /// - Parameters:
    ///   - wordCount: Number of words in the mnemonic (12, 15, 18, 21, or 24)
    ///   - passphrase: Optional passphrase for additional security
    /// - Returns: A tuple containing the generated mnemonic and keypair
    public static func generate(
        wordCount: Int = 12, passphrase: String = ""
    ) throws -> (mnemonic: Mnemonic, keyPair: KeyPair) {
        let mnemonic = try Mnemonic.generate(wordCount: wordCount)
        let keyPair = try KeyPair(mnemonic: mnemonic, passphrase: passphrase)
        return (mnemonic, keyPair)
    }

    /// Returns the private key as nsec (bech32 encoded)
    public var nsec: String {
        Bech32.encode(hrp: "nsec", data: privateKey)
    }

    /// Returns the public key as npub (bech32 encoded)
    public var npub: String {
        Bech32.encode(hrp: "npub", data: publicKey)
    }
}

// MARK: - Public Key Only
/// Represents a Nostr public key (without private key)
public struct PublicKey: Sendable, Hashable {
    /// The public key (32 bytes, x-only)
    public let data: Data

    /// The public key as a hex string
    public var hex: String {
        data.hexEncodedString()
    }

    /// Creates a public key from data
    public init(data: Data) throws {
        guard data.count == 32 else {
            throw NostrError.invalidPublicKey
        }
        self.data = data
    }

    /// Creates a public key from a hex string
    public init(hex: String) throws {
        guard let data = Data(hexString: hex) else {
            throw NostrError.invalidHex
        }
        try self.init(data: data)
    }

    /// Creates a public key from an npub bech32-encoded string
    public init(npub: String) throws {
        let (hrp, data) = try Bech32.decode(npub)
        guard hrp == "npub" else {
            throw NostrError.unknownPrefix(hrp)
        }
        try self.init(data: data)
    }

    /// Returns the public key as npub (bech32 encoded)
    public var npub: String {
        Bech32.encode(hrp: "npub", data: data)
    }
}

// MARK: - Data Extensions
extension Data {
    /// Creates Data from a hex string
    init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Returns a hex-encoded string representation
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
