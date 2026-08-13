import Crypto
import Foundation
import P256K

/// NIP-44 Versioned Encryption
/// https://github.com/nostr-protocol/nips/blob/master/44.md
public struct SealedMessage: Sendable {
    /// The base64-encoded sealed payload
    public let payload: String

    /// Current NIP-44 version
    public static let version: UInt8 = 2

    /// Minimum padded length
    private static let minPlaintextSize = 1
    private static let maxPlaintextSize = 65535
    /// The length of a NIP-44 conversation key, the HKDF-Extract output the message keys expand from.
    private static let conversationKeyByteCount = 32
    /// The length of the per-message nonce NIP-44 expands the message keys over.
    private static let nonceByteCount = 32

    // MARK: - Initializers

    /// Creates a SealedMessage from an existing base64-encoded payload
    public init(payload: String) {
        self.payload = payload
    }

    // MARK: - Public API

    /// Seals a message for a recipient using NIP-44 encryption
    /// - Parameters:
    ///   - message: The plaintext message to seal
    ///   - recipientPubkey: The recipient's public key (hex string)
    ///   - senderKeyPair: The sender's key pair
    /// - Returns: A SealedMessage containing the encrypted payload
    public static func seal(
        _ message: String,
        for recipientPubkey: String,
        using senderKeyPair: KeyPair
    ) throws -> SealedMessage {
        // Generate a random 32-byte nonce, then delegate to the deterministic implementation.
        let nonce = try generateSecureRandomBytes(count: 32)
        return try seal(message, for: recipientPubkey, using: senderKeyPair, nonce: nonce)
    }

    /// Seals a message with a caller-supplied nonce.
    ///
    /// Internal and intended for tests that pin the on-wire output to a known nonce (e.g. the
    /// official NIP-44 vectors). Production callers should use ``seal(_:for:using:)``, which
    /// generates a fresh random nonce for every message as the spec requires.
    /// - Parameters:
    ///   - message: The plaintext message to seal.
    ///   - recipientPubkey: The recipient's public key (hex string).
    ///   - senderKeyPair: The sender's key pair.
    ///   - nonce: The 32-byte nonce to use.
    /// - Returns: A SealedMessage containing the encrypted payload.
    static func seal(
        _ message: String,
        for recipientPubkey: String,
        using senderKeyPair: KeyPair,
        nonce: Data
    ) throws -> SealedMessage {
        guard let recipientPubkeyData = Data(hexString: recipientPubkey) else {
            throw NostrError.invalidPublicKey
        }

        let conversationKey = try getConversationKey(
            senderPrivateKey: senderKeyPair.privateKey,
            recipientPubkey: recipientPubkeyData
        )

        let payload = try encrypt(plaintext: message, conversationKey: conversationKey, nonce: nonce)
        return SealedMessage(payload: payload)
    }

    /// Encrypts a plaintext under an already-derived conversation key.
    ///
    /// Internal and intended for tests that drive the official `encrypt_decrypt` vectors, which
    /// give the conversation key and nonce directly rather than a pair of keys. Splitting this
    /// out mirrors the reference implementation's own `encrypt`/`get_conversation_key` split.
    /// - Parameters:
    ///   - plaintext: The plaintext message.
    ///   - conversationKey: The 32-byte conversation key.
    ///   - nonce: The 32-byte nonce.
    /// - Returns: The base64-encoded `version || nonce || ciphertext || mac` payload.
    static func encrypt(plaintext: String, conversationKey: Data, nonce: Data) throws -> String {
        // Measured rather than encoded first, so an out-of-range plaintext — the invalid vectors
        // reach 10 MB — is rejected without copying it or expanding the message keys.
        let unpaddedLen = plaintext.utf8.count
        guard unpaddedLen >= minPlaintextSize,
            unpaddedLen <= maxPlaintextSize
        else {
            throw NostrError.encryptionFailed
        }

        // HKDF accepts inputs of any length, so a wrong-length key or nonce would expand into a
        // payload that is well-formed and undecryptable by anyone — a failure that surfaces only on
        // the recipient's side, if at all.
        guard conversationKey.count == conversationKeyByteCount,
            nonce.count == nonceByteCount
        else {
            throw NostrError.encryptionFailed
        }

        let plaintextData = Data(plaintext.utf8)

        // 1. Derive message keys from conversation key and nonce
        let (chachaKey, chachaNonce, hmacKey) = deriveMessageKeys(conversationKey: conversationKey, nonce: nonce)

        // 2. Pad the plaintext
        let padded = try pad(plaintextData)

        // 3. Encrypt with ChaCha20
        let ciphertext = try chacha20(padded, key: chachaKey, nonce: chachaNonce)

        // 4. Calculate HMAC
        let hmacInput = nonce + ciphertext
        let mac = HMAC<Crypto.SHA256>.authenticationCode(for: hmacInput, using: SymmetricKey(data: hmacKey))

        // 5. Assemble payload: version || nonce || ciphertext || mac
        var payloadData = Data([version])
        payloadData.append(nonce)
        payloadData.append(ciphertext)
        payloadData.append(Data(mac))

        return payloadData.base64EncodedString()
    }

