import Foundation
import Testing

@testable import NostrCore

@Suite("NIP-49 EncryptedPrivateKey Tests")
struct EncryptedPrivateKeyTests {

    // MARK: - Official vector

    /// Official NIP-49 test vector: the `ncryptsec` for private key
    /// `3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683`, password `nostr`,
    /// log_n 16.
    /// https://github.com/nostr-protocol/nips/blob/master/49.md
    private static let officialNcryptsec =
        "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p"
    private static let officialPrivateKeyHex =
        "3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683"

    @Test("Decrypts the official NIP-49 vector")
    func decryptsOfficialVector() throws {
        let encrypted = try EncryptedPrivateKey(ncryptsec: Self.officialNcryptsec)

        #expect(encrypted.logN == 16)

        let privateKey = try encrypted.decrypt(password: "nostr")
        #expect(privateKey.hexEncodedString() == Self.officialPrivateKeyHex)
    }

    @Test("KeyPair decrypts the official NIP-49 vector")
    func keyPairDecryptsOfficialVector() throws {
        let keyPair = try KeyPair(ncryptsec: Self.officialNcryptsec, password: "nostr")

        #expect(keyPair.privateKeyHex == Self.officialPrivateKeyHex)
    }

    // MARK: - NFKC normalization

    @Test("Passwords are compared after NFKC normalization")
    func normalizesPasswordBeforeKeyDerivation() throws {
        let privateKey = Data(hexString: Self.officialPrivateKeyHex)!

        // U+00C5 (LATIN CAPITAL LETTER A WITH RING ABOVE) and U+0041 U+030A (A + COMBINING RING
        // ABOVE) are distinct UTF-8 byte sequences that collapse to the same string under NFKC.
        let composed = "\u{00C5}"
        let decomposed = "\u{0041}\u{030A}"
        #expect(Array(composed.utf8) != Array(decomposed.utf8))

        let encrypted = try EncryptedPrivateKey.encrypt(privateKey: privateKey, password: composed)
        let decrypted = try encrypted.decrypt(password: decomposed)

        #expect(decrypted == privateKey)
    }

    @Test("The NIP-49 ÅΩẛ̣ password example normalizes to a single form")
    func normalizesSpecPasswordExample() throws {
        let privateKey = Data(hexString: Self.officialPrivateKeyHex)!

        // The spec's example: U+212B U+2126 U+1E9B U+0323 normalizes to U+00C5 U+03A9 U+1E69.
        let original = "\u{212B}\u{2126}\u{1E9B}\u{0323}"
        let normalized = "\u{00C5}\u{03A9}\u{1E69}"

        let encrypted = try EncryptedPrivateKey.encrypt(privateKey: privateKey, password: original)
        let decrypted = try encrypted.decrypt(password: normalized)

        #expect(decrypted == privateKey)
    }

    // MARK: - Round trip

    @Test(
        "Round-trips a random key across passwords",
        arguments: ["", "correct horse battery staple", "🔐🗝️ nostr パスワード"]
    )
    func roundTripsRandomKey(password: String) throws {
        let privateKey = try SecureRandom.generateBytes(count: 32)

        let encrypted = try EncryptedPrivateKey.encrypt(privateKey: privateKey, password: password)
        let decrypted = try encrypted.decrypt(password: password)

        #expect(decrypted == privateKey)
    }

    @Test("KeyPair round trip preserves the public key")
    func keyPairRoundTripPreservesPublicKey() throws {
        let keyPair = try KeyPair()

        let encrypted = try keyPair.encryptedPrivateKey(password: "hunter2")
        let recovered = try KeyPair(ncryptsec: encrypted.ncryptsec, password: "hunter2")

        #expect(recovered.publicKeyHex == keyPair.publicKeyHex)
        #expect(recovered.privateKey == keyPair.privateKey)
    }

    @Test("A small custom cost exponent round-trips")
    func customLogNRoundTrips() throws {
        let privateKey = try SecureRandom.generateBytes(count: 32)

        let encrypted = try EncryptedPrivateKey.encrypt(
            privateKey: privateKey,
            password: "cost",
            logN: 14
        )
        #expect(encrypted.logN == 14)

        let decrypted = try encrypted.decrypt(password: "cost")
        #expect(decrypted == privateKey)
    }

    // MARK: - Key security

