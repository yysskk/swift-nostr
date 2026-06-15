import Foundation
import NostrCore
import Testing

@Suite("EventSigner Tests")
struct EventSignerTests {
    private func makeSigner() throws -> EventSigner {
        try EventSigner(privateKeyHex: "5566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344")
    }

    @Test("signs an unsigned event into a verifiable event")
    func signAndVerify() throws {
        let signer = try makeSigner()
        let unsigned = UnsignedEvent(pubkey: signer.publicKey, kind: .textNote, content: "hello")
        let event = try signer.sign(unsigned)

        #expect(event.pubkey == signer.publicKey)
        #expect(event.kind == .textNote)
        #expect(event.content == "hello")
        #expect(try event.verify())
    }

    @Test("signTextNote produces a verifiable kind-1 event")
    func signTextNote() throws {
        let signer = try makeSigner()
        let event = try signer.signTextNote(content: "gm")

        #expect(event.kind == .textNote)
        #expect(event.content == "gm")
        #expect(try event.verify())
    }

    @Test("signClientAuthentication carries the relay and challenge (NIP-42)")
    func signClientAuthentication() throws {
        let signer = try makeSigner()
        let relay = URL(string: "wss://relay.example.com")!
        let event = try signer.signClientAuthentication(relayURL: relay, challenge: "abc123")

        #expect(event.kind == .clientAuthentication)
        #expect(event.firstTagValue(named: "relay") == "wss://relay.example.com")
        #expect(event.firstTagValue(named: "challenge") == "abc123")
        #expect(try event.verify())
    }

    @Test("verify rejects an event whose content was tampered with")
    func verifyRejectsTampering() throws {
        let signer = try makeSigner()
        let event = try signer.signTextNote(content: "original")
        let tampered = Event(
            id: event.id,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: "tampered",
            sig: event.sig
        )

        // The stored id no longer matches the recomputed hash of the tampered content.
        #expect(throws: NostrError.self) {
            try tampered.verify()
        }
    }
}
