import Crypto
import Foundation
import P256K

/// NIP-44 Versioned Encryption
/// https://github.com/nostr-protocol/nips/blob/master/44.md
///
/// Two modes produce the same NIP-44 v2 payload. ``seal(_:for:using:)`` and
/// ``open(from:using:)`` derive the conversation key from a sender and recipient key pair, for
/// one-to-one messages. ``seal(_:conversationKey:)`` and ``open(conversationKey:)`` take the
/// conversation key directly, for a ciphertext shared by everyone who holds that key.
public struct SealedMessage: Sendable {
    /// The base64-encoded sealed payload
    public let payload: String

    /// Current NIP-44 version
    public static let version: UInt8 = 2

    /// Minimum padded length
    private static let minimumPlaintextSize = 1
    private static let maximumPlaintextSize = 65535
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
    ///   - recipientPublicKey: The recipient's public key
    ///   - senderKeyPair: The sender's key pair
    /// - Returns: A SealedMessage containing the encrypted payload
    /// - Throws: ``SealedMessage/Error/invalidPlaintextLength(_:)`` if `message` is not 1 to 65535
    ///   bytes of UTF-8, or ``SealedMessage/Error/invalidPublicKey`` if `recipientPublicKey` is not
    ///   a point on secp256k1.
    public static func seal(
        _ message: String,
        for recipientPublicKey: PublicKey,
        using senderKeyPair: KeyPair
    ) throws(SealedMessage.Error) -> SealedMessage {
        // Generate a random 32-byte nonce, then delegate to the deterministic implementation.
        let nonce = SecureRandom.generateBytes(count: 32)
        return try seal(message, for: recipientPublicKey, using: senderKeyPair, nonce: nonce)
    }

    /// Seals a message with a caller-supplied nonce.
    ///
    /// Internal and intended for tests that pin the on-wire output to a known nonce (e.g. the
    /// official NIP-44 vectors). Production callers should use ``seal(_:for:using:)``, which
    /// generates a fresh random nonce for every message as the spec requires.
    /// - Parameters:
    ///   - message: The plaintext message to seal.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - senderKeyPair: The sender's key pair.
    ///   - nonce: The 32-byte nonce to use.
    /// - Returns: A SealedMessage containing the encrypted payload.
    static func seal(
        _ message: String,
        for recipientPublicKey: PublicKey,
        using senderKeyPair: KeyPair,
        nonce: Data
    ) throws(SealedMessage.Error) -> SealedMessage {
        let conversationKey = try Self.conversationKey(
            privateKey: senderKeyPair.privateKey,
            publicKey: recipientPublicKey.data
        )

        let payload = try encrypt(plaintext: message, conversationKey: conversationKey, nonce: nonce)
        return SealedMessage(payload: payload)
    }

    /// Seals a message under a caller-supplied conversation key.
    ///
    /// A conversation key is the 32-byte NIP-44 key that the per-message keys are expanded from.
    /// ``seal(_:for:using:)`` derives it by ECDH and HKDF from a key pair; here the caller supplies
    /// it, e.g. a key shared among a group so that one ciphertext can be read by all of its
    /// members. It must be uniformly random secret material, such as 32 bytes from a CSPRNG.
    ///
    /// A fresh random nonce is generated for every call. The payload is standard NIP-44 v2, so any
    /// implementation holding the same conversation key can open it.
    ///
    /// NIP-44 authenticates the key, not a sender: anyone holding the conversation key can both
    /// read and forge messages under it.
    /// - Parameters:
    ///   - message: The plaintext message to seal.
    ///   - conversationKey: The 32-byte conversation key.
    /// - Returns: A SealedMessage containing the encrypted payload.
    /// - Throws: ``SealedMessage/Error/invalidPlaintextLength(_:)`` if `message` is not 1 to 65535
    ///   bytes of UTF-8, or ``SealedMessage/Error/invalidConversationKey`` if `conversationKey` is
    ///   not 32 bytes.
    public static func seal(_ message: String, conversationKey: Data) throws(SealedMessage.Error) -> SealedMessage {
        let nonce = SecureRandom.generateBytes(count: nonceByteCount)
        let payload = try encrypt(plaintext: message, conversationKey: conversationKey, nonce: nonce)
        return SealedMessage(payload: payload)
    }

