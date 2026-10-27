import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("NostrSigning Tests")
struct NostrSigningTests {
    @Test("EventSigner used as any NostrSigning exposes the keypair public key")
    func publicKeyThroughProtocol() async throws {
        let keyPair = KeyPair()
        let signer: any NostrSigning = EventSigner(keyPair: keyPair)

        #expect(try await signer.publicKey == keyPair.publicKey)
    }

    @Test("signing through any NostrSigning produces a verifiable event")
    func signThroughProtocol() async throws {
        let keyPair = KeyPair()
        let signer: any NostrSigning = EventSigner(keyPair: keyPair)
        let unsigned = UnsignedEvent(publicKey: keyPair.publicKey, kind: .textNote, content: "hello")

        let event = try await signer.sign(unsigned)

        #expect(event.publicKey == keyPair.publicKey)
        #expect(event.kind == .textNote)
        #expect(event.content == "hello")
        try event.verify()
    }

    @Test("sign(_:) signs a template under the signer's public key through any NostrSigning")
    func signTemplateThroughProtocol() async throws {
        let keyPair = KeyPair()
        let signer: any NostrSigning = EventSigner(keyPair: keyPair)
        var template = EventTemplate.textNote("hello", tags: [.hashtag("nostr")])
        template.createdAt = Timestamp(rawValue: 1_700_000_000)

        let event = try await signer.sign(template)

        #expect(event.publicKey == keyPair.publicKey)
        #expect(event.kind == .textNote)
        #expect(event.tags.map(\.rawArray) == [["t", "nostr"]])
        #expect(event.content == "hello")
        #expect(event.createdAt == template.createdAt)
        try event.verify()
    }

    @Test("an EventSigner signs a template synchronously in async code, without await")
    func eventSignerSignsTemplateWithoutAwaitInAsyncCode() async throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = signer.sign(EventTemplate.textNote("gm"))

        #expect(event.publicKey == keyPair.publicKey)
        #expect(event.content == "gm")
        try event.verify()
    }

    @Test("sign(_:) resolves the public key of a signer that is not an EventSigner")
    func signTemplateThroughRemoteSigner() async throws {
        let keyPair = KeyPair()
        let signer = StubRemoteSigner(keyPair: keyPair)

        let event = try await signer.sign(.textNote("hello"))

        #expect(event.publicKey == keyPair.publicKey)
        #expect(event.content == "hello")
        try event.verify()
    }

    @Test("a zap request is signed by a signer that is not an EventSigner (NIP-57)")
    func zapRequestThroughRemoteSigner() async throws {
        let keyPair = KeyPair()
        let signer = StubRemoteSigner(keyPair: keyPair)
        let relay = RelayURL("wss://relay.example.com")!

        let zap = try await signer.sign(.zapRequest(to: .fixture("recipient"), relays: [relay], amountMillisats: 21000))

        #expect(zap.kind == .zapRequest)
        #expect(zap.publicKey == keyPair.publicKey)
        #expect(zap.firstTagValue(named: "p") == PublicKey.fixture("recipient").hex)
        #expect(zap.firstTagValue(named: "amount") == "21000")
        try zap.verify()
    }

    @Test("NIP-44 encrypt then decrypt round-trips through any NostrSigning")
    func nip44RoundTripThroughProtocol() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let aliceSigner: any NostrSigning = EventSigner(keyPair: alice)
        let bobSigner: any NostrSigning = EventSigner(keyPair: bob)

        let ciphertext = try await aliceSigner.nip44Encrypt("secret", to: bob.publicKey)
        let plaintext = try await bobSigner.nip44Decrypt(ciphertext, from: alice.publicKey)

        #expect(plaintext == "secret")
    }

    @Test("EventSigner NIP-44 helpers round-trip directly between two keypairs")
    func eventSignerNIP44RoundTrip() throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let aliceSigner = EventSigner(keyPair: alice)
        let bobSigner = EventSigner(keyPair: bob)

        // Alice encrypts to Bob; Bob decrypts from Alice.
        let ciphertext = try aliceSigner.nip44Encrypt("gm", to: bob.publicKey)
        #expect(try bobSigner.nip44Decrypt(ciphertext, from: alice.publicKey) == "gm")
    }
}
