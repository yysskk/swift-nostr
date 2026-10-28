import Crypto
import Foundation

/// A NIP-44 v2 encrypted payload.
/// https://github.com/nostr-protocol/nips/blob/master/44.md
///
/// Every payload is encrypted under a ``ConversationKey``. ``encrypt(_:for:using:)`` and
/// ``decrypt(from:using:)`` derive that key from a sender and recipient key pair, for one-to-one
/// messages. ``encrypt(_:with:)`` and ``decrypt(with:)`` take the key directly, for a ciphertext
/// shared by everyone who holds it. Both produce the same on-wire format.
public struct NIP44Payload: Sendable {
    /// The payload as base64 text, the form a Nostr event carries in its `content`.
    public let base64: String

    /// Current NIP-44 version
    public static let version: UInt8 = 2

    /// Minimum padded length
    private static let minimumPlaintextSize = 1
    private static let maximumPlaintextSize = 65535
    /// The length of the per-message nonce NIP-44 expands the message keys over.
    private static let nonceByteCount = 32

    // MARK: - Initializers

    /// Wraps an existing base64-encoded payload, such as an event's `content`, for decryption.
    public init(base64: String) {
        self.base64 = base64
    }

    // MARK: - Public API

    /// Encrypts a message to a recipient under the conversation key the two parties share.
    /// - Parameters:
    ///   - message: The plaintext message to encrypt.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - senderKeyPair: The sender's key pair.
    /// - Returns: The encrypted payload.
    /// - Throws: ``NIP44Payload/Error/invalidPlaintextLength(_:)`` if `message` is not 1 to 65535
    ///   bytes of UTF-8, or ``NIP44Payload/Error/invalidPublicKey`` if `recipientPublicKey` is not
    ///   a point on secp256k1.
    public static func encrypt(
        _ message: String,
        for recipientPublicKey: PublicKey,
        using senderKeyPair: KeyPair
    ) throws(NIP44Payload.Error) -> NIP44Payload {
        let nonce = SecureRandom.generateBytes(count: nonceByteCount)
        return try encrypt(message, for: recipientPublicKey, using: senderKeyPair, nonce: nonce)
    }

    /// Encrypts a message to a recipient with a caller-supplied nonce.
    ///
    /// Internal and intended for tests that pin the on-wire output to a known nonce (e.g. the
    /// official NIP-44 vectors). Production callers should use ``encrypt(_:for:using:)``, which
    /// generates a fresh random nonce for every message as the spec requires.
    /// - Parameters:
    ///   - message: The plaintext message to encrypt.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - senderKeyPair: The sender's key pair.
    ///   - nonce: The 32-byte nonce to use.
    /// - Returns: The encrypted payload.
    static func encrypt(
        _ message: String,
        for recipientPublicKey: PublicKey,
        using senderKeyPair: KeyPair,
        nonce: Data
    ) throws(NIP44Payload.Error) -> NIP44Payload {
        let conversationKey = try ConversationKey(
            privateKey: senderKeyPair.privateKey,
            publicKey: recipientPublicKey
        )
        return try encrypt(message, with: conversationKey, nonce: nonce)
    }

    /// Encrypts a message under a caller-supplied conversation key.
    ///
    /// ``encrypt(_:for:using:)`` derives the conversation key from a key pair; here the caller
    /// supplies it, e.g. a key from ``ConversationKey/random()`` shared among a group so that one
    /// ciphertext can be read by all of its members.
    ///
    /// A fresh random nonce is generated for every call. The payload is standard NIP-44 v2, so any
    /// implementation holding the same conversation key can decrypt it.
    ///
    /// NIP-44 authenticates the key, not a sender: anyone holding the conversation key can both
    /// read and forge messages under it.
    /// - Parameters:
    ///   - message: The plaintext message to encrypt.
    ///   - conversationKey: The conversation key.
    /// - Returns: The encrypted payload.
    /// - Throws: ``NIP44Payload/Error/invalidPlaintextLength(_:)`` if `message` is not 1 to 65535
    ///   bytes of UTF-8.
    public static func encrypt(
        _ message: String,
        with conversationKey: ConversationKey
    ) throws(NIP44Payload.Error) -> NIP44Payload {
        let nonce = SecureRandom.generateBytes(count: nonceByteCount)
        return try encrypt(message, with: conversationKey, nonce: nonce)
    }

