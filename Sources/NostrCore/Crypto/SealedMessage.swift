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
        guard let recipientPubkeyData = Data(hexString: recipientPubkey) else {
            throw NostrError.invalidPublicKey
        }

        let plaintextData = Data(message.utf8)

        guard plaintextData.count >= minPlaintextSize,
            plaintextData.count <= maxPlaintextSize
        else {
            throw NostrError.encryptionFailed
        }

        // 1. Calculate conversation key
        let conversationKey = try getConversationKey(
            senderPrivateKey: senderKeyPair.privateKey,
            recipientPubkey: recipientPubkeyData
        )

        // 2. Generate random nonce (32 bytes)
        let nonce = try generateSecureRandomBytes(count: 32)

        // 3. Derive message keys from conversation key and nonce
        let (chachaKey, chachaNonce, hmacKey) = deriveMessageKeys(conversationKey: conversationKey, nonce: nonce)

        // 4. Pad the plaintext
        let padded = try pad(plaintextData)

        // 5. Encrypt with ChaCha20
        let ciphertext = try chacha20Encrypt(data: padded, key: chachaKey, nonce: chachaNonce)

        // 6. Calculate HMAC
        let hmacInput = nonce + ciphertext
        let mac = HMAC<Crypto.SHA256>.authenticationCode(for: hmacInput, using: SymmetricKey(data: hmacKey))

        // 7. Assemble payload: version || nonce || ciphertext || mac
        var payloadData = Data([version])
        payloadData.append(nonce)
        payloadData.append(ciphertext)
        payloadData.append(Data(mac))

        return SealedMessage(payload: payloadData.base64EncodedString())
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

        guard let payloadData = Data(base64Encoded: payload) else {
            throw NostrError.invalidPayloadFormat
        }

        // Minimum: 1 (version) + 32 (nonce) + 32 (min ciphertext) + 32 (mac) = 97 bytes
        guard payloadData.count >= 97 else {
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

        // 2. Calculate conversation key
        let conversationKey = try Self.getConversationKey(
            senderPrivateKey: recipientKeyPair.privateKey,
            recipientPubkey: senderPubkeyData
        )

        // 3. Derive message keys
        let (chachaKey, chachaNonce, hmacKey) = Self.deriveMessageKeys(
            conversationKey: conversationKey, nonce: Data(nonce))

        // 4. Verify HMAC using timing-safe comparison
        let hmacInput = Data(nonce) + Data(ciphertext)
        let expectedMac = HMAC<Crypto.SHA256>.authenticationCode(for: hmacInput, using: SymmetricKey(data: hmacKey))

        guard Self.timingSafeEqual(Data(mac), Data(expectedMac)) else {
            throw NostrError.hmacVerificationFailed
        }

        // 5. Decrypt with ChaCha20
        let padded = try Self.chacha20Stream(data: Data(ciphertext), key: chachaKey, nonce: chachaNonce)

        // 6. Unpad
        let plaintext = try Self.unpad(padded)

        guard let message = String(data: plaintext, encoding: .utf8) else {
            throw NostrError.invalidPayloadFormat
        }

        return message
    }

    // MARK: - Internal Methods

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

    /// Derives message keys from conversation key and nonce using HKDF-Expand
    private static func deriveMessageKeys(
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

    /// ChaCha20 encryption
    private static func chacha20Encrypt(data: Data, key: Data, nonce: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonce)

        // Use ChaCha20-Poly1305 but ignore the tag (NIP-44 uses separate HMAC)
        let sealedBox = try ChaChaPoly.seal(data, using: symmetricKey, nonce: chachaNonce)

        return sealedBox.ciphertext
    }

    /// Pure ChaCha20 stream cipher (XOR with keystream)
    private static func chacha20Stream(data: Data, key: Data, nonce: Data) throws -> Data {
        // Generate keystream by encrypting zeros
        let zeros = Data(repeating: 0, count: data.count)
        let symmetricKey = SymmetricKey(data: key)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonce)

        let sealedBox = try ChaChaPoly.seal(zeros, using: symmetricKey, nonce: chachaNonce)
        let keystream = sealedBox.ciphertext

        // XOR data with keystream using zip for safer iteration
        let result = Data(zip(data, keystream).map { $0 ^ $1 })

        return result
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

    /// Unpads plaintext according to NIP-44 spec
    private static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 2 else {
            throw NostrError.invalidPadding
        }

        let unpaddedLen = (Int(padded[0]) << 8) | Int(padded[1])

        guard unpaddedLen >= minPlaintextSize,
            unpaddedLen <= maxPlaintextSize,
            unpaddedLen <= padded.count - 2
        else {
            throw NostrError.invalidPadding
        }

        return padded[2..<(2 + unpaddedLen)]
    }

    /// Calculates the padded length for a given unpadded length
    private static func calcPaddedLen(_ unpaddedLen: Int) -> Int {
        if unpaddedLen <= 32 {
            return 32
        }

        let nextPower = Int(ceil(log2(Double(unpaddedLen))))
        let chunk = max(32, 1 << (nextPower - 1))
        return chunk * Int(ceil(Double(unpaddedLen) / Double(chunk)))
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
