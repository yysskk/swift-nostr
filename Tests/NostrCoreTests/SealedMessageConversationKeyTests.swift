import Foundation
import Testing

@testable import NostrCore

/// ``SealedMessage/seal(_:conversationKey:)`` and ``SealedMessage/open(conversationKey:)``, which
/// take the NIP-44 conversation key from the caller instead of deriving it from a key pair.
@Suite("SealedMessage Conversation Key Tests")
struct SealedMessageConversationKeyTests {

    private static func randomKey() throws -> Data {
        SecureRandom.generateBytes(count: 32)
    }

    // MARK: - Round Trip

    @Test("A message sealed under a conversation key opens under the same key")
    func roundTrip() throws {
        let key = try Self.randomKey()
        let plaintext = "gm, group 🍕"

        let sealed = try SealedMessage.seal(plaintext, conversationKey: key)

        #expect(try sealed.open(conversationKey: key) == plaintext)
    }

    @Test("Sealing the same message twice uses a fresh nonce each time")
    func freshNoncePerSeal() throws {
        let key = try Self.randomKey()

        let first = try SealedMessage.seal("hello", conversationKey: key)
        let second = try SealedMessage.seal("hello", conversationKey: key)

        #expect(first.payload != second.payload)
        let firstNonce = try #require(Data(base64Encoded: first.payload))[1..<33]
        let secondNonce = try #require(Data(base64Encoded: second.payload))[1..<33]
        #expect(firstNonce != secondNonce)
    }

    @Test("A message sealed under one key does not open under another")
    func wrongKeyFails() throws {
        let sealed = try SealedMessage.seal("secret", conversationKey: Self.randomKey())

        #expect(throws: SealedMessage.Error.invalidMAC) {
            _ = try sealed.open(conversationKey: Self.randomKey())
        }
    }

    // MARK: - Interop

    @Test("A key-pair seal opens under that pair's conversation key")
    func keyPairSealOpensUnderConversationKey() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let key = try #require(
            Data(
                hexString: SealedMessage.conversationKeyHex(
                    privateKeyHex: alice.privateKeyHex,
                    publicKeyHex: bob.publicKey.hex
                )
            )
        )

        let sealed = try SealedMessage.seal("from Alice", for: bob.publicKey, using: alice)

        #expect(try sealed.open(conversationKey: key) == "from Alice")
    }

    @Test("A conversation-key seal opens with the matching key pair")
    func conversationKeySealOpensWithKeyPair() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let key = try #require(
            Data(
                hexString: SealedMessage.conversationKeyHex(
                    privateKeyHex: alice.privateKeyHex,
                    publicKeyHex: bob.publicKey.hex
                )
            )
        )

        let sealed = try SealedMessage.seal("to Bob", conversationKey: key)

        #expect(try sealed.open(from: alice.publicKey, using: bob) == "to Bob")
    }

    @Test(
        "Official encrypt_decrypt payloads open under their conversation key",
        arguments: NIP44Vectors.valid.encryptDecrypt
    )
    func officialVectorOpens(_ vector: NIP44Vectors.EncryptDecryptVector) throws {
        let key = try #require(Data(hexString: vector.conversationKey))

        let opened = try SealedMessage(payload: vector.payload).open(conversationKey: key)

        #expect(Data(opened.utf8) == Data(vector.plaintext.utf8))
    }

    // MARK: - Failure Modes

    @Test("seal rejects a conversation key that is not 32 bytes", arguments: [0, 31, 33])
    func sealRejectsWrongLengthKey(byteCount: Int) {
        #expect(throws: SealedMessage.Error.invalidConversationKey) {
            _ = try SealedMessage.seal("hello", conversationKey: Data(repeating: 0x01, count: byteCount))
        }
    }

    @Test("open rejects a conversation key that is not 32 bytes", arguments: [0, 31, 33])
    func openRejectsWrongLengthKey(byteCount: Int) throws {
        let sealed = try SealedMessage.seal("hello", conversationKey: Self.randomKey())

        #expect(throws: SealedMessage.Error.invalidConversationKey) {
            _ = try sealed.open(conversationKey: Data(repeating: 0x01, count: byteCount))
        }
    }

    @Test("seal rejects an empty message")
    func sealRejectsEmptyMessage() throws {
        let key = try Self.randomKey()

        #expect(throws: SealedMessage.Error.invalidPlaintextLength(0)) {
            _ = try SealedMessage.seal("", conversationKey: key)
        }
    }
}
