import Crypto
import Foundation
import Testing

@testable import NostrCore

/// The complete official NIP-44 v2 interoperability vector suite.
///
/// Spec: https://github.com/nostr-protocol/nips/blob/master/44.md
///
/// The vectors are bundled verbatim as `Resources/nip44.vectors.json`:
/// - Source repository: https://github.com/paulmillr/nip44 (the vector source the spec links to)
/// - Raw URL: https://raw.githubusercontent.com/paulmillr/nip44/main/nip44.vectors.json
/// - sha256: `269ed0f69e4c192512cc779e78c555090cebc7c785b609e338a62afc3ce25040` (37,630 bytes)
///
/// To refresh: re-download from the raw URL into `Tests/NostrCoreTests/Resources/` and update the
/// hash recorded above with the new `shasum -a 256` output.
///
/// These pin swift-nostr's on-wire output to the reference implementation shared by nostr-tools,
/// NDK, and rust-nostr — every conversation key, message-key expansion, padding boundary, payload,
/// and rejection case the reference publishes. 0.6.0 shipped an interop bug (the AEAD ChaCha20
/// keystream at block counter 1 instead of bare ChaCha20 at counter 0) that only four hand-copied
/// vectors were guarding against; running the whole file is what keeps that class of drift out.
@Suite("NIP-44 Vector Tests")
struct NIP44VectorTests {

    // MARK: - Valid vectors

    /// The ECDH + HKDF-Extract conversation-key derivation must match the reference implementation.
    @Test(
        "Conversation keys match the official get_conversation_key vectors",
        arguments: NIP44Vectors.valid.getConversationKey
    )
    func conversationKey(_ vector: NIP44Vectors.ConversationKeyVector) throws {
        let derived = try SealedMessage.conversationKeyHex(
            privateKeyHex: vector.sec1,
            publicKeyHex: vector.pub2
        )

        #expect(derived == vector.conversationKey)
    }

    /// HKDF-Expand must split into the same ChaCha20 key, ChaCha20 nonce, and HMAC key.
    @Test(
        "Message keys match the official get_message_keys vectors",
        arguments: NIP44Vectors.valid.getMessageKeys.keys
    )
    func messageKeys(_ vector: NIP44Vectors.MessageKeysVector) throws {
        let conversationKey = try #require(
            Data(hexString: NIP44Vectors.valid.getMessageKeys.conversationKey)
        )
        let nonce = try #require(Data(hexString: vector.nonce))

        let (chachaKey, chachaNonce, hmacKey) = SealedMessage.deriveMessageKeys(
            conversationKey: conversationKey,
            nonce: nonce
        )

