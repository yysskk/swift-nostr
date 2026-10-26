import Foundation
import NostrCore
import Testing

@Suite("KeyPair Tests")
struct KeyPairTests {

    @Test("Generate random keypair")
    func generateRandomKeypair() throws {
        let keyPair = try KeyPair()

        #expect(keyPair.privateKey.count == 32)
        #expect(keyPair.publicKey.data.count == 32)
        #expect(keyPair.privateKeyHex.count == 64)
        #expect(keyPair.publicKey.hex.count == 64)
    }

    @Test("Create keypair from private key hex")
    func createFromPrivateKeyHex() throws {
        let privateKeyHex = "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        let keyPair = try KeyPair(privateKeyHex: privateKeyHex)

        #expect(keyPair.privateKeyHex == privateKeyHex)
        #expect(keyPair.publicKey.hex.count == 64)
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
        let npub = keyPair.publicKey.npub

        #expect(npub.hasPrefix("npub1"))

        // Decode and verify
        let publicKey = try PublicKey(npub: npub)
        #expect(publicKey.hex == keyPair.publicKey.hex)
    }

    @Test("Invalid private key length throws error")
    func invalidPrivateKeyLength() {
        let shortKey = Data(repeating: 0, count: 16)
        #expect(throws: KeyPair.Error.invalidLength(16)) {
            _ = try KeyPair(privateKey: shortKey)
        }
    }

    @Test("Invalid hex string throws error", arguments: ["not-a-hex-string", "abcd"])
    func invalidHexString(hex: String) {
        #expect(throws: KeyPair.Error.invalidHex) {
            _ = try KeyPair(privateKeyHex: hex)
        }
    }

    @Test("A key that is not a secp256k1 scalar is rejected")
    func invalidScalar() {
        let curveOrder = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
        for hex in [String(repeating: "0", count: 64), curveOrder] {
            #expect(throws: KeyPair.Error.invalidPrivateKey) {
                _ = try KeyPair(privateKeyHex: hex)
            }
        }
    }

    @Test("A malformed nsec is rejected with the reason")
    func invalidNsec() throws {
        let keyPair = try KeyPair()
        let corrupted = String(keyPair.nsec.dropLast()) + (keyPair.nsec.hasSuffix("q") ? "p" : "q")
        let short = try Bech32.encode(hrp: "nsec", data: Data(repeating: 1, count: 31))

        #expect(throws: KeyPair.Error.invalidBech32(.invalidChecksum)) {
            _ = try KeyPair(nsec: corrupted)
        }
        #expect(throws: KeyPair.Error.unexpectedPrefix("npub")) {
            _ = try KeyPair(nsec: keyPair.publicKey.npub)
        }
        #expect(throws: KeyPair.Error.invalidLength(31)) {
            _ = try KeyPair(nsec: short)
        }
    }

    @Test("Keypairs for the same identity are equal")
    func equalityForSameIdentity() throws {
        let keyPair = try KeyPair()
        let same = try KeyPair(privateKey: keyPair.privateKey)
        let other = try KeyPair()

        #expect(keyPair == same)
        #expect(keyPair != other)
    }

    @Test("Keypairs hash by identity and work in a Set")
    func hashingByIdentity() throws {
        let keyPair = try KeyPair()
        let same = try KeyPair(privateKey: keyPair.privateKey)
        let other = try KeyPair()

        let identities: Set<KeyPair> = [keyPair, same, other]
        #expect(identities.count == 2)
        #expect(identities.contains(same))
    }
}
