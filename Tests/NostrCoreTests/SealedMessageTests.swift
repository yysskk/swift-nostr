import Foundation
import NostrCore
import Testing

@Suite("SealedMessage Tests")
struct SealedMessageTests {

    // MARK: - Round Trip

    @Test("Alice seals to Bob and Bob opens the original plaintext")
    func roundTrip() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let plaintext = "gm from Alice"

        let sealed = try SealedMessage.seal(plaintext, for: bob.publicKey, using: alice)
        let opened = try sealed.open(from: alice.publicKey, using: bob)

        #expect(opened == plaintext)
    }

    @Test("Round trip preserves unicode and emoji")
    func roundTripUnicode() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let plaintext = "こんにちは 🍕🫃 café naïve"

        let sealed = try SealedMessage.seal(plaintext, for: bob.publicKey, using: alice)
        let opened = try sealed.open(from: alice.publicKey, using: bob)

        #expect(opened == plaintext)
    }

    @Test("Round trip preserves a long message")
    func roundTripLongMessage() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let plaintext = String(repeating: "The quick brown fox. ", count: 500)

        let sealed = try SealedMessage.seal(plaintext, for: bob.publicKey, using: alice)
        let opened = try sealed.open(from: alice.publicKey, using: bob)

        #expect(opened == plaintext)
    }

    // MARK: - Payload Shape

    @Test("Payload is non-empty base64 with a version-2 first byte")
    func payloadShape() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let sealed = try SealedMessage.seal("hello", for: bob.publicKey, using: alice)

        #expect(!sealed.payload.isEmpty)
        let decoded = try #require(Data(base64Encoded: sealed.payload))
        #expect(decoded.first == SealedMessage.version)
        #expect(SealedMessage.version == 2)
    }

    // MARK: - Failure Modes

    @Test("Opening with the wrong recipient key throws")
    func wrongRecipientFails() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let mallory = KeyPair()

        let sealed = try SealedMessage.seal("secret", for: bob.publicKey, using: alice)

        // Mallory derives a different conversation key, so the HMAC check fails.
        #expect(throws: SealedMessage.Error.invalidMAC) {
            _ = try sealed.open(from: alice.publicKey, using: mallory)
        }
    }

    @Test("Tampering with the payload makes open fail the HMAC check")
    func tamperingFails() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let sealed = try SealedMessage.seal("secret", for: bob.publicKey, using: alice)

        var bytes = try #require(Data(base64Encoded: sealed.payload))
        // Flip a bit in the ciphertext region (byte 40 is past the version + 32-byte nonce).
        bytes[40] ^= 0x01
        let tampered = SealedMessage(payload: bytes.base64EncodedString())

        #expect(throws: SealedMessage.Error.invalidMAC) {
            _ = try tampered.open(from: alice.publicKey, using: bob)
        }
    }

    /// `ff…ff` is 64 well-formed hex digits but exceeds the field prime, so it names no point.
    private static let offCurvePublicKey = PublicKey(String(repeating: "ff", count: 32))!

    @Test("Sealing to a public key that is not on the curve throws")
    func sealToOffCurveKeyFails() throws {
        let alice = KeyPair()

        #expect(throws: SealedMessage.Error.invalidPublicKey) {
            _ = try SealedMessage.seal("secret", for: Self.offCurvePublicKey, using: alice)
        }
    }

    @Test("Opening from a public key that is not on the curve throws")
    func openFromOffCurveKeyFails() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let sealed = try SealedMessage.seal("secret", for: bob.publicKey, using: alice)

        #expect(throws: SealedMessage.Error.invalidPublicKey) {
            _ = try sealed.open(from: Self.offCurvePublicKey, using: bob)
        }
    }

    @Test("A payload that is not base64 is malformed")
    func nonBase64PayloadIsMalformed() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        #expect(throws: SealedMessage.Error.malformedPayload) {
            _ = try SealedMessage(payload: "not base64!").open(from: alice.publicKey, using: bob)
        }
    }

    // Note: the complete official NIP-44 vector suite lives in `NIP44VectorTests`, backed by the
    // bundled `Resources/nip44.vectors.json`; this suite covers random-key round trips and tamper
    // detection through the public API.
}
