import Foundation
import Testing

@testable import NostrCore

/// ``NIP44Payload/encrypt(_:with:)`` and ``NIP44Payload/decrypt(with:)``, which take the NIP-44
/// conversation key from the caller instead of deriving it from a key pair.
@Suite("NIP44Payload Conversation Key Tests")
struct NIP44PayloadConversationKeyTests {

    // MARK: - Round Trip

    @Test("A message encrypted under a conversation key decrypts under the same key")
    func roundTrip() throws {
        let key = ConversationKey.random()
        let plaintext = "gm, group 🍕"

        let encrypted = try NIP44Payload.encrypt(plaintext, with: key)

        #expect(try encrypted.decrypt(with: key) == plaintext)
    }

    @Test("Encrypting the same message twice uses a fresh nonce each time")
    func freshNoncePerEncryption() throws {
        let key = ConversationKey.random()

        let first = try NIP44Payload.encrypt("hello", with: key)
        let second = try NIP44Payload.encrypt("hello", with: key)

        #expect(first.base64 != second.base64)
        let firstNonce = try #require(Data(base64Encoded: first.base64))[1..<33]
        let secondNonce = try #require(Data(base64Encoded: second.base64))[1..<33]
        #expect(firstNonce != secondNonce)
    }

    @Test("A message encrypted under one key does not decrypt under another")
    func wrongKeyFails() throws {
        let encrypted = try NIP44Payload.encrypt("secret", with: .random())
        let otherKey = ConversationKey.random()

        #expect(throws: NIP44Payload.Error.invalidMAC) {
            _ = try encrypted.decrypt(with: otherKey)
        }
    }

    // MARK: - Interop

    @Test("A key-pair encryption decrypts under that pair's conversation key")
    func keyPairEncryptionDecryptsUnderConversationKey() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let key = try ConversationKey(privateKey: alice.privateKey, publicKey: bob.publicKey)

        let encrypted = try NIP44Payload.encrypt("from Alice", for: bob.publicKey, using: alice)

        #expect(try encrypted.decrypt(with: key) == "from Alice")
    }

    @Test("A conversation-key encryption decrypts with the matching key pair")
    func conversationKeyEncryptionDecryptsWithKeyPair() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let key = try ConversationKey(privateKey: alice.privateKey, publicKey: bob.publicKey)

        let encrypted = try NIP44Payload.encrypt("to Bob", with: key)

        #expect(try encrypted.decrypt(from: alice.publicKey, using: bob) == "to Bob")
    }

    @Test(
        "Official encrypt_decrypt payloads decrypt under their conversation key",
        arguments: NIP44Vectors.valid.encryptDecrypt
    )
    func officialVectorDecrypts(_ vector: NIP44Vectors.EncryptDecryptVector) throws {
        let key = try NIP44Vectors.conversationKey(hex: vector.conversationKey)

        let decrypted = try NIP44Payload(base64: vector.payload).decrypt(with: key)

        #expect(Data(decrypted.utf8) == Data(vector.plaintext.utf8))
    }

    // MARK: - Failure Modes

    @Test("encrypt rejects an empty message")
    func encryptRejectsEmptyMessage() {
        let key = ConversationKey.random()

        #expect(throws: NIP44Payload.Error.invalidPlaintextLength(0)) {
            _ = try NIP44Payload.encrypt("", with: key)
        }
    }
}