    /// Encrypts a plaintext under an already-derived conversation key.
    ///
    /// Backs ``seal(_:conversationKey:)`` and ``seal(_:for:using:)``. Taking the nonce keeps it
    /// testable against the official `encrypt_decrypt` vectors, which give the conversation key and
    /// nonce directly; it stays internal so that callers cannot reuse a nonce. Splitting this out
    /// mirrors the reference implementation's own `encrypt`/`get_conversation_key` split.
    /// - Parameters:
    ///   - plaintext: The plaintext message.
    ///   - conversationKey: The 32-byte conversation key.
    ///   - nonce: The 32-byte nonce.
    /// - Returns: The base64-encoded `version || nonce || ciphertext || mac` payload.
    static func encrypt(
        plaintext: String, conversationKey: Data, nonce: Data
    ) throws(SealedMessage.Error) -> String {
        // Measured rather than encoded first, so an out-of-range plaintext — the invalid vectors
        // reach 10 MB — is rejected without copying it or expanding the message keys.
        let unpaddedLen = plaintext.utf8.count
        guard unpaddedLen >= minimumPlaintextSize,
            unpaddedLen <= maximumPlaintextSize
        else {
            throw .invalidPlaintextLength(unpaddedLen)
        }

        // HKDF accepts inputs of any length, so a wrong-length key or nonce would expand into a
        // payload that is well-formed and undecryptable by anyone — a failure that surfaces only on
        // the recipient's side, if at all.
        guard conversationKey.count == conversationKeyByteCount else {
            throw .invalidConversationKey
        }
        guard nonce.count == nonceByteCount else {
            throw .invalidNonce
        }

        let plaintextData = Data(plaintext.utf8)

        // 1. Derive message keys from conversation key and nonce
        var (chachaKey, chachaNonce, hmacKey) = deriveMessageKeys(conversationKey: conversationKey, nonce: nonce)
        // Zeroed once the payload is assembled: these are per-message keys with no use afterwards.
        defer {
            chachaKey.secureScrub()
            chachaNonce.secureScrub()
            hmacKey.secureScrub()
        }

        // 2. Pad the plaintext
        var padded = pad(plaintextData)
        defer { padded.secureScrub() }

        // 3. Encrypt with ChaCha20
        let ciphertext = chacha20(padded, key: chachaKey, nonce: chachaNonce)

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
    ///   - senderPublicKey: The sender's public key
    ///   - recipientKeyPair: The recipient's key pair
    /// - Returns: The decrypted plaintext message
    /// - Throws: ``SealedMessage/Error/invalidPublicKey`` if `senderPublicKey` is not a point on
    ///   secp256k1, or what ``open(conversationKey:)`` throws for a payload that does not open.
    public func open(
        from senderPublicKey: PublicKey, using recipientKeyPair: KeyPair
    ) throws(SealedMessage.Error) -> String {
        let conversationKey = try Self.conversationKey(
            privateKey: recipientKeyPair.privateKey,
            publicKey: senderPublicKey.data
        )

        return try Self.decrypt(payload: payload, conversationKey: conversationKey)
    }

    /// Opens a message sealed under a caller-supplied conversation key.
    ///
    /// The counterpart of ``seal(_:conversationKey:)``. It opens any NIP-44 v2 payload encrypted
    /// under `conversationKey`, including one sealed with ``seal(_:for:using:)`` when the caller
    /// holds that pair's conversation key.
    ///
    /// A successful open shows only that the payload was sealed by someone holding the
    /// conversation key, not who: anyone holding it can both read and forge messages under it.
    /// - Parameter conversationKey: The 32-byte conversation key.
    /// - Returns: The decrypted plaintext message.
    /// - Throws: ``SealedMessage/Error/invalidConversationKey`` if `conversationKey` is not 32
    ///   bytes; ``SealedMessage/Error/malformedPayload`` if the payload is not valid base64, is out
    ///   of range, or does not decrypt to UTF-8; ``SealedMessage/Error/unsupportedVersion(_:)`` if
    ///   its version is not 2; ``SealedMessage/Error/invalidMAC`` if it was not sealed under this
    ///   key or was altered; ``SealedMessage/Error/invalidPadding`` if its padding is not canonical.
    public func open(conversationKey: Data) throws(SealedMessage.Error) -> String {
        try Self.decrypt(payload: payload, conversationKey: conversationKey)
    }

    /// Decrypts a base64 payload under an already-derived conversation key.
    ///
    /// Backs ``open(conversationKey:)`` and ``open(from:using:)``, and lets tests drive the
    /// official `encrypt_decrypt` and `invalid.decrypt` vectors, which give the conversation key
    /// directly rather than a pair of keys. Splitting this out mirrors the reference
    /// implementation's own `decrypt` / `get_conversation_key` split.
    /// - Parameters:
    ///   - payload: The base64-encoded `version || nonce || ciphertext || mac` payload.
    ///   - conversationKey: The 32-byte conversation key.
    /// - Returns: The decrypted plaintext message.
    static func decrypt(payload: String, conversationKey: Data) throws(SealedMessage.Error) -> String {
        guard conversationKey.count == conversationKeyByteCount else {
            throw .invalidConversationKey
        }

        guard let payloadData = Data(base64Encoded: payload) else {
            throw .malformedPayload
        }

        // The smallest padded plaintext is a 2-byte length prefix plus one 32-byte block, and the
        // largest is that prefix plus 65536 bytes, so the decoded payload is
        // 1 (version) + 32 (nonce) + [34, 65538] (ciphertext) + 32 (mac) = [99, 65603] bytes.
        guard payloadData.count >= 99, payloadData.count <= 65603 else {
            throw .malformedPayload
        }

        // 1. Parse payload
        let version = payloadData[0]
        guard version == Self.version else {
            throw .unsupportedVersion(version)
        }

        let nonce = payloadData[1..<33]
        let mac = payloadData[(payloadData.count - 32)...]
        let ciphertext = payloadData[33..<(payloadData.count - 32)]

        // 2. Derive message keys
        var (chachaKey, chachaNonce, hmacKey) = Self.deriveMessageKeys(
            conversationKey: conversationKey, nonce: Data(nonce))
        defer {
            chachaKey.secureScrub()
            chachaNonce.secureScrub()
            hmacKey.secureScrub()
        }

        // 3. Verify HMAC using timing-safe comparison
        let hmacInput = Data(nonce) + Data(ciphertext)
        let expectedMac = HMAC<Crypto.SHA256>.authenticationCode(for: hmacInput, using: SymmetricKey(data: hmacKey))

        guard Self.timingSafeEqual(Data(mac), Data(expectedMac)) else {
            throw .invalidMAC
        }

        // 4. Decrypt with ChaCha20
        var padded = Self.chacha20(Data(ciphertext), key: chachaKey, nonce: chachaNonce)
        defer { padded.secureScrub() }

        // 5. Unpad
        let plaintext = try Self.unpad(padded)

        guard let message = String(data: plaintext, encoding: .utf8) else {
            throw .malformedPayload
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
    /// - Throws: ``KeyPair/Error`` or ``PublicKey/Error`` for a key that does not parse, or
    ///   ``SealedMessage/Error/invalidPublicKey`` if the public key is not a point on secp256k1.
    static func conversationKeyHex(privateKeyHex: String, publicKeyHex: String) throws -> String {
        let keyPair = try KeyPair(privateKeyHex: privateKeyHex)
        let publicKey = try PublicKey(hex: publicKeyHex)
        let conversationKey = try Self.conversationKey(privateKey: keyPair.privateKey, publicKey: publicKey.data)
        return conversationKey.hexEncodedString()
    }

    /// Computes the conversation key using ECDH + HKDF.
    /// - Parameters:
    ///   - privateKey: The caller's 32-byte private key, taken from a ``KeyPair`` and so a valid
    ///     secp256k1 scalar.
    ///   - publicKey: The peer's 32-byte x-only public key.
    private static func conversationKey(privateKey: Data, publicKey: Data) throws(SealedMessage.Error) -> Data {
        // Get the private key for ECDH (use KeyAgreement, not Signing). A KeyPair only ever holds a
        // valid scalar, so this cannot fail.
        let agreementKey: P256K.KeyAgreement.PrivateKey
        do {
            agreementKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        } catch {
            preconditionFailure("A KeyPair holds a valid secp256k1 scalar: \(error)")
        }

        // Lift the x-only public key to a full point. Either parity yields the same shared x, so
        // the even one (0x02) is tried first and the odd one (0x03) only if that fails.
        let peerKey: P256K.KeyAgreement.PublicKey
        if let evenKey = try? P256K.KeyAgreement.PublicKey(
            dataRepresentation: Data([0x02]) + publicKey, format: .compressed)
        {
            peerKey = evenKey
        } else if let oddKey = try? P256K.KeyAgreement.PublicKey(
            dataRepresentation: Data([0x03]) + publicKey, format: .compressed)
        {
            peerKey = oddKey
        } else {
            throw .invalidPublicKey
        }

        // Compute ECDH shared point
        // The sharedSecret in compressed format is: version (1 byte) + x-coordinate (32 bytes)
        // NIP-44 needs only the x-coordinate, so skip the version byte
        let sharedSecret = agreementKey.sharedSecretFromKeyAgreement(with: peerKey, format: .compressed)
        var sharedX = sharedSecret.withUnsafeBytes { bytes in
            Data(bytes.dropFirst())
        }
        // The conversation key is derived from this; nothing needs the shared point afterwards.
        defer { sharedX.secureScrub() }

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
        // RFC 5869 caps the output at 255 blocks. The bound here is one block lower: `counter`
        // is incremented at the end of every iteration, so producing the 255th block would take it
        // to 256 and trap before the loop could exit. `length` is a fixed 76 at the only call site,
        // so this pins an internal invariant rather than validating input.
        precondition(length <= 254 * 32, "HKDF-Expand output is limited to 254 blocks here")

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
    private static func chacha20(_ data: Data, key: Data, nonce: Data) -> Data {
        ChaCha20.xor(data, key: key, nonce: nonce)
    }

    /// Pads plaintext according to NIP-44 spec. ``encrypt(plaintext:conversationKey:nonce:)``
    /// rejects an out-of-range plaintext before calling this.
    private static func pad(_ plaintext: Data) -> Data {
        let unpaddedLen = plaintext.count
        precondition(
            unpaddedLen >= minimumPlaintextSize && unpaddedLen <= maximumPlaintextSize,
            "A NIP-44 plaintext is 1 to 65535 bytes")

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
    private static func unpad(_ padded: Data) throws(SealedMessage.Error) -> Data {
        guard padded.count >= 2 else {
            throw .invalidPadding
        }

        let unpaddedLen = (Int(padded[0]) << 8) | Int(padded[1])

        guard unpaddedLen >= minimumPlaintextSize,
            unpaddedLen <= maximumPlaintextSize,
            padded.count == 2 + calcPaddedLen(unpaddedLen)
        else {
            throw .invalidPadding
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
}

extension SealedMessage {
    /// Why a NIP-44 message could not be sealed or opened.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The conversation key is not 32 bytes.
        case invalidConversationKey
        /// The plaintext is not 1 to 65535 bytes of UTF-8 (payload: its byte count).
        case invalidPlaintextLength(Int)
        /// The nonce is not 32 bytes.
        case invalidNonce
        /// The peer's public key is not a point on secp256k1, so no conversation key can be derived.
        case invalidPublicKey
        /// The payload is not valid base64, its length is out of range, or it does not decrypt to
        /// UTF-8.
        case malformedPayload
        /// The payload declares a version other than 2 (payload: the version byte).
        case unsupportedVersion(UInt8)
        /// The MAC does not match: the payload was not sealed under this conversation key, or it
        /// was altered.
        case invalidMAC
        /// The decrypted padding is not the canonical NIP-44 layout.
        case invalidPadding

        public var errorDescription: String? {
            switch self {
            case .invalidConversationKey:
                return "A NIP-44 conversation key must be 32 bytes"
            case .invalidPlaintextLength(let count):
                return "A NIP-44 plaintext must be 1 to 65535 bytes, got \(count)"
            case .invalidNonce:
                return "A NIP-44 nonce must be 32 bytes"
            case .invalidPublicKey:
                return "The public key is not a point on secp256k1"
            case .malformedPayload:
                return "The NIP-44 payload is malformed"
            case .unsupportedVersion(let version):
                return "Unsupported NIP-44 version: \(version)"
            case .invalidMAC:
                return "The NIP-44 payload failed MAC verification"
            case .invalidPadding:
                return "The NIP-44 payload has invalid padding"
            }
        }
    }
}