    /// Encrypts a message under a conversation key with a caller-supplied nonce.
    ///
    /// Backs both public `encrypt` forms. Taking the nonce keeps it testable against the official
    /// `encrypt_decrypt` vectors, which give the conversation key and nonce directly; it stays
    /// internal so that callers cannot reuse a nonce. Splitting this out mirrors the reference
    /// implementation's own `encrypt`/`get_conversation_key` split.
    /// - Parameters:
    ///   - message: The plaintext message.
    ///   - conversationKey: The conversation key.
    ///   - nonce: The 32-byte nonce.
    /// - Returns: The `version || nonce || ciphertext || mac` payload.
    /// - Throws: ``NIP44Payload/Error/invalidPlaintextLength(_:)`` if `message` is not 1 to 65535
    ///   bytes of UTF-8, or ``NIP44Payload/Error/invalidNonce`` if `nonce` is not 32 bytes.
    static func encrypt(
        _ message: String,
        with conversationKey: ConversationKey,
        nonce: Data
    ) throws(NIP44Payload.Error) -> NIP44Payload {
        // Measured rather than encoded first, so an out-of-range plaintext — the invalid vectors
        // reach 10 MB — is rejected without copying it or expanding the message keys.
        let unpaddedLen = message.utf8.count
        guard unpaddedLen >= minimumPlaintextSize,
            unpaddedLen <= maximumPlaintextSize
        else {
            throw .invalidPlaintextLength(unpaddedLen)
        }

        // HKDF accepts inputs of any length, so a wrong-length nonce would expand into a payload
        // that is well-formed and undecryptable by anyone — a failure that surfaces only on the
        // recipient's side, if at all. The key's length is guaranteed by ``ConversationKey``.
        guard nonce.count == nonceByteCount else {
            throw .invalidNonce
        }

        let plaintextData = Data(message.utf8)

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

        return NIP44Payload(base64: payloadData.base64EncodedString())
    }

    /// Decrypts a payload from a sender under the conversation key the two parties share.
    /// - Parameters:
    ///   - senderPublicKey: The sender's public key.
    ///   - recipientKeyPair: The recipient's key pair.
    /// - Returns: The decrypted plaintext message.
    /// - Throws: ``NIP44Payload/Error/invalidPublicKey`` if `senderPublicKey` is not a point on
    ///   secp256k1, or what ``decrypt(with:)`` throws for a payload that does not decrypt.
    public func decrypt(
        from senderPublicKey: PublicKey,
        using recipientKeyPair: KeyPair
    ) throws(NIP44Payload.Error) -> String {
        let conversationKey = try ConversationKey(
            privateKey: recipientKeyPair.privateKey,
            publicKey: senderPublicKey
        )
        return try decrypt(with: conversationKey)
    }

    /// Decrypts a payload under a caller-supplied conversation key.
    ///
    /// The counterpart of ``encrypt(_:with:)``. It decrypts any NIP-44 v2 payload encrypted under
    /// `conversationKey`, including one from ``encrypt(_:for:using:)`` when the caller holds that
    /// pair's conversation key.
    ///
    /// A successful decryption shows only that the payload was encrypted by someone holding the
    /// conversation key, not who: anyone holding it can both read and forge messages under it.
    /// - Parameter conversationKey: The conversation key.
    /// - Returns: The decrypted plaintext message.
    /// - Throws: ``NIP44Payload/Error/malformedPayload`` if the payload is not valid base64, is out
    ///   of range, or does not decrypt to UTF-8; ``NIP44Payload/Error/unsupportedVersion(_:)`` if
    ///   its version is not 2; ``NIP44Payload/Error/invalidMAC`` if it was not encrypted under this
    ///   key or was altered; ``NIP44Payload/Error/invalidPadding`` if its padding is not canonical.
    public func decrypt(with conversationKey: ConversationKey) throws(NIP44Payload.Error) -> String {
        guard let payloadData = Data(base64Encoded: base64) else {
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

    /// Derives message keys from conversation key and nonce using HKDF-Expand.
    ///
    /// Internal rather than private so tests can check the derivation against the official
    /// `get_message_keys` vectors, which pin all three outputs for a fixed conversation key.
    static func deriveMessageKeys(
        conversationKey: ConversationKey, nonce: Data
    ) -> (chachaKey: Data, chachaNonce: Data, hmacKey: Data) {
        let info = nonce
        let expanded = hkdfExpand(prk: conversationKey.data, info: info, length: 76)

        let chachaKey = expanded[0..<32]
        let chachaNonce = expanded[32..<44]
        let hmacKey = expanded[44..<76]

        return (Data(chachaKey), Data(chachaNonce), Data(hmacKey))
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
    /// stream cipher the same XOR both encrypts and decrypts, so encryption and decryption share this.
    private static func chacha20(_ data: Data, key: Data, nonce: Data) -> Data {
        ChaCha20.xor(data, key: key, nonce: nonce)
    }

    /// Pads plaintext according to NIP-44 spec. ``encrypt(_:with:nonce:)``
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
    private static func unpad(_ padded: Data) throws(NIP44Payload.Error) -> Data {
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

extension NIP44Payload {
    /// Why a NIP-44 payload could not be encrypted or decrypted.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The bytes given to ``ConversationKey/init(data:)`` are not 32 long.
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
        /// The MAC does not match: the payload was not encrypted under this conversation key, or it
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