    @Test(
        "The key-security byte survives an encrypt/parse round trip",
        arguments: [
            EncryptedPrivateKey.KeySecurity.insecure,
            .secure,
            .unknown,
        ]
    )
    func preservesKeySecurity(keySecurity: EncryptedPrivateKey.KeySecurity) throws {
        let privateKey = try SecureRandom.generateBytes(count: 32)

        let encrypted = try EncryptedPrivateKey.encrypt(
            privateKey: privateKey,
            password: "secure",
            keySecurity: keySecurity
        )
        let reparsed = try EncryptedPrivateKey(ncryptsec: encrypted.ncryptsec)

        #expect(reparsed.keySecurity == keySecurity)

        // A differing key-security byte must not break decryption (it is the AEAD associated data).
        #expect(try encrypted.decrypt(password: "secure") == privateKey)
    }

    // MARK: - Failure modes

    @Test("A wrong password fails to decrypt")
    func wrongPasswordFails() throws {
        let privateKey = try SecureRandom.generateBytes(count: 32)
        let encrypted = try EncryptedPrivateKey.encrypt(privateKey: privateKey, password: "right")

        #expect(throws: NostrError.decryptionFailed) {
            try encrypted.decrypt(password: "wrong")
        }
    }

    @Test("Encrypting rejects a key that is not 32 bytes")
    func encryptRejectsWrongKeyLength() {
        #expect(throws: NostrError.invalidPrivateKey) {
            try EncryptedPrivateKey.encrypt(privateKey: Data(repeating: 0, count: 31), password: "x")
        }
    }

    @Test("Encrypting rejects an out-of-range cost exponent")
    func encryptRejectsUnsupportedCost() throws {
        let privateKey = try SecureRandom.generateBytes(count: 32)

        #expect(throws: NostrError.unsupportedScryptCost(0)) {
            try EncryptedPrivateKey.encrypt(privateKey: privateKey, password: "x", logN: 0)
        }
        #expect(throws: NostrError.unsupportedScryptCost(23)) {
            try EncryptedPrivateKey.encrypt(privateKey: privateKey, password: "x", logN: 23)
        }
    }

    @Test("Parsing rejects a non-ncryptsec prefix")
    func rejectsWrongPrefix() throws {
        // A valid nsec bech32 string carries the wrong HRP.
        let nsec = try KeyPair().nsec

        #expect(throws: NostrError.invalidNcryptsec) {
            try EncryptedPrivateKey(ncryptsec: nsec)
        }
    }

    @Test("Parsing rejects a non-bech32 string")
    func rejectsMalformedBech32() {
        #expect(throws: NostrError.invalidNcryptsec) {
            try EncryptedPrivateKey(ncryptsec: "not a bech32 string")
        }
    }

    @Test("Parsing rejects a truncated payload")
    func rejectsTruncatedPayload() throws {
        // A 90-byte payload (one byte short) under the correct HRP.
        let truncated = try Bech32.encode(
            hrp: "ncryptsec",
            data: Data([0x02] + [UInt8](repeating: 0, count: 89))
        )

        #expect(throws: NostrError.invalidNcryptsec) {
            try EncryptedPrivateKey(ncryptsec: truncated)
        }
    }

    @Test("Parsing rejects an unsupported version byte")
    func rejectsUnsupportedVersion() throws {
        // A full-length payload whose version byte is 0x01 instead of 0x02.
        let wrongVersion = try Bech32.encode(
            hrp: "ncryptsec",
            data: Data([0x01] + [UInt8](repeating: 0, count: 90))
        )

        #expect(throws: NostrError.invalidNcryptsec) {
            try EncryptedPrivateKey(ncryptsec: wrongVersion)
        }
    }

    @Test("Decrypting rejects a cost exponent outside 1...22", arguments: [UInt8(0), UInt8(23)])
    func decryptRejectsUnsupportedCost(logN: UInt8) throws {
        // Craft a structurally valid payload declaring an out-of-range log_n; the guard rejects it
        // before scrypt runs (so scrypt never sees N = 1 or a huge N and never leaks a raw
        // CryptoKit error), and the (garbage) ciphertext is never touched.
        var payload = Data()
        payload.append(0x02)  // version
        payload.append(logN)  // log_n
        payload.append(Data(repeating: 0, count: 16))  // salt
        payload.append(Data(repeating: 0, count: 24))  // nonce
        payload.append(0x02)  // key-security byte
        payload.append(Data(repeating: 0, count: 48))  // ciphertext
        let ncryptsec = try Bech32.encode(hrp: "ncryptsec", data: payload)

        let encrypted = try EncryptedPrivateKey(ncryptsec: ncryptsec)
        #expect(throws: NostrError.unsupportedScryptCost(logN)) {
            try encrypted.decrypt(password: "anything")
        }
    }
}
