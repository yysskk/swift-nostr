import Foundation
import NostrCore
import Testing

@Suite("NIP-06 Mnemonic Tests")
struct MnemonicTests {

    // MARK: - NIP-06 Test Vectors

    @Test("NIP-06 test vector 1 - 12 word mnemonic")
    func testVector1() throws {
        // From NIP-06 specification
        let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let expectedPrivateKey = "7f7ff03d123792d6ac594bfa67bf6d0c0ab55b6b1fdb6249303fe861f1ccba9a"
        let expectedPublicKey = "17162c921dc4d2518f9a101db33695df1afb56ab82f5ff3e5da6eec3ca5cd917"

        let keyPair = try KeyPair(mnemonicPhrase: phrase)

        #expect(keyPair.privateKeyHex == expectedPrivateKey)
        #expect(keyPair.publicKeyHex == expectedPublicKey)
    }

    @Test("NIP-06 test vector 2 - 24 word mnemonic")
    func testVector2() throws {
        // From NIP-06 specification
        let phrase =
            "what bleak badge arrange retreat wolf trade produce cricket blur garlic valid proud rude strong choose busy staff weather area salt hollow arm fade"
        let expectedPrivateKey = "c15d739894c81a2fcfd3a2df85a0d2c0dbc47a280d092799f144d73d7ae78add"
        let expectedPublicKey = "d41b22899549e1f3d335a31002cfd382174006e166d3e658e3a5eecdb6463573"

        let keyPair = try KeyPair(mnemonicPhrase: phrase)

        #expect(keyPair.privateKeyHex == expectedPrivateKey)
        #expect(keyPair.publicKeyHex == expectedPublicKey)
    }

    // MARK: - Mnemonic Generation

    @Test("Generate 12 word mnemonic")
    func generate12Words() throws {
        let mnemonic = try Mnemonic.generate(wordCount: 12)

        #expect(mnemonic.wordCount == 12)
        #expect(mnemonic.words.count == 12)

        // All words should be in the BIP-39 wordlist
        for word in mnemonic.words {
            #expect(BIP39WordList.english.contains(word))
        }
    }

    @Test("Generate 24 word mnemonic")
    func generate24Words() throws {
        let mnemonic = try Mnemonic.generate(wordCount: 24)

        #expect(mnemonic.wordCount == 24)
        #expect(mnemonic.words.count == 24)
    }

    @Test("Generate keypair with mnemonic")
    func generateKeypairWithMnemonic() throws {
        let (mnemonic, keyPair) = try KeyPair.generate(wordCount: 12)

        #expect(mnemonic.wordCount == 12)
        #expect(keyPair.privateKey.count == 32)
        #expect(keyPair.publicKey.count == 32)

        // Verify the keypair can be recreated from the mnemonic
        let recreatedKeyPair = try KeyPair(mnemonic: mnemonic)
        #expect(recreatedKeyPair.privateKeyHex == keyPair.privateKeyHex)
        #expect(recreatedKeyPair.publicKeyHex == keyPair.publicKeyHex)
    }

    // MARK: - Mnemonic Validation

    @Test("Invalid word count throws error")
    func invalidWordCount() {
        #expect(throws: NostrError.invalidMnemonic) {
            _ = try Mnemonic.generate(wordCount: 13)
        }
    }

    @Test("Invalid word throws error")
    func invalidWord() {
        let invalidPhrase = "leader monkey parrot ring guide accident before fence cannon height naive notaword"
        #expect(throws: NostrError.invalidMnemonicWord("notaword")) {
            _ = try Mnemonic(phrase: invalidPhrase)
        }
    }

    @Test("Invalid checksum throws error")
    func invalidChecksum() {
        // Using wrong last word (checksum mismatch)
        let invalidPhrase = "leader monkey parrot ring guide accident before fence cannon height naive ability"
        #expect(throws: NostrError.invalidMnemonicChecksum) {
            _ = try Mnemonic(phrase: invalidPhrase)
        }
    }

    // MARK: - Account Derivation

    @Test("Different accounts derive different keys")
    func differentAccounts() throws {
        let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let mnemonic = try Mnemonic(phrase: phrase)

        let keyPair0 = try KeyPair(mnemonic: mnemonic, account: 0)
        let keyPair1 = try KeyPair(mnemonic: mnemonic, account: 1)

        #expect(keyPair0.privateKeyHex != keyPair1.privateKeyHex)
        #expect(keyPair0.publicKeyHex != keyPair1.publicKeyHex)
    }

    // MARK: - Passphrase Support

    @Test("Passphrase changes derived key")
    func passphraseChangesKey() throws {
        let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let mnemonic = try Mnemonic(phrase: phrase)

        let keyPairNoPass = try KeyPair(mnemonic: mnemonic, passphrase: "")
        let keyPairWithPass = try KeyPair(mnemonic: mnemonic, passphrase: "mypassphrase")

        #expect(keyPairNoPass.privateKeyHex != keyPairWithPass.privateKeyHex)
    }

    // MARK: - Mnemonic Phrase

    @Test("Mnemonic phrase is space-separated")
    func mnemonicPhraseFormat() throws {
        let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let mnemonic = try Mnemonic(phrase: phrase)

        #expect(mnemonic.phrase == phrase)
    }
}
