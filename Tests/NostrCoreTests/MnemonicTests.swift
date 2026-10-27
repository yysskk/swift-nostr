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

        #expect(keyPair.privateKey.hex == expectedPrivateKey)
        #expect(keyPair.publicKey.hex == expectedPublicKey)
    }

    @Test("NIP-06 test vector 2 - 24 word mnemonic")
    func testVector2() throws {
        // From NIP-06 specification
        let phrase =
            "what bleak badge arrange retreat wolf trade produce cricket blur garlic valid proud rude strong choose busy staff weather area salt hollow arm fade"
        let expectedPrivateKey = "c15d739894c81a2fcfd3a2df85a0d2c0dbc47a280d092799f144d73d7ae78add"
        let expectedPublicKey = "d41b22899549e1f3d335a31002cfd382174006e166d3e658e3a5eecdb6463573"

        let keyPair = try KeyPair(mnemonicPhrase: phrase)

        #expect(keyPair.privateKey.hex == expectedPrivateKey)
        #expect(keyPair.publicKey.hex == expectedPublicKey)
    }

    // MARK: - BIP-39 Test Vectors

    @Test(
        "init(entropy:) matches the BIP-39 reference vectors",
        arguments: [
            (
                "00000000000000000000000000000000",
                "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            ),
            (
                "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
                "legal winner thank year wave sausage worth useful legal winner thank yellow"
            ),
            (
                "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
            ),
        ]
    )
    func entropyVectors(entropyHex: String, phrase: String) throws {
        let entropy = try #require(Data(hexString: entropyHex))

        #expect(try Mnemonic(entropy: entropy).phrase == phrase)
    }

    @Test("seed(passphrase:) matches the BIP-39 reference vector")
    func seedVector() throws {
        let mnemonic = try Mnemonic(entropy: Data(count: 16))

        #expect(
            mnemonic.seed(passphrase: "TREZOR").hexEncodedString()
                == "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        )
    }

    @Test("init(entropy:) rejects an unsupported entropy length")
    func entropyRejectsInvalidLength() {
        #expect(throws: Mnemonic.Error.invalidEntropyLength(15)) {
            _ = try Mnemonic(entropy: Data(count: 15))
        }
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
        #expect(keyPair.privateKey.data.count == 32)
        #expect(keyPair.publicKey.data.count == 32)

        // Verify the keypair can be recreated from the mnemonic
        let recreatedKeyPair = try KeyPair(mnemonic: mnemonic)
        #expect(recreatedKeyPair.privateKey.hex == keyPair.privateKey.hex)
        #expect(recreatedKeyPair.publicKey.hex == keyPair.publicKey.hex)
    }

    // MARK: - Mnemonic Validation

    @Test("Invalid word count throws error")
    func invalidWordCount() {
        #expect(throws: Mnemonic.Error.invalidWordCount(13)) {
            _ = try Mnemonic.generate(wordCount: 13)
        }
    }

    @Test("A phrase with an unsupported word count throws error")
    func phraseWithInvalidWordCount() {
        #expect(throws: Mnemonic.Error.invalidWordCount(3)) {
            _ = try Mnemonic(phrase: "leader monkey parrot")
        }
    }

    @Test("Invalid word throws error")
    func invalidWord() {
        let invalidPhrase = "leader monkey parrot ring guide accident before fence cannon height naive notaword"
        #expect(throws: Mnemonic.Error.unknownWord("notaword")) {
            _ = try Mnemonic(phrase: invalidPhrase)
        }
    }

    @Test("Invalid checksum throws error")
    func invalidChecksum() {
        // Using wrong last word (checksum mismatch)
        let invalidPhrase = "leader monkey parrot ring guide accident before fence cannon height naive ability"
        #expect(throws: Mnemonic.Error.invalidChecksum) {
            _ = try Mnemonic(phrase: invalidPhrase)
        }
    }

    @Test("A keypair from an invalid phrase throws the mnemonic error")
    func keyPairFromInvalidPhrase() {
        let invalidPhrase = "leader monkey parrot ring guide accident before fence cannon height naive notaword"
        #expect(throws: KeyPair.Error.invalidMnemonic(.unknownWord("notaword"))) {
            _ = try KeyPair(mnemonicPhrase: invalidPhrase)
        }
    }

    @Test("Generating a keypair with an unsupported word count throws the mnemonic error")
    func generateKeyPairWithInvalidWordCount() {
        #expect(throws: KeyPair.Error.invalidMnemonic(.invalidWordCount(13))) {
            _ = try KeyPair.generate(wordCount: 13)
        }
    }

    // MARK: - Account Derivation

    @Test("Different accounts derive different keys")
    func differentAccounts() throws {
        let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let mnemonic = try Mnemonic(phrase: phrase)

        let keyPair0 = try KeyPair(mnemonic: mnemonic, account: 0)
        let keyPair1 = try KeyPair(mnemonic: mnemonic, account: 1)

        #expect(keyPair0.privateKey.hex != keyPair1.privateKey.hex)
        #expect(keyPair0.publicKey.hex != keyPair1.publicKey.hex)
    }

    // MARK: - Passphrase Support

    @Test("Passphrase changes derived key")
    func passphraseChangesKey() throws {
        let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let mnemonic = try Mnemonic(phrase: phrase)

        let keyPairNoPass = try KeyPair(mnemonic: mnemonic, passphrase: "")
        let keyPairWithPass = try KeyPair(mnemonic: mnemonic, passphrase: "mypassphrase")

        #expect(keyPairNoPass.privateKey.hex != keyPairWithPass.privateKey.hex)
    }

    // MARK: - Mnemonic Phrase

    @Test("Mnemonic phrase is space-separated")
    func mnemonicPhraseFormat() throws {
        let phrase = "leader monkey parrot ring guide accident before fence cannon height naive bean"
        let mnemonic = try Mnemonic(phrase: phrase)

        #expect(mnemonic.phrase == phrase)
    }
}
