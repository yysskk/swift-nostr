import Foundation
import NostrCore
import Testing

@Suite("EventSigner Tests")
struct EventSignerTests {
    private func makeSigner() throws -> EventSigner {
        try EventSigner(privateKey: PrivateKey(hex: "5566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344"))
    }

    @Test("signs an unsigned event into a verifiable event")
    func signAndVerify() throws {
        let signer = try makeSigner()
        let unsigned = UnsignedEvent(publicKey: signer.publicKey, kind: .textNote, content: "hello")
        let event = try signer.sign(unsigned)

        #expect(event.publicKey == signer.publicKey)
        #expect(event.kind == .textNote)
        #expect(event.content == "hello")
        try event.verify()
        #expect(event.isValid)
    }

    @Test("sign rejects an unsigned event keyed to another public key")
    func signRejectsForeignPublicKey() throws {
        let signer = try makeSigner()
        let unsigned = UnsignedEvent(publicKey: KeyPair().publicKey, kind: .textNote, content: "hello")

        #expect(throws: EventSigner.Error.publicKeyMismatch) { try signer.sign(unsigned) }
    }

    @Test("sign(_:) signs a template under the signer's public key, keeping its fields")
    func signTemplate() throws {
        let signer = try makeSigner()
        let template = EventTemplate(
            kind: .textNote,
            tags: [.hashtag("nostr")],
            content: "gm",
            createdAt: Timestamp(rawValue: 1_700_000_000)
        )

        let event = signer.sign(template)

        #expect(event.publicKey == signer.publicKey)
        #expect(event.kind == .textNote)
        #expect(event.tags.map(\.rawArray) == [["t", "nostr"]])
        #expect(event.content == "gm")
        #expect(event.createdAt == template.createdAt)
        try event.verify()
    }

    @Test("publicKey is the key pair's typed public key")
    func publicKeyIsTyped() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        #expect(signer.publicKey == keyPair.publicKey)
        #expect(signer.npub == keyPair.publicKey.npub)
    }

    @Test("verify rejects an event whose content was tampered with")
    func verifyRejectsTampering() throws {
        let signer = try makeSigner()
        let event = signer.sign(.textNote("original"))
        let tampered = Event(
            id: event.id,
            publicKey: event.publicKey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: "tampered",
            signature: event.signature
        )

        // The stored id no longer matches the recomputed hash of the tampered content.
        #expect(throws: Event.VerificationError.idMismatch) {
            try tampered.verify()
        }
        #expect(!tampered.isValid)
    }

    @Test("verify rejects an event whose signature was tampered with")
    func verifyRejectsTamperedSignature() throws {
        let signer = try makeSigner()
        let event = signer.sign(.textNote("original"))
        var signatureBytes = try #require(event.signature).data
        signatureBytes[signatureBytes.startIndex] ^= 0x01
        let tampered = Event(
            id: event.id,
            publicKey: event.publicKey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            signature: try Signature(data: signatureBytes)
        )

        #expect(throws: Event.VerificationError.invalidSignature) {
            try tampered.verify()
        }
        #expect(!tampered.isValid)
    }
}
