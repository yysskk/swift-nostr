import Foundation
import Testing

@testable import NostrCore

/// NIP-44 derives its ChaCha20 key, nonce, and MAC key by expanding the conversation key over the
/// message nonce. HKDF accepts inputs of any length, so a wrong-length nonce produces a perfectly
/// well-formed payload that simply cannot be decrypted by anyone — a silent failure that only shows
/// up on the far side of the conversation. The key's length is checked by ``ConversationKey``.
@Suite("NIP-44 Nonce Length Tests")
struct NIP44PayloadLengthTests {
    private let validNonce = Data(repeating: 0x02, count: 32)

    @Test(
        "encrypt rejects a nonce that is not 32 bytes",
        arguments: [0, 12, 24, 31, 33]
    )
    func encryptRejectsWrongLengthNonce(byteCount: Int) {
        let conversationKey = ConversationKey.random()
        let nonce = Data(repeating: 0x02, count: byteCount)

        #expect(throws: NIP44Payload.Error.invalidNonce) {
            _ = try NIP44Payload.encrypt("hello", with: conversationKey, nonce: nonce)
        }
    }

    @Test("a well-formed nonce still round-trips")
    func validNonceRoundTrips() throws {
        let conversationKey = ConversationKey.random()

        let payload = try NIP44Payload.encrypt("hello", with: conversationKey, nonce: validNonce)

        #expect(try payload.decrypt(with: conversationKey) == "hello")
    }
}