    /// Opens a sealed message from a sender
    /// - Parameters:
    ///   - senderPubkey: The sender's public key (hex string)
    ///   - recipientKeyPair: The recipient's key pair
    /// - Returns: The decrypted plaintext message
    public func open(from senderPubkey: String, using recipientKeyPair: KeyPair) throws -> String {
        guard let senderPubkeyData = Data(hexString: senderPubkey) else {
            throw NostrError.invalidPublicKey
        }

        let conversationKey = try Self.getConversationKey(
            senderPrivateKey: recipientKeyPair.privateKey,
            recipientPubkey: senderPubkeyData
        )

        return try Self.decrypt(payload: payload, conversationKey: conversationKey)
    }

    /// Decrypts a base64 payload under an already-derived conversation key.
    ///
    /// Internal and intended for tests that drive the official `encrypt_decrypt` and
    /// `invalid.decrypt` vectors, which give the conversation key directly rather than a pair of
    /// keys. Splitting this out mirrors the reference implementation's own `decrypt` /
    /// `get_conversation_key` split.
    /// - Parameters:
    ///   - payload: The base64-encoded `version || nonce || ciphertext || mac` payload.
    ///   - conversationKey: The 32-byte conversation key.
    /// - Returns: The decrypted plaintext message.
    static func decrypt(payload: String, conversationKey: Data) throws -> String {
        guard conversationKey.count == conversationKeyByteCount else {
            throw NostrError.decryptionFailed
        }

        guard let payloadData = Data(base64Encoded: payload) else {
            throw NostrError.invalidPayloadFormat
        }

        // The smallest padded plaintext is a 2-byte length prefix plus one 32-byte block, and the
        // largest is that prefix plus 65536 bytes, so the decoded payload is
        // 1 (version) + 32 (nonce) + [34, 65538] (ciphertext) + 32 (mac) = [99, 65603] bytes.
        guard payloadData.count >= 99, payloadData.count <= 65603 else {
            throw NostrError.invalidPayloadFormat
        }

        // 1. Parse payload
        let version = payloadData[0]
        guard version == Self.version else {
            throw NostrError.unsupportedEncryptionVersion(version)
        }

        let nonce = payloadData[1..<33]
        let mac = payloadData[(payloadData.count - 32)...]
        let ciphertext = payloadData[33..<(payloadData.count - 32)]

        // 2. Derive message keys
        let (chachaKey, chachaNonce, hmacKey) = Self.deriveMessageKeys(
            conversationKey: conversationKey, nonce: Data(nonce))

        // 3. Verify HMAC using timing-safe comparison
        let hmacInput = Data(nonce) + Data(ciphertext)
        let expectedMac = HMAC<Crypto.SHA256>.authenticationCode(for: hmacInput, using: SymmetricKey(data: hmacKey))

        guard Self.timingSafeEqual(Data(mac), Data(expectedMac)) else {
            throw NostrError.hmacVerificationFailed
        }

        // 4. Decrypt with ChaCha20
        let padded = try Self.chacha20(Data(ciphertext), key: chachaKey, nonce: chachaNonce)

        // 5. Unpad
        let plaintext = try Self.unpad(padded)

        guard let message = String(data: plaintext, encoding: .utf8) else {
            throw NostrError.invalidPayloadFormat
        }

        return message
    }