        #expect(chachaKey.hexEncodedString() == vector.chachaKey)
        #expect(chachaNonce.hexEncodedString() == vector.chachaNonce)
        #expect(hmacKey.hexEncodedString() == vector.hmacKey)
    }

    /// The padding table, including the power-of-two boundaries where a floating-point
    /// implementation drifts.
    @Test(
        "Padded lengths match the official calc_padded_len vectors",
        arguments: NIP44Vectors.valid.calcPaddedLen
    )
    func paddedLength(_ vector: NIP44Vectors.PaddedLengthVector) {
        #expect(SealedMessage.calcPaddedLen(vector.unpadded) == vector.padded)
    }

    /// Both parties must derive the vector's conversation key from their own secret and the peer's
    /// public key.
    @Test(
        "encrypt_decrypt conversation keys are symmetric",
        arguments: NIP44Vectors.valid.encryptDecrypt
    )
    func encryptDecryptConversationKey(_ vector: NIP44Vectors.EncryptDecryptVector) throws {
        let pub1 = try KeyPair(privateKeyHex: vector.sec1).publicKeyHex
        let pub2 = try KeyPair(privateKeyHex: vector.sec2).publicKeyHex

        let fromSender = try SealedMessage.conversationKeyHex(privateKeyHex: vector.sec1, publicKeyHex: pub2)
        let fromRecipient = try SealedMessage.conversationKeyHex(privateKeyHex: vector.sec2, publicKeyHex: pub1)

        #expect(fromSender == vector.conversationKey)
        #expect(fromRecipient == vector.conversationKey)
    }

    /// Encrypting with the vector's exact nonce must reproduce the reference payload byte for
    /// byte. This locks the encrypt direction to the spec, not just the round trip.
    @Test(
        "Encrypting with the vector nonce reproduces the official payload",
        arguments: NIP44Vectors.valid.encryptDecrypt
    )
    func encryptMatchesPayload(_ vector: NIP44Vectors.EncryptDecryptVector) throws {
        let conversationKey = try #require(Data(hexString: vector.conversationKey))
        let nonce = try #require(Data(hexString: vector.nonce))

        let payload = try SealedMessage.encrypt(
            plaintext: vector.plaintext,
            conversationKey: conversationKey,
            nonce: nonce
        )

        #expect(payload == vector.payload)
    }

    /// Decrypting each reference payload must recover the exact plaintext. This is the direction a
    /// keystream offset by a block corrupts.
    @Test(
        "Decrypting official payloads recovers the plaintext",
        arguments: NIP44Vectors.valid.encryptDecrypt
    )
    func decryptMatchesPlaintext(_ vector: NIP44Vectors.EncryptDecryptVector) throws {
        let conversationKey = try #require(Data(hexString: vector.conversationKey))

        let decrypted = try SealedMessage.decrypt(payload: vector.payload, conversationKey: conversationKey)

        #expect(Data(decrypted.utf8) == Data(vector.plaintext.utf8))
    }

    /// The same vectors through the public key-pair API, so the conversation-key plumbing that
    /// ``SealedMessage/encrypt(plaintext:conversationKey:nonce:)`` skips is covered too.
    @Test(
        "Sealing and opening with key pairs matches the official vectors",
        arguments: NIP44Vectors.valid.encryptDecrypt
    )
    func sealAndOpenMatchVector(_ vector: NIP44Vectors.EncryptDecryptVector) throws {
        let sender = try KeyPair(privateKeyHex: vector.sec1)
        let recipient = try KeyPair(privateKeyHex: vector.sec2)
        let nonce = try #require(Data(hexString: vector.nonce))

        let sealed = try SealedMessage.seal(
            vector.plaintext,
            for: recipient.publicKeyHex,
            using: sender,
            nonce: nonce
        )
        #expect(sealed.payload == vector.payload)

        let opened = try SealedMessage(payload: vector.payload).open(
            from: sender.publicKeyHex,
            using: recipient
        )
        #expect(Data(opened.utf8) == Data(vector.plaintext.utf8))
    }

    /// The maximum-size messages, which span more than a thousand ChaCha20 blocks. The vectors
    /// give digests rather than the payloads themselves; both are digests of the UTF-8 bytes of a
    /// string — the plaintext, and the base64 payload text (not the decoded payload bytes).
    @Test(
        "Long-message vectors match the official digests and round-trip",
        arguments: NIP44Vectors.valid.encryptDecryptLongMsg
    )
    func longMessage(_ vector: NIP44Vectors.LongMessageVector) throws {
        let plaintext = String(repeating: vector.pattern, count: vector.repeatCount)
        #expect(Self.sha256Hex(of: plaintext) == vector.plaintextSha256)

        let conversationKey = try #require(Data(hexString: vector.conversationKey))
        let nonce = try #require(Data(hexString: vector.nonce))

        let payload = try SealedMessage.encrypt(
            plaintext: plaintext,
            conversationKey: conversationKey,
            nonce: nonce
        )
        #expect(Self.sha256Hex(of: payload) == vector.payloadSha256)

        let decrypted = try SealedMessage.decrypt(payload: payload, conversationKey: conversationKey)
        #expect(Data(decrypted.utf8) == Data(plaintext.utf8))
    }

    // MARK: - Invalid vectors

    /// Out-of-range secret keys and public keys that are not on the curve must be rejected. The
    /// errors come from P256K and are untyped, so only the fact of throwing is asserted.
    @Test(
        "Invalid conversation-key inputs are rejected",
        arguments: NIP44Vectors.invalid.getConversationKey
    )
    func invalidConversationKey(_ vector: NIP44Vectors.InvalidConversationKeyVector) {
        #expect(throws: (any Error).self) {
            _ = try SealedMessage.conversationKeyHex(privateKeyHex: vector.sec1, publicKeyHex: vector.pub2)
        }
    }

    /// Plaintexts outside 1...65535 bytes cannot be padded, so encryption must refuse them.
    @Test(
        "Plaintext lengths outside the allowed range are rejected",
        arguments: NIP44Vectors.invalid.encryptMsgLengths
    )
    func invalidPlaintextLength(_ length: Int) {
        #expect(throws: NostrError.encryptionFailed) {
            _ = try SealedMessage.encrypt(
                plaintext: String(repeating: "a", count: length),
                conversationKey: Data(repeating: 0, count: 32),
                nonce: Data(repeating: 0, count: 32)
            )
        }
    }

    /// Every malformed payload the reference publishes must be refused, with the error the failure
    /// mode calls for. The `invalid padding` cases carry valid MACs, so only a strict unpad
    /// rejects them.
    @Test(
        "Malformed payloads are rejected",
        arguments: NIP44Vectors.invalid.decrypt
    )
    func invalidDecrypt(_ vector: NIP44Vectors.InvalidDecryptVector) throws {
        let conversationKey = try #require(Data(hexString: vector.conversationKey))
        let expectedError = try #require(vector.expectedError, "unrecognized vector note: \(vector.note)")

        #expect(throws: expectedError) {
            _ = try SealedMessage.decrypt(payload: vector.payload, conversationKey: conversationKey)
        }
    }

    // MARK: - Helpers

    /// The SHA-256 of a string's UTF-8 bytes, as lowercase hex.
    private static func sha256Hex(of string: String) -> String {
        Data(Crypto.SHA256.hash(data: Data(string.utf8))).hexEncodedString()
    }
}

