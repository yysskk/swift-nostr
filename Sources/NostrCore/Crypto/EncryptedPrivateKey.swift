import Foundation
import _CryptoExtras

/// A NIP-49 password-encrypted Nostr private key (`ncryptsec1...`), protected with scrypt and
/// XChaCha20-Poly1305.
///
/// https://github.com/nostr-protocol/nips/blob/master/49.md
public struct EncryptedPrivateKey: Sendable, Hashable {
    /// How the private key was handled before encryption (stored as AEAD associated data).
    public enum KeySecurity: UInt8, Sendable, Hashable {
        /// The key has been handled insecurely (for example, stored unencrypted).
        case insecure = 0x00
        /// The key has only ever been handled securely.
        case secure = 0x01
        /// The client does not track how the key was handled (the default).
        case unknown = 0x02
    }

    /// The version byte required by NIP-49.
    private static let version: UInt8 = 0x02
    /// The human-readable prefix used by NIP-49 bech32 strings.
    private static let humanReadablePrefix = "ncryptsec"
    /// The length in bytes of the decoded payload.
    private static let payloadByteCount = 91
    /// The scrypt block-size parameter (`r`) fixed by NIP-49.
    private static let scryptBlockSize = 8
    /// The scrypt parallelism parameter (`p`) fixed by NIP-49.
    private static let scryptParallelism = 1
    /// The length in bytes of the derived symmetric key.
    private static let symmetricKeyByteCount = 32
    /// The length in bytes of the scrypt salt.
    private static let saltByteCount = 16
    /// The length in bytes of the XChaCha20-Poly1305 nonce.
    private static let nonceByteCount = 24
    /// The largest scrypt cost exponent NIP-49 defines. A payload may record any cost up to this,
    /// and ``init(ncryptsec:)`` parses all of them — but see ``defaultMaximumLogN`` for what
    /// ``decrypt(password:maxLogN:)`` is willing to spend without being asked.
    private static let maximumLogN: UInt8 = 22

    /// The largest scrypt cost ``decrypt(password:maxLogN:)`` accepts unless the caller raises it.
    ///
    /// scrypt's memory cost is `128 · N · r`, and NIP-49 fixes `r` at 8, so the recorded `logN`
    /// alone determines the allocation — 2^logN KiB:
    ///
    /// | logN | Memory  |
    /// |------|---------|
    /// | 16   | 64 MiB  |
    /// | 18   | 256 MiB |
    /// | 20   | 1 GiB   |
    /// | 22   | 4 GiB   |
    ///
    /// The cost byte is chosen by whoever wrote the payload, so an unbounded cap hands a stranger
    /// a 4 GiB allocation on an iPhone or a watch — terminated by the system before the password is
    /// even checked. 18 sits two doublings above the 16 that NIP-49 recommends and that clients
    /// emit in practice, so ordinary keys open untouched while the worst case stays survivable.
    /// A caller who must open a deliberately costlier key passes a higher `maxLogN` and accepts
    /// the allocation; ``logN`` is readable from a parsed payload beforehand, so that decision can
    /// be made with the real number in hand.
    public static let defaultMaximumLogN: UInt8 = 18

    /// The bech32 `ncryptsec` string.
    public let ncryptsec: String

    /// The scrypt cost exponent recorded in the payload (N = 2^logN).
    public let logN: UInt8

    /// The recorded key-security byte.
    public let keySecurity: KeySecurity

    /// Parses and structurally validates an `ncryptsec` string (HRP, version 0x02, 91-byte payload)
    /// without decrypting.
    /// - Parameter ncryptsec: The bech32 `ncryptsec1...` string to validate.
    /// - Throws: ``NostrError/invalidNcryptsec`` if the string is not a well-formed NIP-49 payload.
    public init(ncryptsec: String) throws {
        let payload = try Self.decodePayload(ncryptsec)

        self.ncryptsec = ncryptsec
        self.logN = payload[payload.startIndex + 1]
        // The key-security byte only defines 0x00, 0x01 and 0x02; treat any other value as
        // `.unknown`. Decryption re-reads the raw byte from the payload for the AEAD associated
        // data, so this mapping never affects the round trip.
        self.keySecurity = KeySecurity(rawValue: payload[payload.startIndex + 42]) ?? .unknown
    }

