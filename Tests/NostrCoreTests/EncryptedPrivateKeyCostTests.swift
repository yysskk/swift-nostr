import Foundation
import NostrCore
import Testing

/// scrypt's memory cost is `128 · N · r`, and NIP-49 fixes `r` at 8, so a payload's `logN` byte
/// alone decides how much memory decryption asks for: 2^logN KiB, or 4 GiB at the spec's maximum of
/// 22. That byte comes from whoever wrote the `ncryptsec`, so decryption has to decide how much it
/// is willing to allocate before it starts.
@Suite("NIP-49 Scrypt Cost Bound Tests")
struct EncryptedPrivateKeyCostTests {
    private let password = "correct horse battery staple"
    private let privateKey = Data(repeating: 0x11, count: 32)

    /// Rewrites the cost byte of an existing payload. Encrypting at a high `logN` would actually
    /// perform the derivation, which is precisely the cost this guard exists to avoid paying.
    private func ncryptsec(withLogN logN: UInt8, from source: EncryptedPrivateKey) throws -> String {
        let (hrp, payload) = try Bech32.decode(source.ncryptsec)
        var bytes = Array(payload)
        bytes[1] = logN
        return try Bech32.encode(hrp: hrp, data: Data(bytes))
    }

    private func makeEncrypted(logN: UInt8 = 14) throws -> EncryptedPrivateKey {
        try EncryptedPrivateKey.encrypt(privateKey: privateKey, password: password, logN: logN)
    }

    /// Each of these would allocate at least half a gigabyte — a hard termination on the phones and
    /// watches this package supports, reached before the password is even checked.
    @Test(
        "a payload above the default cost cap is rejected without deriving a key",
        arguments: [UInt8(19), 20, 21, 22]
    )
    func rejectsExcessiveCost(logN: UInt8) throws {
        let string = try ncryptsec(withLogN: logN, from: makeEncrypted())
        let encrypted = try EncryptedPrivateKey(ncryptsec: string)

        // Parsing still reports the recorded cost, so a caller can decide what to do about it.
        #expect(encrypted.logN == logN)
        #expect(throws: NostrError.unsupportedScryptCost(logN)) {
            _ = try encrypted.decrypt(password: password)
        }
    }

    @Test("the cost the spec recommends stays within the default cap")
    func recommendedCostIsAccepted() throws {
        let string = try ncryptsec(withLogN: 16, from: makeEncrypted())
        let encrypted = try EncryptedPrivateKey(ncryptsec: string)

        // The payload was sealed at a different cost, so the key derives to something else and the
        // AEAD tag fails — but it fails on authentication, having passed the cost check.
        #expect(throws: NostrError.decryptionFailed) {
            _ = try encrypted.decrypt(password: password)
        }
    }

    @Test("a caller can lower the cap below the recorded cost")
    func callerCanLowerTheCap() throws {
        let encrypted = try makeEncrypted(logN: 14)

        #expect(throws: NostrError.unsupportedScryptCost(14)) {
            _ = try encrypted.decrypt(password: password, maxLogN: 13)
        }
    }

    @Test("a caller can raise the cap to open a costlier payload")
    func callerCanRaiseTheCap() throws {
        let encrypted = try makeEncrypted(logN: 14)

        #expect(try encrypted.decrypt(password: password, maxLogN: 14) == privateKey)
        #expect(try encrypted.decrypt(password: password, maxLogN: 22) == privateKey)
    }

    @Test("a cap above the range NIP-49 defines is rejected")
    func capAboveSpecRangeIsRejected() throws {
        let encrypted = try makeEncrypted()

        #expect(throws: NostrError.unsupportedScryptCost(23)) {
            _ = try encrypted.decrypt(password: password, maxLogN: 23)
        }
    }

    @Test("round-tripping at the default cap still works")
    func defaultRoundTrip() throws {
        let encrypted = try makeEncrypted(logN: 14)
        #expect(try encrypted.decrypt(password: password) == privateKey)
    }
}
