import Foundation
import NostrCore
import Testing

@Suite("KeyDerivation Tests")
struct KeyDerivationTests {

    // The NIP-06 test vector 1 mnemonic and its expected account-0 private key.
    private let mnemonicPhrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
    private let expectedPrivateKey = "7f7ff03d123792d6ac594bfa67bf6d0c0ab55b6b1fdb6249303fe861f1ccba9a"

    @Test("deriveNostrKey on a NIP-06 seed produces the vector private key")
    func derivesNIP06VectorKey() throws {
        let seed = try Mnemonic(phrase: mnemonicPhrase).toSeed()

        let privateKey = try KeyDerivation.deriveNostrKey(seed: seed)

        #expect(privateKey.count == 32)
        #expect(privateKey.hexEncodedString() == expectedPrivateKey)
    }

    @Test("A non-zero account derives a different key than account 0")
    func accountChangesKey() throws {
        let seed = try Mnemonic(phrase: mnemonicPhrase).toSeed()

        let account0 = try KeyDerivation.deriveNostrKey(seed: seed, account: 0)
        let account1 = try KeyDerivation.deriveNostrKey(seed: seed, account: 1)

        #expect(account0.hexEncodedString() == expectedPrivateKey)
        #expect(account0 != account1)
    }
}
