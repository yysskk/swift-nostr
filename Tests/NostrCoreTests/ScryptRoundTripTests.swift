import Foundation
import NostrCore
import Testing

/// The writer and the reader have to agree on how much scrypt cost is acceptable. Capping only the
/// reader meant this library could mint an `ncryptsec` it would then refuse to open.
@Suite("NIP-49 Cost Round-Trip Tests")
struct ScryptRoundTripTests {
    private let privateKey = Data(repeating: 0x22, count: 32)
    private let password = "hunter2"

    @Test("a key written at the default cap opens with the default cap")
    func defaultsRoundTrip() throws {
        let encrypted = try EncryptedPrivateKey.encrypt(
            privateKey: privateKey, password: password, logN: 14)

        #expect(try encrypted.decrypt(password: password) == privateKey)
    }

    /// Previously `encrypt` accepted up to the spec's 22 while `decrypt` refused above 18, so this
    /// pairing threw `unsupportedScryptCost` for a key this library had just produced.
    @Test("encrypt refuses a cost the default reader could not open")
    func encryptRefusesUnreadableCost() {
        #expect(throws: NostrError.unsupportedScryptCost(20)) {
            _ = try EncryptedPrivateKey.encrypt(
                privateKey: privateKey, password: password, logN: 20)
        }
    }

    /// Writing a costlier key stays possible, but has to be asked for — and then it is the caller's
    /// job to read it back with a matching allowance.
    @Test("a raised cap lets both sides agree on a costlier key")
    func raisedCapRoundTrips() throws {
        let encrypted = try EncryptedPrivateKey.encrypt(
            privateKey: privateKey, password: password, logN: 19, maximumLogN: 19)

        #expect(encrypted.logN == 19)
        #expect(throws: NostrError.unsupportedScryptCost(19)) {
            _ = try encrypted.decrypt(password: password)
        }
        #expect(try encrypted.decrypt(password: password, maxLogN: 19) == privateKey)
    }

    /// The writing side needs the same whole-range check as the reading side: an upper-bound-only
    /// guard let a zero cap through, and `1...0` is not a valid range.
    @Test("a cap below the range NIP-49 defines is refused on both sides")
    func capBelowSpecRangeIsRefused() throws {
        #expect(throws: NostrError.unsupportedScryptCost(0)) {
            _ = try EncryptedPrivateKey.encrypt(
                privateKey: privateKey, password: password, logN: 14, maximumLogN: 0)
        }

        let keyPair = try KeyPair()
        #expect(throws: NostrError.unsupportedScryptCost(0)) {
            _ = try keyPair.encryptedPrivateKey(password: password, logN: 14, maximumLogN: 0)
        }
    }

    @Test("a cap beyond the range NIP-49 defines is refused on both sides")
    func capBeyondSpecIsRefused() throws {
        #expect(throws: NostrError.unsupportedScryptCost(23)) {
            _ = try EncryptedPrivateKey.encrypt(
                privateKey: privateKey, password: password, logN: 14, maximumLogN: 23)
        }

        let encrypted = try EncryptedPrivateKey.encrypt(
            privateKey: privateKey, password: password, logN: 14)
        #expect(throws: NostrError.unsupportedScryptCost(23)) {
            _ = try encrypted.decrypt(password: password, maxLogN: 23)
        }
    }

    @Test("the KeyPair convenience carries the same cap")
    func keyPairConvenienceRoundTrips() throws {
        let keyPair = try KeyPair()
        let encrypted = try keyPair.encryptedPrivateKey(password: password, logN: 14)

        #expect(try KeyPair(ncryptsec: encrypted.ncryptsec, password: password).privateKeyHex == keyPair.privateKeyHex)
    }
}