    /// Encrypts a 32-byte private key under `password` (NFKC-normalized before key derivation).
    /// - Parameters:
    ///   - privateKey: The raw 32-byte private key to encrypt.
    ///   - password: The password protecting the key. It is NFKC-normalized before key derivation.
    ///   - logN: The scrypt cost exponent, `1...22` (default 16). Higher is slower and stronger.
    ///   - keySecurity: How the key was handled before encryption (default ``KeySecurity/unknown``).
    /// - Returns: The resulting ``EncryptedPrivateKey``.
    /// - Throws: ``NostrError/invalidPrivateKey`` if `privateKey` is not 32 bytes, or
    ///   ``NostrError/unsupportedScryptCost(_:)`` if `logN` is outside `1...22`.
    public static func encrypt(
        privateKey: Data,
        password: String,
        logN: UInt8 = 16,
        keySecurity: KeySecurity = .unknown
    ) throws -> EncryptedPrivateKey {
        guard privateKey.count == 32 else {
            throw NostrError.invalidPrivateKey
        }
        guard 1...maximumLogN ~= logN else {
            throw NostrError.unsupportedScryptCost(logN)
        }

        let salt = try SecureRandom.generateBytes(count: saltByteCount)
        let nonce = try SecureRandom.generateBytes(count: nonceByteCount)
        // Scrubbed once the payload is sealed: the key is re-derived from the password on every
        // decrypt, so nothing needs this copy afterwards.
        var symmetricKey = try deriveSymmetricKey(password: password, salt: salt, logN: logN)
        defer { symmetricKey.secureScrub() }

        let associatedData = Data([keySecurity.rawValue])
        let ciphertext = try XChaCha20Poly1305.seal(
            privateKey,
            key: symmetricKey,
            nonce: nonce,
            authenticating: associatedData
        )

        var payload = Data(capacity: payloadByteCount)
        payload.append(version)
        payload.append(logN)
        payload.append(salt)
        payload.append(nonce)
        payload.append(associatedData)
        payload.append(ciphertext)

        let ncryptsec = try Bech32.encode(hrp: humanReadablePrefix, data: payload)
        return try EncryptedPrivateKey(ncryptsec: ncryptsec)
    }

    /// Decrypts the private key. Returns the raw 32 bytes without validating them as a secp256k1
    /// scalar (NIP-49 must round-trip even invalid keys).
    /// - Parameters:
    ///   - password: The password protecting the key. It is NFKC-normalized before key derivation.
    ///   - maxLogN: The largest scrypt cost to spend on this payload, defaulting to
    ///     ``defaultMaximumLogN``. Raise it to open a deliberately costly key, keeping in mind that
    ///     the derivation allocates 2^logN KiB; ``logN`` reports what a given payload asks for.
    /// - Returns: The decrypted 32-byte private key.
    /// - Throws: ``NostrError/unsupportedScryptCost(_:)`` if the recorded cost is outside
    ///   `1...maxLogN`, or if `maxLogN` itself exceeds the `22` NIP-49 defines;
    ///   ``NostrError/decryptionFailed`` if authentication fails (almost always a wrong password).
    public func decrypt(password: String, maxLogN: UInt8 = defaultMaximumLogN) throws -> Data {
        // The whole range, not just the ceiling: a `maxLogN` of 0 would clear an upper-bound-only
        // guard and then make the `1...maxLogN` below an invalid range, trapping on exactly the
        // caller-supplied input this bound exists to make safe.
        guard 1...Self.maximumLogN ~= maxLogN else {
            throw NostrError.unsupportedScryptCost(maxLogN)
        }

        let payload = try Self.decodePayload(ncryptsec)
        let base = payload.startIndex

        // Checked before deriving anything: the cost byte is attacker-supplied, and the memory it
        // asks for is committed the moment scrypt starts.
        let logN = payload[base + 1]
        guard 1...maxLogN ~= logN else {
            throw NostrError.unsupportedScryptCost(logN)
        }

        let salt = Data(payload[(base + 2)..<(base + 18)])
        let nonce = Data(payload[(base + 18)..<(base + 42)])
        let associatedData = Data(payload[(base + 42)..<(base + 43)])
        let ciphertext = Data(payload[(base + 43)..<(base + 91)])

        var symmetricKey = try Self.deriveSymmetricKey(password: password, salt: salt, logN: logN)
        defer { symmetricKey.secureScrub() }
        return try XChaCha20Poly1305.open(
            ciphertext,
            key: symmetricKey,
            nonce: nonce,
            authenticating: associatedData
        )
    }