    // MARK: - Internal Methods

    /// Derives the NIP-44 conversation key from hex-encoded keys and returns it as hex.
    ///
    /// Internal and intended for tests that check the derivation against the official
    /// `get_conversation_key` vectors.
    /// - Parameters:
    ///   - privateKeyHex: The caller's private key (hex string).
    ///   - publicKeyHex: The peer's x-only public key (hex string).
    /// - Returns: The 32-byte conversation key as a hex string.
    static func conversationKeyHex(privateKeyHex: String, publicKeyHex: String) throws -> String {
        guard let privateKey = Data(hexString: privateKeyHex) else {
            throw NostrError.invalidPrivateKey
        }
        guard let publicKey = Data(hexString: publicKeyHex) else {
            throw NostrError.invalidPublicKey
        }
        let conversationKey = try getConversationKey(senderPrivateKey: privateKey, recipientPubkey: publicKey)
        return conversationKey.hexEncodedString()
    }

    /// Computes the conversation key using ECDH + HKDF
    private static func getConversationKey(senderPrivateKey: Data, recipientPubkey: Data) throws -> Data {
        // Get the private key for ECDH (use KeyAgreement, not Signing)
        let privateKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: senderPrivateKey)

        // Convert x-only pubkey to full pubkey
        // Try even parity (0x02) first, then odd parity (0x03) if that fails
        var publicKey: P256K.KeyAgreement.PublicKey

        var evenPubkey = Data([0x02])
        evenPubkey.append(recipientPubkey)

