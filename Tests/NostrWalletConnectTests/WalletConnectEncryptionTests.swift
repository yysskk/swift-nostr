import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnectEncryption Tests")
struct WalletConnectEncryptionTests {
    @Test("scheme raw values match the NIP-47 wire tokens")
    func rawValues() {
        #expect(WalletConnectEncryption.nip44.rawValue == "nip44_v2")
        #expect(WalletConnectEncryption.nip04.rawValue == "nip04")
        #expect(WalletConnectEncryption(rawValue: "nip44_v2") == .nip44)
        #expect(WalletConnectEncryption(rawValue: "nip04") == .nip04)
        #expect(WalletConnectEncryption(rawValue: "aes") == nil)
    }

    @Test("round-trips through the cipher for each scheme", arguments: [WalletConnectEncryption.nip44, .nip04])
    func roundTrip(scheme: WalletConnectEncryption) throws {
        let client = KeyPair()
        let wallet = KeyPair()
        let cipher = WalletConnectCipher(scheme)
        let message = #"{"method":"get_balance","params":{}}"#

        let payload = try cipher.encrypt(message, recipientPublicKey: wallet.publicKey, sender: client)
        let decrypted = try cipher.decrypt(payload, senderPublicKey: client.publicKey, recipient: wallet)

        #expect(decrypted == message)
    }

    @Test("a NIP-04 payload is shaped differently from a NIP-44 payload")
    func payloadShapes() throws {
        let client = KeyPair()
        let wallet = KeyPair()

        let nip04 = try WalletConnectCipher(.nip04).encrypt("hi", recipientPublicKey: wallet.publicKey, sender: client)
        let nip44 = try WalletConnectCipher(.nip44).encrypt("hi", recipientPublicKey: wallet.publicKey, sender: client)

        #expect(nip04.contains("?iv="))
        #expect(!nip44.contains("?iv="))
    }

    @Test("decrypting with the wrong scheme fails")
    func crossSchemeFails() throws {
        let client = KeyPair()
        let wallet = KeyPair()

        let nip04Payload = try WalletConnectCipher(.nip04)
            .encrypt("hi", recipientPublicKey: wallet.publicKey, sender: client)
        #expect(throws: (any Error).self) {
            try WalletConnectCipher(.nip44).decrypt(nip04Payload, senderPublicKey: client.publicKey, recipient: wallet)
        }

        let nip44Payload = try WalletConnectCipher(.nip44)
            .encrypt("hi", recipientPublicKey: wallet.publicKey, sender: client)
        #expect(throws: (any Error).self) {
            try WalletConnectCipher(.nip04).decrypt(nip44Payload, senderPublicKey: client.publicKey, recipient: wallet)
        }
    }

    @Test(
        "a recipient public key that is not on the curve is rejected for each scheme",
        arguments: [WalletConnectEncryption.nip44, .nip04]
    )
    func offCurvePublicKey(scheme: WalletConnectEncryption) throws {
        let client = KeyPair()
        // Well-formed hex, but no secp256k1 point has this x coordinate (it exceeds the field size).
        let offCurve = try PublicKey(hex: String(repeating: "ff", count: 32))
        #expect(throws: (any Error).self) {
            try WalletConnectCipher(scheme).encrypt("hi", recipientPublicKey: offCurve, sender: client)
        }
    }
}
