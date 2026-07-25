import Foundation
import NostrCore
import Testing

@Suite("SealedMessage Tests")
struct SealedMessageTests {

    // MARK: - Round Trip

    @Test("Alice seals to Bob and Bob opens the original plaintext")
    func roundTrip() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let plaintext = "gm from Alice"

        let sealed = try SealedMessage.seal(plaintext, for: bob.publicKeyHex, using: alice)
        let opened = try sealed.open(from: alice.publicKeyHex, using: bob)

        #expect(opened == plaintext)
    }

    @Test("Round trip preserves unicode and emoji")
    func roundTripUnicode() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let plaintext = "こんにちは 🍕🫃 café naïve"

        let sealed = try SealedMessage.seal(plaintext, for: bob.publicKeyHex, using: alice)
        let opened = try sealed.open(from: alice.publicKeyHex, using: bob)

        #expect(opened == plaintext)
    }

    @Test("Round trip preserves a long message")
    func roundTripLongMessage() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let plaintext = String(repeating: "The quick brown fox. ", count: 500)

        let sealed = try SealedMessage.seal(plaintext, for: bob.publicKeyHex, using: alice)
        let opened = try sealed.open(from: alice.publicKeyHex, using: bob)

        #expect(opened == plaintext)
    }

    // MARK: - Payload Shape

    @Test("Payload is non-empty base64 with a version-2 first byte")
    func payloadShape() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let sealed = try SealedMessage.seal("hello", for: bob.publicKeyHex, using: alice)

        #expect(!sealed.payload.isEmpty)
        let decoded = try #require(Data(base64Encoded: sealed.payload))
        #expect(decoded.first == SealedMessage.version)
        #expect(SealedMessage.version == 2)
    }

    // MARK: - Failure Modes

    @Test("Opening with the wrong recipient key throws")
    func wrongRecipientFails() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let mallory = try KeyPair()

        let sealed = try SealedMessage.seal("secret", for: bob.publicKeyHex, using: alice)

        // Mallory derives a different conversation key, so the HMAC check fails.
        #expect(throws: NostrError.hmacVerificationFailed) {
            _ = try sealed.open(from: alice.publicKeyHex, using: mallory)
        }
    }

    @Test("Tampering with the payload makes open fail the HMAC check")
    func tamperingFails() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let sealed = try SealedMessage.seal("secret", for: bob.publicKeyHex, using: alice)

        var bytes = try #require(Data(base64Encoded: sealed.payload))
        // Flip a bit in the ciphertext region (byte 40 is past the version + 32-byte nonce).
        bytes[40] ^= 0x01
        let tampered = SealedMessage(payload: bytes.base64EncodedString())

        #expect(throws: NostrError.hmacVerificationFailed) {
            _ = try tampered.open(from: alice.publicKeyHex, using: bob)
        }
    }

    // Note: the complete official NIP-44 vector suite lives in `NIP44VectorTests`, backed by the
    // bundled `Resources/nip44.vectors.json`; this suite covers random-key round trips and tamper
    // detection through the public API.
}