        if let evenKey = try? P256K.KeyAgreement.PublicKey(dataRepresentation: evenPubkey, format: .compressed) {
            publicKey = evenKey
        } else {
            var oddPubkey = Data([0x03])
            oddPubkey.append(recipientPubkey)
            publicKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: oddPubkey, format: .compressed)
        }

        // Compute ECDH shared point
        // The sharedSecret in compressed format is: version (1 byte) + x-coordinate (32 bytes)
        // NIP-44 needs only the x-coordinate, so skip the version byte
        let sharedSecret = privateKey.sharedSecretFromKeyAgreement(with: publicKey, format: .compressed)
        let sharedX = sharedSecret.withUnsafeBytes { bytes in
            Data(bytes.dropFirst())
        }

        // Derive conversation key using HKDF
        let salt = Data("nip44-v2".utf8)
        let conversationKey = hkdfExtract(salt: salt, ikm: sharedX)

        return conversationKey
    }

    /// Derives message keys from conversation key and nonce using HKDF-Expand.
    ///
    /// Internal rather than private so tests can check the derivation against the official
    /// `get_message_keys` vectors, which pin all three outputs for a fixed conversation key.
    static func deriveMessageKeys(
        conversationKey: Data, nonce: Data
    ) -> (chachaKey: Data, chachaNonce: Data, hmacKey: Data) {
        let info = nonce
        let expanded = hkdfExpand(prk: conversationKey, info: info, length: 76)

        let chachaKey = expanded[0..<32]
        let chachaNonce = expanded[32..<44]
        let hmacKey = expanded[44..<76]

        return (Data(chachaKey), Data(chachaNonce), Data(hmacKey))
    }

    /// HKDF-Extract
    private static func hkdfExtract(salt: Data, ikm: Data) -> Data {
        let key = SymmetricKey(data: salt)
        let prk = HMAC<Crypto.SHA256>.authenticationCode(for: ikm, using: key)
        return Data(prk)
    }

    /// HKDF-Expand
    private static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        // RFC 5869 caps the output at 255 blocks, which is also where the `UInt8` block counter
        // below would overflow and trap. `length` is a fixed 76 at the only call site, so this
        // pins an internal invariant rather than validating input.
        precondition(length <= 255 * 32, "HKDF-Expand output is limited to 255 blocks")

        let key = SymmetricKey(data: prk)
        var output = Data()
        var t = Data()
        var counter: UInt8 = 1

        while output.count < length {
            var input = t
            input.append(info)
            input.append(counter)
            t = Data(HMAC<Crypto.SHA256>.authenticationCode(for: input, using: key))
            output.append(t)
            counter += 1
        }

        return output.prefix(length)
    }

    /// Applies the NIP-44 ChaCha20 stream cipher to `data`.
    ///
    /// NIP-44 uses bare ChaCha20 with the block counter starting at 0 (RFC 8439 §2.4), not the
    /// AEAD construction, whose message keystream starts at counter 1. Because ChaCha20 is a
    /// stream cipher the same XOR both encrypts and decrypts, so `seal` and `open` share this.
    private static func chacha20(_ data: Data, key: Data, nonce: Data) throws -> Data {
        try ChaCha20.xor(data, key: key, nonce: nonce)
    }

    /// Pads plaintext according to NIP-44 spec
    private static func pad(_ plaintext: Data) throws -> Data {
        let unpaddedLen = plaintext.count
        guard unpaddedLen >= minPlaintextSize,
            unpaddedLen <= maxPlaintextSize
        else {
            throw NostrError.encryptionFailed
        }

        // Calculate padded length
        let paddedLen = calcPaddedLen(unpaddedLen)

        // Create padded data: 2-byte BE length prefix + plaintext + zero padding
        var padded = Data()
        padded.append(UInt8((unpaddedLen >> 8) & 0xFF))
        padded.append(UInt8(unpaddedLen & 0xFF))
        padded.append(plaintext)
        padded.append(Data(repeating: 0, count: paddedLen - unpaddedLen))

        return padded
    }

    /// Unpads plaintext according to NIP-44 spec.
    ///
    /// The padded block must be exactly what a compliant encryptor produces: the declared length
    /// has to be in range *and* the block has to be the 2-byte prefix plus `calcPaddedLen` of that
    /// length. A merely-sufficient block is not enough — an attacker who can re-pad a plaintext
    /// into a longer or shorter block still produces a valid MAC over it, so accepting
    /// non-canonical padding would make the ciphertext malleable. The official `invalid padding`
    /// vectors are exactly that: correct MACs over blocks no compliant encryptor emits.
    private static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 2 else {
            throw NostrError.invalidPadding
        }

        let unpaddedLen = (Int(padded[0]) << 8) | Int(padded[1])

        guard unpaddedLen >= minPlaintextSize,
            unpaddedLen <= maxPlaintextSize,
            padded.count == 2 + calcPaddedLen(unpaddedLen)
        else {
            throw NostrError.invalidPadding
        }

        return padded[2..<(2 + unpaddedLen)]
    }

    /// Calculates the padded length for a given unpadded length, per the NIP-44 `calc_padded_len`
    /// algorithm. Uses integer arithmetic so the result is exact at power-of-two boundaries where
    /// floating-point rounding would drift.
    ///
    /// Internal rather than private so tests can check the table against the official
    /// `calc_padded_len` vectors directly.
    static func calcPaddedLen(_ unpaddedLen: Int) -> Int {
        if unpaddedLen <= 32 {
            return 32
        }

        // nextPower = 2^(floor(log2(unpaddedLen - 1)) + 1); floor(log2(x)) for a positive Int is
        // its highest set bit index, i.e. (bitWidth - leadingZeroBitCount - 1).
        let highestBit = (unpaddedLen - 1).bitWidth - (unpaddedLen - 1).leadingZeroBitCount - 1
        let nextPower = 1 << (highestBit + 1)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * ((unpaddedLen - 1) / chunk + 1)
    }

    /// Compares two Data values in constant time to prevent timing attacks
    /// - Parameters:
    ///   - lhs: First data to compare
    ///   - rhs: Second data to compare
    /// - Returns: true if the data is equal, false otherwise
    private static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var result: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            result |= a ^ b
        }
        return result == 0
    }

    /// Generates cryptographically secure random bytes
    /// - Parameter count: The number of random bytes to generate
    /// - Returns: Data containing the random bytes
    private static func generateSecureRandomBytes(count: Int) throws -> Data {
        try SecureRandom.generateBytes(count: count)
    }
}
