import Foundation
import NostrCore
import Testing

@Suite("KeyPair Tests")
struct KeyPairTests {

    @Test("Generate random keypair")
    func generateRandomKeypair() throws {
        let keyPair = KeyPair()

        #expect(keyPair.privateKey.data.count == 32)
        #expect(keyPair.publicKey.data.count == 32)
        #expect(keyPair.privateKey.hex.count == 64)
        #expect(keyPair.publicKey.hex.count == 64)
    }

    @Test("Create keypair from private key hex")
    func createFromPrivateKeyHex() throws {
        let privateKeyHex = "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        let keyPair = KeyPair(privateKey: try PrivateKey(hex: privateKeyHex))

        #expect(keyPair.privateKey.hex == privateKeyHex)
        #expect(keyPair.publicKey.hex.count == 64)
    }

    @Test("Bech32 encoding nsec")
    func bech32Nsec() throws {
        let keyPair = KeyPair()
        let nsec = keyPair.privateKey.nsec

        #expect(nsec.hasPrefix("nsec1"))

        // Decode and verify
        let recreated = try KeyPair(nsec: nsec)
        #expect(recreated.privateKey.hex == keyPair.privateKey.hex)
    }

    @Test("Bech32 encoding npub")
    func bech32Npub() throws {
        let keyPair = KeyPair()
        let npub = keyPair.publicKey.npub

        #expect(npub.hasPrefix("npub1"))

        // Decode and verify
        let publicKey = try PublicKey(npub: npub)
        #expect(publicKey.hex == keyPair.publicKey.hex)
    }

    @Test("A malformed nsec is rejected with the reason")
    func invalidNsec() {
        let keyPair = KeyPair()

        #expect(throws: KeyPair.Error.unexpectedPrefix("npub")) {
            _ = try KeyPair(nsec: keyPair.publicKey.npub)
        }
    }

    @Test("Keypairs for the same identity are equal")
    func equalityForSameIdentity() {
        let keyPair = KeyPair()
        let same = KeyPair(privateKey: keyPair.privateKey)
        let other = KeyPair()

        #expect(keyPair == same)
        #expect(keyPair != other)
    }

    @Test("Keypairs hash by identity and work in a Set")
    func hashingByIdentity() {
        let keyPair = KeyPair()
        let same = KeyPair(privateKey: keyPair.privateKey)
        let other = KeyPair()

        let identities: Set<KeyPair> = [keyPair, same, other]
        #expect(identities.count == 2)
        #expect(identities.contains(same))
    }
}
