import Foundation
import NostrCore
import Testing

@Suite("NIP44Payload Tests")
struct NIP44PayloadTests {

    // MARK: - Round Trip

    @Test("Alice encrypts to Bob and Bob decrypts the original plaintext")
    func roundTrip() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let plaintext = "gm from Alice"

        let encrypted = try NIP44Payload.encrypt(plaintext, for: bob.publicKey, using: alice)
        let decrypted = try encrypted.decrypt(from: alice.publicKey, using: bob)

        #expect(decrypted == plaintext)
    }

    @Test("Round trip preserves unicode and emoji")
    func roundTripUnicode() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let plaintext = "こんにちは 🍕🫃 café naïve"

        let encrypted = try NIP44Payload.encrypt(plaintext, for: bob.publicKey, using: alice)
        let decrypted = try encrypted.decrypt(from: alice.publicKey, using: bob)

        #expect(decrypted == plaintext)
    }

    @Test("Round trip preserves a long message")
    func roundTripLongMessage() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let plaintext = String(repeating: "The quick brown fox. ", count: 500)

        let encrypted = try NIP44Payload.encrypt(plaintext, for: bob.publicKey, using: alice)
        let decrypted = try encrypted.decrypt(from: alice.publicKey, using: bob)

        #expect(decrypted == plaintext)
    }

    // MARK: - Payload Shape

    @Test("Payload is non-empty base64 with a version-2 first byte")
    func payloadShape() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let encrypted = try NIP44Payload.encrypt("hello", for: bob.publicKey, using: alice)

        #expect(!encrypted.base64.isEmpty)
        let decoded = try #require(Data(base64Encoded: encrypted.base64))
        #expect(decoded.first == NIP44Payload.version)
        #expect(NIP44Payload.version == 2)
    }

    // MARK: - Failure Modes

    @Test("Decrypting with the wrong recipient key throws")
    func wrongRecipientFails() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let mallory = KeyPair()

        let encrypted = try NIP44Payload.encrypt("secret", for: bob.publicKey, using: alice)

        // Mallory derives a different conversation key, so the HMAC check fails.
        #expect(throws: NIP44Payload.Error.invalidMAC) {
            _ = try encrypted.decrypt(from: alice.publicKey, using: mallory)
        }
    }

    @Test("Tampering with the payload makes decrypt fail the HMAC check")
    func tamperingFails() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let encrypted = try NIP44Payload.encrypt("secret", for: bob.publicKey, using: alice)

        var bytes = try #require(Data(base64Encoded: encrypted.base64))
        // Flip a bit in the ciphertext region (byte 40 is past the version + 32-byte nonce).
        bytes[40] ^= 0x01
        let tampered = NIP44Payload(base64: bytes.base64EncodedString())

        #expect(throws: NIP44Payload.Error.invalidMAC) {
            _ = try tampered.decrypt(from: alice.publicKey, using: bob)
        }
    }

    /// `ff…ff` is 64 well-formed hex digits but exceeds the field prime, so it names no point.
    private static let offCurvePublicKey = PublicKey(String(repeating: "ff", count: 32))!

    @Test("Encrypting to a public key that is not on the curve throws")
    func encryptToOffCurveKeyFails() throws {
        let alice = KeyPair()

        #expect(throws: NIP44Payload.Error.invalidPublicKey) {
            _ = try NIP44Payload.encrypt("secret", for: Self.offCurvePublicKey, using: alice)
        }
    }

    @Test("Decrypting from a public key that is not on the curve throws")
    func decryptFromOffCurveKeyFails() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let encrypted = try NIP44Payload.encrypt("secret", for: bob.publicKey, using: alice)

        #expect(throws: NIP44Payload.Error.invalidPublicKey) {
            _ = try encrypted.decrypt(from: Self.offCurvePublicKey, using: bob)
        }
    }

    @Test("A payload that is not base64 is malformed")
    func nonBase64PayloadIsMalformed() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        #expect(throws: NIP44Payload.Error.malformedPayload) {
            _ = try NIP44Payload(base64: "not base64!").decrypt(from: alice.publicKey, using: bob)
        }
    }

    // Note: the complete official NIP-44 vector suite lives in `NIP44VectorTests`, backed by the
    // bundled `Resources/nip44.vectors.json`; this suite covers random-key round trips and tamper
    // detection through the public API.
}
