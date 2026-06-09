import Foundation
import Testing

@testable import NostrClient

@Suite("KeyPair Tests")
struct KeyPairTests {

    @Test("Generate random keypair")
    func generateRandomKeypair() throws {
        let keyPair = try KeyPair()

        #expect(keyPair.privateKey.count == 32)
        #expect(keyPair.publicKey.count == 32)
        #expect(keyPair.privateKeyHex.count == 64)
        #expect(keyPair.publicKeyHex.count == 64)
    }

    @Test("Create keypair from private key hex")
    func createFromPrivateKeyHex() throws {
        let privateKeyHex = "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        let keyPair = try KeyPair(privateKeyHex: privateKeyHex)

        #expect(keyPair.privateKeyHex == privateKeyHex)
        #expect(keyPair.publicKeyHex.count == 64)
    }

    @Test("Bech32 encoding nsec")
    func bech32Nsec() throws {
        let keyPair = try KeyPair()
        let nsec = keyPair.nsec

        #expect(nsec.hasPrefix("nsec1"))

        // Decode and verify
        let recreated = try KeyPair(nsec: nsec)
        #expect(recreated.privateKeyHex == keyPair.privateKeyHex)
    }

    @Test("Bech32 encoding npub")
    func bech32Npub() throws {
        let keyPair = try KeyPair()
        let npub = keyPair.npub

        #expect(npub.hasPrefix("npub1"))

        // Decode and verify
        let publicKey = try PublicKey(npub: npub)
        #expect(publicKey.hex == keyPair.publicKeyHex)
    }

    @Test("Invalid private key length throws error")
    func invalidPrivateKeyLength() {
        let shortKey = Data(repeating: 0, count: 16)
        #expect(throws: NostrError.invalidPrivateKey) {
            _ = try KeyPair(privateKey: shortKey)
        }
    }

    @Test("Invalid hex string throws error")
    func invalidHexString() {
        #expect(throws: NostrError.invalidHex) {
            _ = try KeyPair(privateKeyHex: "not-a-hex-string")
        }
    }
}

@Suite("PublicKey Tests")
struct PublicKeyTests {

    @Test("Create from hex")
    func createFromHex() throws {
        let keyPair = try KeyPair()
        let publicKey = try PublicKey(hex: keyPair.publicKeyHex)

        #expect(publicKey.hex == keyPair.publicKeyHex)
    }

    @Test("Create from npub")
    func createFromNpub() throws {
        let keyPair = try KeyPair()
        let publicKey = try PublicKey(npub: keyPair.npub)

        #expect(publicKey.hex == keyPair.publicKeyHex)
    }

    @Test("Invalid public key length throws error")
    func invalidPublicKeyLength() {
        let shortKey = Data(repeating: 0, count: 16)
        #expect(throws: NostrError.invalidPublicKey) {
            _ = try PublicKey(data: shortKey)
        }
    }
}
