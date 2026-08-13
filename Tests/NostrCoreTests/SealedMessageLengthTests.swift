import Foundation
import Testing

@testable import NostrCore

/// NIP-44 derives its ChaCha20 key, nonce, and MAC key by expanding the conversation key over the
/// message nonce. HKDF accepts inputs of any length, so a wrong-length key or nonce produces a
/// perfectly well-formed payload that simply cannot be decrypted by anyone — a silent failure that
/// only shows up on the far side of the conversation.
@Suite("NIP-44 Key and Nonce Length Tests")
struct SealedMessageLengthTests {
    private let validKey = Data(repeating: 0x01, count: 32)
    private let validNonce = Data(repeating: 0x02, count: 32)

    @Test(
        "encrypt rejects a conversation key that is not 32 bytes",
        arguments: [0, 16, 31, 33, 64]
    )
    func encryptRejectsWrongLengthKey(byteCount: Int) {
        #expect(throws: NostrError.encryptionFailed) {
            _ = try SealedMessage.encrypt(
                plaintext: "hello",
                conversationKey: Data(repeating: 0x01, count: byteCount),
                nonce: validNonce
            )
        }
    }

    @Test(
        "encrypt rejects a nonce that is not 32 bytes",
        arguments: [0, 12, 24, 31, 33]
    )
    func encryptRejectsWrongLengthNonce(byteCount: Int) {
        #expect(throws: NostrError.encryptionFailed) {
            _ = try SealedMessage.encrypt(
                plaintext: "hello",
                conversationKey: validKey,
                nonce: Data(repeating: 0x02, count: byteCount)
            )
        }
    }

    @Test(
        "decrypt rejects a conversation key that is not 32 bytes",
        arguments: [0, 16, 31, 33, 64]
    )
    func decryptRejectsWrongLengthKey(byteCount: Int) throws {
        let payload = try SealedMessage.encrypt(
            plaintext: "hello",
            conversationKey: validKey,
            nonce: validNonce
        )

        #expect(throws: NostrError.decryptionFailed) {
            _ = try SealedMessage.decrypt(
                payload: payload,
                conversationKey: Data(repeating: 0x01, count: byteCount)
            )
        }
    }

    @Test("a well-formed key and nonce still round-trip")
    func validLengthsRoundTrip() throws {
        let payload = try SealedMessage.encrypt(
            plaintext: "hello",
            conversationKey: validKey,
            nonce: validNonce
        )

        #expect(try SealedMessage.decrypt(payload: payload, conversationKey: validKey) == "hello")
    }
}