    // MARK: - Private Helpers

    /// Decodes and structurally validates the bech32 payload (HRP, length, version byte).
    private static func decodePayload(_ ncryptsec: String) throws -> Data {
        let decoded: (hrp: String, data: Data)
        do {
            decoded = try Bech32.decode(ncryptsec)
        } catch {
            throw NostrError.invalidNcryptsec
        }

        guard decoded.hrp == humanReadablePrefix,
            decoded.data.count == payloadByteCount,
            decoded.data[decoded.data.startIndex] == version
        else {
            throw NostrError.invalidNcryptsec
        }

        return decoded.data
    }

    /// Derives the 32-byte symmetric key with scrypt over the NFKC-normalized password.
    private static func deriveSymmetricKey(password: String, salt: Data, logN: UInt8) throws -> Data {
        let normalizedPassword = Data(password.precomposedStringWithCompatibilityMapping.utf8)
        let derivedKey = try KDF.Scrypt.deriveKey(
            from: normalizedPassword,
            salt: salt,
            outputByteCount: symmetricKeyByteCount,
            rounds: 1 << Int(logN),
            blockSize: scryptBlockSize,
            parallelism: scryptParallelism
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }
}

// MARK: - KeyPair Convenience
extension KeyPair {
    /// Encrypts this keypair's private key to a NIP-49 `ncryptsec` string.
    /// - Parameters:
    ///   - password: The password protecting the key. It is NFKC-normalized before key derivation.
    ///   - logN: The scrypt cost exponent, `1...22` (default 16). Higher is slower and stronger.
    ///   - keySecurity: How the key was handled before encryption (default
    ///     ``EncryptedPrivateKey/KeySecurity/unknown``).
    /// - Returns: The resulting ``EncryptedPrivateKey``.
    /// - Throws: ``NostrError/unsupportedScryptCost(_:)`` if `logN` is outside `1...22`.
    public func encryptedPrivateKey(
        password: String,
        logN: UInt8 = 16,
        keySecurity: EncryptedPrivateKey.KeySecurity = .unknown
    ) throws -> EncryptedPrivateKey {
        try EncryptedPrivateKey.encrypt(
            privateKey: privateKey,
            password: password,
            logN: logN,
            keySecurity: keySecurity
        )
    }

    /// Decrypts an `ncryptsec` and creates the keypair, validating the key on secp256k1.
    /// - Parameters:
    ///   - ncryptsec: The bech32 `ncryptsec1...` string.
    ///   - password: The password protecting the key. It is NFKC-normalized before key derivation.
    ///   - maxLogN: The largest scrypt cost to spend on this payload, defaulting to
    ///     ``EncryptedPrivateKey/defaultMaximumLogN``.
    /// - Throws: ``NostrError/invalidNcryptsec`` if the payload is malformed,
    ///   ``NostrError/unsupportedScryptCost(_:)`` if the recorded cost exceeds `maxLogN`,
    ///   ``NostrError/decryptionFailed`` if the password is wrong, or
    ///   ``NostrError/invalidPrivateKey`` if the decrypted bytes are not a valid secp256k1 scalar.
    public init(
        ncryptsec: String,
        password: String,
        maxLogN: UInt8 = EncryptedPrivateKey.defaultMaximumLogN
    ) throws {
        let privateKey = try EncryptedPrivateKey(ncryptsec: ncryptsec)
            .decrypt(password: password, maxLogN: maxLogN)
        try self.init(privateKey: privateKey)
    }
}
