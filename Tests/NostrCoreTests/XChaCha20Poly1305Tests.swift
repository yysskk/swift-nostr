import Foundation
import Testing

@testable import NostrCore

@Suite("XChaCha20-Poly1305 Tests")
struct XChaCha20Poly1305Tests {

    // MARK: - HChaCha20

    /// Official HChaCha20 test vector from draft-irtf-cfrg-xchacha-03 §2.2.1.
    @Test("HChaCha20 matches the draft §2.2.1 subkey vector")
    func hchacha20DraftVector() throws {
        let key = Data(hexString: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
        let nonce = Data(hexString: "000000090000004a0000000031415927")!
        let expectedSubkey = "82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc"

        let subkey = try HChaCha20.deriveSubkey(key: key, nonce: nonce)

        #expect(subkey.hexEncodedString() == expectedSubkey)
    }

    @Test("HChaCha20 rejects a wrong key length")
    func hchacha20RejectsWrongKeyLength() {
        let key = Data(repeating: 0, count: 31)
        let nonce = Data(repeating: 0, count: 16)

        #expect(throws: NostrError.invalidData) {
            try HChaCha20.deriveSubkey(key: key, nonce: nonce)
        }
    }

    @Test("HChaCha20 rejects a wrong nonce length")
    func hchacha20RejectsWrongNonceLength() {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 15)