// MARK: - Vector Data

/// The decoded contents of the bundled `nip44.vectors.json`.
///
/// Decoded once into `static let`s because `@Test(arguments:)` needs its cases available
/// statically. A missing or undecodable resource is a `fatalError` rather than a skip: silently
/// running zero of the suite's vectors is a worse failure than a crash that names the cause.
enum NIP44Vectors: Sendable {
    static let valid = file.v2.valid
    static let invalid = file.v2.invalid

    private static let resourceName = "nip44.vectors"
    private static let sourceURL = "https://raw.githubusercontent.com/paulmillr/nip44/main/nip44.vectors.json"
    private static let file = load()

    private static func load() -> File {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json") else {
            fatalError(
                """
                Missing test resource \(resourceName).json. It is bundled by the NostrCoreTests \
                target (see Package.swift); re-download it from \(sourceURL).
                """
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(File.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Could not decode \(resourceName).json: \(error)")
        }
    }

    // MARK: File shape

    struct File: Decodable, Sendable {
        let v2: Version
    }

    struct Version: Decodable, Sendable {
        let valid: Valid
        let invalid: Invalid
    }

    struct Valid: Decodable, Sendable {
        let getConversationKey: [ConversationKeyVector]
        let getMessageKeys: MessageKeysBlock
        let calcPaddedLen: [PaddedLengthVector]
        let encryptDecrypt: [EncryptDecryptVector]
        let encryptDecryptLongMsg: [LongMessageVector]
    }

    struct Invalid: Decodable, Sendable {
        let encryptMsgLengths: [Int]
        let getConversationKey: [InvalidConversationKeyVector]
        let decrypt: [InvalidDecryptVector]
    }

    // MARK: Valid vector types

    struct ConversationKeyVector: Decodable, Sendable {
        let sec1: String
        let pub2: String
        let conversationKey: String
        /// Present on only a few entries, describing the edge case they cover.
        let note: String?
    }

    struct MessageKeysBlock: Decodable, Sendable {
        let conversationKey: String
        let keys: [MessageKeysVector]
    }

    struct MessageKeysVector: Decodable, Sendable {
        let nonce: String
        let chachaKey: String
        let chachaNonce: String
        let hmacKey: String
    }

    /// One `[unpadded, padded]` pair.
    struct PaddedLengthVector: Decodable, Sendable {
        let unpadded: Int
        let padded: Int

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            unpadded = try container.decode(Int.self)
            padded = try container.decode(Int.self)
        }
    }

