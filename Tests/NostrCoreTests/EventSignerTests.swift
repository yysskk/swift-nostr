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
        let unsigned = UnsignedEvent(publicKey: signer.publicKey, kind: .textNote, content: "hello")
        let event = try signer.sign(unsigned)

        #expect(event.publicKey == signer.publicKey)
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

    @Test("signClientAuthentication carries the canonical relay URL and challenge (NIP-42)")
    func signClientAuthentication() throws {
        let signer = try makeSigner()
        let relay = try RelayURL(string: "wss://Relay.Example.com/")
        let event = try signer.signClientAuthentication(relayURL: relay, challenge: "abc123")

        #expect(event.kind == .clientAuthentication)
        #expect(event.firstTagValue(named: "relay") == "wss://relay.example.com")
        #expect(event.firstTagValue(named: "challenge") == "abc123")
        #expect(try event.verify())
    }

    @Test("signRepost records the reposted event, its author, and the relay")
    func signRepostCarriesRelayURL() throws {
        let signer = try makeSigner()
        let reposted = try signer.signTextNote(content: "gm")
        let event = try signer.signRepost(of: reposted, relayURL: RelayURL("wss://relay.example.com")!)

        #expect(event.kind == .repost)
        #expect(event.tags.contains(["e", reposted.id.hex, "wss://relay.example.com"]))
        #expect(event.tags.contains(["p", reposted.publicKey.hex]))
        #expect(try event.verify())
    }

    @Test("signRepost omits the relay when none is given")
    func signRepostWithoutRelayURL() throws {
        let signer = try makeSigner()
        let reposted = try signer.signTextNote(content: "gm")
        let event = try signer.signRepost(of: reposted)

        #expect(event.tags.contains(["e", reposted.id.hex]))
    }

    @Test("publicKey is the key pair's typed public key")
    func publicKeyIsTyped() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        #expect(signer.publicKey == keyPair.publicKey)
        #expect(signer.npub == keyPair.publicKey.npub)
    }

    @Test("signDeletion writes one e tag per event id, in order")
    func signDeletion() throws {
        let signer = try makeSigner()
        let first = try signer.signTextNote(content: "first")
        let second = try signer.signTextNote(content: "second")

        let deletion = try signer.signDeletion(eventIDs: [first.id, second.id], reason: "oops")

        #expect(deletion.kind == .eventDeletion)
        #expect(deletion.tags == [["e", first.id.hex], ["e", second.id.hex]])
        #expect(deletion.referencedEventIDs == [first.id, second.id])
        #expect(deletion.content == "oops")
        #expect(try deletion.verify())
    }

    @Test("signReaction references the event and its author")
    func signReaction() throws {
        let signer = try makeSigner()
        let author = EventSigner(keyPair: try KeyPair())
        let note = try author.signTextNote(content: "gm")

        let reaction = try signer.signReaction(to: note)

        #expect(reaction.kind == .reaction)
        #expect(reaction.tags == [["e", note.id.hex], ["p", author.publicKey.hex]])
        #expect(try reaction.verify())
    }

    @Test("verify rejects an event whose content was tampered with")
    func verifyRejectsTampering() throws {
        let signer = try makeSigner()
        let event = try signer.signTextNote(content: "original")
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
        #expect(throws: NostrError.self) {
            try tampered.verify()
        }
    }
}