        #expect(throws: NostrError.invalidData) {
            try HChaCha20.deriveSubkey(key: key, nonce: nonce)
        }
    }

    // MARK: - AEAD vector

    /// Official AEAD_XChaCha20_Poly1305 test vector from draft-irtf-cfrg-xchacha-03 §A.3.1.
    /// The plaintext decodes to the well-known "Ladies and Gentlemen…" sunscreen text.
    @Test("XChaCha20-Poly1305 seal matches the draft §A.3.1 vector")
    func aeadSealDraftVector() throws {
        let plaintext = Data(
            hexString: "4c616469657320616e642047656e746c656d656e206f662074686520636c6173"
                + "73206f66202739393a204966204920636f756c64206f6666657220796f75206f"
                + "6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73"
                + "637265656e20776f756c642062652069742e")!
        let aad = Data(hexString: "50515253c0c1c2c3c4c5c6c7")!
        let key = Data(hexString: "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")!
        let nonce = Data(hexString: "404142434445464748494a4b4c4d4e4f5051525354555657")!

        let expectedCiphertext =
            "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb"
            + "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452"
            + "2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9"
            + "21f9664c97637da9768812f615c68b13b52e"
        let expectedTag = "c0875924c1c7987947deafd8780acf49"

        let sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, authenticating: aad)

        #expect(sealed.hexEncodedString() == expectedCiphertext + expectedTag)
    }

    @Test("XChaCha20-Poly1305 open recovers the draft §A.3.1 plaintext")
    func aeadOpenDraftVector() throws {
        let expectedPlaintext = Data(
            hexString: "4c616469657320616e642047656e746c656d656e206f662074686520636c6173"
                + "73206f66202739393a204966204920636f756c64206f6666657220796f75206f"
                + "6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73"
                + "637265656e20776f756c642062652069742e")!
        let aad = Data(hexString: "50515253c0c1c2c3c4c5c6c7")!
        let key = Data(hexString: "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")!
        let nonce = Data(hexString: "404142434445464748494a4b4c4d4e4f5051525354555657")!

        let ciphertextWithTag = Data(
            hexString: "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb"
                + "731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452"
                + "2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9"
                + "21f9664c97637da9768812f615c68b13b52e"
                + "c0875924c1c7987947deafd8780acf49")!

        let opened = try XChaCha20Poly1305.open(ciphertextWithTag, key: key, nonce: nonce, authenticating: aad)

        #expect(opened == expectedPlaintext)
    }

    // MARK: - Round-trip

    @Test("Random seal then open returns the original plaintext")
    func roundTripIdentity() throws {
        for _ in 0..<32 {
            let key = randomData(count: 32)
            let nonce = randomData(count: 24)
            let aad = randomData(count: Int.random(in: 0...48))
            let plaintext = randomData(count: Int.random(in: 0...256))

            let sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, authenticating: aad)
            let opened = try XChaCha20Poly1305.open(sealed, key: key, nonce: nonce, authenticating: aad)

            #expect(opened == plaintext)
        }
    }

    @Test("Round-trip works with the default empty AAD")
    func roundTripWithDefaultAAD() throws {
        let key = randomData(count: 32)
        let nonce = randomData(count: 24)
        let plaintext = Data("swift-nostr".utf8)

        let sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce)
        let opened = try XChaCha20Poly1305.open(sealed, key: key, nonce: nonce)

        #expect(opened == plaintext)
    }

    // MARK: - Tamper detection

    @Test("Flipping a ciphertext byte makes open throw")
    func tamperedCiphertextFails() throws {
        let key = randomData(count: 32)
        let nonce = randomData(count: 24)
        let plaintext = Data("tamper the ciphertext".utf8)

        var sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce)
        // Flip a byte inside the ciphertext body (before the 16-byte tag).
        sealed[sealed.startIndex] ^= 0x01

        #expect(throws: NostrError.decryptionFailed) {
            try XChaCha20Poly1305.open(sealed, key: key, nonce: nonce)
        }
    }

    @Test("Flipping a tag byte makes open throw")
    func tamperedTagFails() throws {
        let key = randomData(count: 32)
        let nonce = randomData(count: 24)
        let plaintext = Data("tamper the tag".utf8)

        var sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce)
        // Flip a byte inside the trailing 16-byte tag.
        sealed[sealed.index(before: sealed.endIndex)] ^= 0x01

        #expect(throws: NostrError.decryptionFailed) {
            try XChaCha20Poly1305.open(sealed, key: key, nonce: nonce)
        }
    }

    @Test("Changing the AAD makes open throw")
    func tamperedAADFails() throws {
        let key = randomData(count: 32)
        let nonce = randomData(count: 24)
        let plaintext = Data("tamper the aad".utf8)
        let aad = Data("original".utf8)

        let sealed = try XChaCha20Poly1305.seal(plaintext, key: key, nonce: nonce, authenticating: aad)

        #expect(throws: NostrError.decryptionFailed) {
            try XChaCha20Poly1305.open(sealed, key: key, nonce: nonce, authenticating: Data("modified".utf8))
        }
    }

    // MARK: - Length validation

    @Test("Seal rejects a wrong key length")
    func sealRejectsWrongKeyLength() {
        #expect(throws: NostrError.invalidData) {
            try XChaCha20Poly1305.seal(Data(), key: Data(repeating: 0, count: 31), nonce: Data(repeating: 0, count: 24))
        }
    }

    @Test("Seal rejects a wrong nonce length")
    func sealRejectsWrongNonceLength() {
        #expect(throws: NostrError.invalidData) {
            try XChaCha20Poly1305.seal(Data(), key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 23))
        }
    }

    @Test("Open rejects a wrong key length")
    func openRejectsWrongKeyLength() {
        #expect(throws: NostrError.invalidData) {
            try XChaCha20Poly1305.open(
                Data(repeating: 0, count: 16),
                key: Data(repeating: 0, count: 31),
                nonce: Data(repeating: 0, count: 24)
            )
        }
    }

    @Test("Open rejects a wrong nonce length")
    func openRejectsWrongNonceLength() {
        #expect(throws: NostrError.invalidData) {
            try XChaCha20Poly1305.open(
                Data(repeating: 0, count: 16),
                key: Data(repeating: 0, count: 32),
                nonce: Data(repeating: 0, count: 23)
            )
        }
    }

    @Test("Open rejects input shorter than the tag")
    func openRejectsShortInput() {
        #expect(throws: NostrError.invalidData) {
            try XChaCha20Poly1305.open(
                Data(repeating: 0, count: 15),
                key: Data(repeating: 0, count: 32),
                nonce: Data(repeating: 0, count: 24)
            )
        }
    }

    // MARK: - Helpers

    private func randomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