    struct EncryptDecryptVector: Decodable, Sendable {
        let sec1: String
        let sec2: String
        let conversationKey: String
        let nonce: String
        let plaintext: String
        let payload: String
    }

    struct LongMessageVector: Decodable, Sendable {
        let conversationKey: String
        let nonce: String
        let pattern: String
        let repeatCount: Int
        let plaintextSha256: String
        let payloadSha256: String

        private enum CodingKeys: String, CodingKey {
            case conversationKey
            case nonce
            case pattern
            // `repeat` is a Swift keyword.
            case repeatCount = "repeat"
            case plaintextSha256
            case payloadSha256
        }
    }

    // MARK: Invalid vector types

    struct InvalidConversationKeyVector: Decodable, Sendable {
        let sec1: String
        let pub2: String
        let note: String
    }

    struct InvalidDecryptVector: Decodable, Sendable {
        let conversationKey: String
        let nonce: String
        let plaintext: String
        let payload: String
        let note: String

        /// The error ``SealedMessage/decrypt(payload:conversationKey:)`` must throw for this
        /// vector, or `nil` if the note is one this suite does not know about — which the test
        /// treats as a failure rather than a skip, so a future vectors update cannot quietly drop
        /// a case.
        var expectedError: NostrError? {
            switch note {
            // This payload is prefixed with `#`, which the reference reads as an unknown version
            // byte. Swift's strict base64 decoder refuses the `#` one step earlier, so the payload
            // is rejected with a different error but the same outcome. Sniffing for `#` before
            // decoding would change public `open` behaviour for no practical gain.
            case "unknown encryption version": .invalidPayloadFormat
            case "unknown encryption version 0": .unsupportedEncryptionVersion(0)
            case "invalid base64": .invalidPayloadFormat
            case "invalid MAC": .hmacVerificationFailed
            case "invalid padding": .invalidPadding
            // The remaining notes carry the offending length, e.g. "invalid payload length: 48".
            default: note.hasPrefix("invalid payload length:") ? .invalidPayloadFormat : nil
            }
        }
    }
}

// MARK: - Test Descriptions

extension NIP44Vectors.ConversationKeyVector: CustomTestStringConvertible {
    var testDescription: String {
        let keys = "sec1 \(sec1.prefix(8)) / pub2 \(pub2.prefix(8))"
        return note.map { "\(keys) (\($0))" } ?? keys
    }
}

extension NIP44Vectors.MessageKeysVector: CustomTestStringConvertible {
    var testDescription: String { "nonce \(nonce.prefix(8))" }
}

extension NIP44Vectors.PaddedLengthVector: CustomTestStringConvertible {
    var testDescription: String { "\(unpadded) -> \(padded)" }
}

extension NIP44Vectors.EncryptDecryptVector: CustomTestStringConvertible {
    var testDescription: String { "\(plaintext.utf8.count)-byte plaintext, nonce \(nonce.prefix(8))" }
}

extension NIP44Vectors.LongMessageVector: CustomTestStringConvertible {
    var testDescription: String { "\(pattern) x \(repeatCount)" }
}

extension NIP44Vectors.InvalidConversationKeyVector: CustomTestStringConvertible {
    var testDescription: String { note }
}

extension NIP44Vectors.InvalidDecryptVector: CustomTestStringConvertible {
    var testDescription: String { note }
}
