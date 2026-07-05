import Foundation
import NostrCore
import Testing

@Suite("NostrSigning Tests")
struct NostrSigningTests {
    @Test("EventSigner used as any NostrSigning exposes the keypair public key")
    func publicKeyThroughProtocol() async throws {
        let keyPair = try KeyPair()
        let signer: any NostrSigning = EventSigner(keyPair: keyPair)

        #expect(try await signer.publicKey == keyPair.publicKeyHex)
    }

    @Test("signing through any NostrSigning produces a verifiable event")
    func signThroughProtocol() async throws {
        let keyPair = try KeyPair()
        let signer: any NostrSigning = EventSigner(keyPair: keyPair)
        let unsigned = UnsignedEvent(pubkey: keyPair.publicKeyHex, kind: .textNote, content: "hello")

        let event = try await signer.sign(unsigned)

        #expect(event.pubkey == keyPair.publicKeyHex)
        #expect(event.kind == .textNote)
        #expect(event.content == "hello")
        #expect(try event.verify())
    }

    @Test("NIP-44 encrypt then decrypt round-trips through any NostrSigning")
    func nip44RoundTripThroughProtocol() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let aliceSigner: any NostrSigning = EventSigner(keyPair: alice)
        let bobSigner: any NostrSigning = EventSigner(keyPair: bob)

        let ciphertext = try await aliceSigner.nip44Encrypt("secret", to: bob.publicKeyHex)
        let plaintext = try await bobSigner.nip44Decrypt(ciphertext, from: alice.publicKeyHex)

        #expect(plaintext == "secret")
    }

    @Test("EventSigner NIP-44 helpers round-trip directly between two keypairs")
    func eventSignerNIP44RoundTrip() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let aliceSigner = EventSigner(keyPair: alice)
        let bobSigner = EventSigner(keyPair: bob)

        // Alice encrypts to Bob; Bob decrypts from Alice.
        let ciphertext = try aliceSigner.nip44Encrypt("gm", to: bob.publicKeyHex)
        #expect(try bobSigner.nip44Decrypt(ciphertext, from: alice.publicKeyHex) == "gm")
    }
}
